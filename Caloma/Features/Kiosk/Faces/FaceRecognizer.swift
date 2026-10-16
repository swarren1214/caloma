import Foundation
import SwiftUI

/// The faces Caloma knows, on this iPad only: a set of embeddings per family member, never
/// photos. Kept in a protected file that isn't backed up or synced.
@Observable
final class FaceStore {
    static let shared = FaceStore()

    private(set) var faces: [UUID: [[Float]]] = [:]

    /// Embeddings from face setup; Not-you picks add to these up to `maximum`.
    static let maximum = 40
    @ObservationIgnored private var setupCounts: [UUID: Int] = [:]

    private struct File: Codable {
        var embedder: String
        var faces: [String: [[Float]]]
        var setupCounts: [String: Int]?
    }

    private var url: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Faces", directoryHint: .isDirectory).appending(path: "faces.json")
    }

    init() {
        load()
    }

    func isEnrolled(_ id: UUID) -> Bool { !(faces[id]?.isEmpty ?? true) }
    var isEmpty: Bool { faces.isEmpty }

    func set(_ embeddings: [[Float]], for id: UUID) {
        faces[id] = embeddings
        setupCounts[id] = embeddings.count
        save()
    }

    /// A Not-you pick: one more look at this person, if they've been set up.
    func learn(_ embedding: [Float], for id: UUID) {
        guard var stored = faces[id], !stored.isEmpty else { return }
        stored.append(embedding)
        let kept = setupCounts[id] ?? 0
        if stored.count > Self.maximum, stored.count > kept {
            // Drop the oldest learned look; setup's looks stay.
            stored.remove(at: min(kept, stored.count - 1))
        }
        faces[id] = stored
        save()
    }

    func erase(_ id: UUID) {
        faces[id] = nil
        setupCounts[id] = nil
        save()
    }

    func eraseAll() {
        faces = [:]
        setupCounts = [:]
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        // Faces made by another embedder can't be compared; they need setting up again.
        guard file.embedder == FaceEmbedder.current.id else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var loaded: [UUID: [[Float]]] = [:]
        for (key, value) in file.faces {
            if let id = UUID(uuidString: key) { loaded[id] = value }
        }
        faces = loaded
        var counts: [UUID: Int] = [:]
        for (key, value) in file.setupCounts ?? [:] {
            if let id = UUID(uuidString: key) { counts[id] = value }
        }
        setupCounts = counts
    }

    private func save() {
        var encoded: [String: [[Float]]] = [:]
        for (id, value) in faces { encoded[id.uuidString] = value }
        var counts: [String: Int] = [:]
        for (id, value) in setupCounts { counts[id.uuidString] = value }
        let file = File(embedder: FaceEmbedder.current.id, faces: encoded, setupCounts: counts)
        guard let data = try? JSONEncoder().encode(file) else { return }
        var folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Watches the front camera in Kiosk Mode and says who's there. Only a confident, steady match
/// counts: the best person must clear the threshold, beat the next person by a margin, and win
/// 3 of the last 4 looks. Face setup borrows the same camera.
@Observable
final class FaceRecognizer {
    static let shared = FaceRecognizer()

    enum Mode: Equatable {
        case off, recognize, enroll
    }

    private(set) var mode: Mode = .off
    private(set) var cameraDenied = false
    /// The latest look, for face setup and the test screen.
    private(set) var latest: FaceReading = .nobody
    /// Everyone's score for the latest look, best first.
    private(set) var scores: [(id: UUID, score: Float)] = []

    @ObservationIgnored let camera = FaceCamera()
    @ObservationIgnored private let store = FaceStore.shared

    /// Kiosk Mode: someone was recognized, and how long they've been the steady answer.
    @ObservationIgnored var onRecognized: ((UUID, TimeInterval) -> Void)?
    /// Face setup: every look.
    @ObservationIgnored var onReading: ((FaceReading) -> Void)?

    @ObservationIgnored private var votes: [UUID?] = []
    @ObservationIgnored private var steady: UUID?
    @ObservationIgnored private var steadySince = Date.now
    @ObservationIgnored private var recent: (embedding: [Float], at: Date)?

    /// Faces must be at least this tall in the frame (the front camera is wide; check with
    /// Test Recognition and adjust).
    static let minimumFaceHeight = 0.12

    func start(_ mode: Mode) async {
        guard mode != .off else { stop(); return }
        guard await FaceCamera.requestAccess() else {
            cameraDenied = true
            return
        }
        // The screen may have gone while the permission prompt was up.
        guard !Task.isCancelled else { return }
        cameraDenied = false
        self.mode = mode
        reset()
        camera.framesPerSecond = mode == .enroll ? 10 : 6
        camera.onFrame = { FaceRecognizer.process($0) }
        camera.start()
    }

    func stop() {
        mode = .off
        camera.onFrame = nil
        camera.stop()
        reset()
        latest = .nobody
        scores = []
    }

    /// Stops looking for a moment (Face ID needs the camera), then carries on.
    func pause(_ paused: Bool) {
        guard mode == .recognize else { return }
        if paused { camera.stop() } else { camera.start() }
    }

    /// Lower the frame rate at night or while a doorbell card is up.
    func setSlow(_ slow: Bool) {
        guard mode == .recognize else { return }
        camera.framesPerSecond = slow ? 1 : 6
    }

    /// The last clear look, if it was within the past couple of seconds. For Not-you picks.
    func recentEmbedding(within seconds: TimeInterval = 2) -> [Float]? {
        guard let recent, Date.now.timeIntervalSince(recent.at) <= seconds else { return nil }
        return recent.embedding
    }

    /// "Who's here?" picked someone while a face was in view: remember this look as theirs.
    func learn(_ memberID: UUID) {
        guard mode == .recognize, let embedding = recentEmbedding() else { return }
        store.learn(embedding, for: memberID)
        reset()
    }

    private func reset() {
        votes = []
        steady = nil
        recent = nil
    }

    /// Runs on the camera's queue.
    nonisolated private static func process(_ buffer: CVPixelBuffer) {
        let reading = FaceAnalyzer.read(buffer, embedder: FaceEmbedder.current)
        Task { @MainActor in
            FaceRecognizer.shared.handle(reading)
        }
    }

    private func handle(_ reading: FaceReading) {
        latest = reading
        switch mode {
        case .off:
            return
        case .enroll:
            onReading?(reading)
        case .recognize:
            recognize(reading)
        }
    }

    private func recognize(_ reading: FaceReading) {
        var vote: UUID?
        if reading.hasFace, reading.box.height >= Self.minimumFaceHeight, let embedding = reading.embedding, !store.isEmpty {
            recent = (embedding, reading.at)
            let ranked = FaceMath.rank(embedding, in: store.faces)
            scores = ranked
            let embedder = FaceEmbedder.current
            if let best = ranked.first, best.score >= embedder.matchThreshold,
               ranked.count < 2 || best.score - ranked[1].score >= embedder.margin {
                vote = best.id
            }
        } else if !reading.hasFace {
            scores = []
        }
        votes.append(vote)
        if votes.count > 4 { votes.removeFirst(votes.count - 4) }

        var counts: [UUID: Int] = [:]
        for case let id? in votes { counts[id, default: 0] += 1 }
        guard let winner = counts.first(where: { $0.value >= 3 })?.key else {
            if counts.isEmpty { steady = nil }
            return
        }
        if winner != steady {
            steady = winner
            steadySince = .now
        }
        onRecognized?(winner, Date.now.timeIntervalSince(steadySince))
    }
}
