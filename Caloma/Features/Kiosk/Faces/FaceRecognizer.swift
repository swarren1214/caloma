import Foundation
import SwiftUI

/// The faces Caloma knows, on this iPad only: a set of embeddings per family member, never
/// photos. Kept in a protected file that isn't backed up or synced.
@Observable
final class FaceStore {
    static let shared = FaceStore()

    private(set) var faces: [UUID: [[Float]]] = [:]
    /// What the wall matches against: built from everyone's looks whenever they change.
    @ObservationIgnored private(set) var family = FamilyFaceModel.empty
    /// The model trained on this family's looks (two or more people set up). Retrained in the
    /// background whenever a face is saved, learned or erased.
    @ObservationIgnored private(set) var classifier: FamilyClassifier?
    /// How the classifier did on the looks it held back, for the Faces screen.
    private(set) var report: FamilyClassifier.Report?
    private(set) var isTraining = false
    @ObservationIgnored private var generation = 0

    /// Faces were made by an older matcher and erased: everyone needs setting up again.
    private(set) var needsSetupAgain = false

    /// Looks per person: setup saves up to about 60; picks on the wall add to these up to
    /// `maximum`.
    static let maximum = 90
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
        needsSetupAgain = false
        faces[id] = embeddings
        setupCounts[id] = embeddings.count
        rebuild()
        save()
    }

    /// A pick on the wall: one more look at this person, if they've been set up and the look
    /// isn't clearly someone else's. `confirmed` is for a look backed by their passcode.
    func learn(_ embedding: [Float], for id: UUID, confirmed: Bool = false) {
        guard var stored = faces[id], !stored.isEmpty else { return }
        guard confirmed || leans(embedding, toward: id) else { return }
        stored.append(embedding)
        let kept = setupCounts[id] ?? 0
        if stored.count > Self.maximum, stored.count > kept {
            // Drop the oldest learned look; setup's looks stay.
            stored.remove(at: min(kept, stored.count - 1))
        }
        faces[id] = stored
        rebuild()
        save()
    }

    func erase(_ id: UUID) {
        faces[id] = nil
        setupCounts[id] = nil
        rebuild()
        save()
    }

    func eraseAll() {
        faces = [:]
        setupCounts = [:]
        rebuild()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Matching

    /// Who this look is: the family classifier when two or more people are set up, the face
    /// model alone before that. A guest or a friend over (not plausibly anyone set up, by the
    /// face print) is nobody either way.
    func judge(_ look: [Float]) -> (scores: [FamilyFaceModel.Score], chances: [FamilyClassifier.Chance], verdict: FamilyFaceModel.Verdict) {
        let embedder = FaceEmbedder.current
        let scores = family.scores(look)
        guard let classifier else {
            return (scores, [], family.verdict(scores, embedder: embedder))
        }
        let chances = classifier.chances(look).filter { faces[$0.id] != nil }
        guard let top = chances.first,
              let plain = scores.first(where: { $0.id == top.id })?.plain,
              plain >= embedder.guestFloor else { return (scores, chances, .nobody) }
        let second = chances.count > 1 ? chances[1] : nil
        if top.probability >= Self.matchChance, top.probability - (second?.probability ?? 0) >= Self.matchLead {
            return (scores, chances, .match(top.id))
        }
        if let second, second.probability >= Self.closeCallChance {
            return (scores, chances, .closeCall(top.id, second.id))
        }
        return (scores, chances, .nobody)
    }

    /// A match needs at least this chance, this far ahead of the next person.
    static let matchChance: Float = 0.85
    static let matchLead: Float = 0.5
    /// Two people each at least this likely, with neither a match: ask which.
    static let closeCallChance: Float = 0.2

    /// Whether a look is safe to keep as this person's: the wall was already leaning their
    /// way, or it was a close call they were part of.
    private func leans(_ look: [Float], toward id: UUID) -> Bool {
        guard let classifier else { return family.leans(look, toward: id, embedder: FaceEmbedder.current) }
        let chances = classifier.chances(look)
        guard let top = chances.first, let theirs = chances.first(where: { $0.id == id }) else { return false }
        if top.id == id { return theirs.probability >= 0.4 }
        return theirs.probability >= Self.closeCallChance && top.probability < Self.matchChance
    }

    private func rebuild() {
        family = FamilyFaceModel(faces: faces)
        generation += 1
        let generation = generation
        let snapshot = faces
        isTraining = true
        Task.detached(priority: .utility) {
            let trained = FamilyClassifier(faces: snapshot)
            await MainActor.run { FaceStore.shared.adopt(trained, generation: generation) }
        }
    }

    private func adopt(_ trained: FamilyClassifier?, generation: Int) {
        guard generation == self.generation else { return }
        classifier = trained
        report = trained?.report
        isTraining = false
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        // Faces made by another embedder can't be compared; they need setting up again.
        guard file.embedder == FaceEmbedder.current.id else {
            try? FileManager.default.removeItem(at: url)
            needsSetupAgain = !file.faces.isEmpty
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
        rebuild()
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

/// Where the person the wall is following was last seen, shared with the camera's queue so
/// each frame reads their face first.
nonisolated final class FaceTarget: @unchecked Sendable {
    static let shared = FaceTarget()
    private let lock = NSLock()
    private var _box: CGRect?
    var box: CGRect? {
        get { lock.withLock { _box } }
        set { lock.withLock { _box = newValue } }
    }
}

/// Watches the front camera on the Family Board and says who's there. Only a confident, steady
/// match counts: the best person must stand well clear of how close the rest of the family
/// usually comes, beat the next person by a margin, and win 3 of the last 4 looks. When two
/// people keep coming out about even, it says so instead of guessing. Face setup borrows the
/// same camera.
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
    private(set) var scores: [FamilyFaceModel.Score] = []
    /// The family classifier's chance for each person, best first (empty before two people
    /// are set up).
    private(set) var chances: [FamilyClassifier.Chance] = []
    /// What the latest look was judged to be.
    private(set) var verdict: FamilyFaceModel.Verdict = .nobody

    @ObservationIgnored let camera = FaceCamera()
    @ObservationIgnored private let store = FaceStore.shared

    /// Kiosk Mode: someone was recognized, and how long they've been the steady answer.
    @ObservationIgnored var onRecognized: ((UUID, TimeInterval) -> Void)?
    /// Family Board: the person the wall was following has gone out of view.
    @ObservationIgnored var onLeft: ((UUID) -> Void)?
    /// Who the wall is following: once someone is recognized, it stays with their face until
    /// it's been out of view for `leaveAfter`, whoever else steps in.
    private(set) var following: UUID?
    @ObservationIgnored private var lostSince: Date?
    @ObservationIgnored private var slow = false
    /// Family Board: two people keep coming out about even (best first), with the look.
    @ObservationIgnored var onCloseCall: ((UUID, UUID, [Float]) -> Void)?
    /// Face setup: every look.
    @ObservationIgnored var onReading: ((FaceReading) -> Void)?

    @ObservationIgnored private var votes: [FamilyFaceModel.Verdict] = []
    @ObservationIgnored private var askedPair: Set<UUID>?
    @ObservationIgnored private var steady: UUID?
    @ObservationIgnored private var steadySince = Date.now
    @ObservationIgnored private var recent: (embedding: [Float], at: Date)?
    /// The last few clear looks at the face in view, for pooling.
    @ObservationIgnored private var track: [(embedding: [Float], quality: Double, box: CGRect, at: Date)] = []

    /// Looks pooled together: a face only counts as the same one while it stays put.
    static let trackLength = 5
    static let trackWindow: TimeInterval = 1.5

    /// How long the followed face can be out of view before they count as gone.
    static let leaveAfter: TimeInterval = 1.5
    /// Frames a second: brisk with a face in view, an easy watch for one otherwise, and a slow
    /// one at night. Even the slow watch is quick enough that walking up feels immediate.
    static let fastRate: Double = 10
    static let watchRate: Double = 4
    static let nightRate: Double = 3
    /// A match needs this many of the last `voteWindow` looks.
    static let voteWindow = 3
    static let votesNeeded = 2

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
        // Setup averages several views of each look, so it looks a little less often.
        camera.framesPerSecond = mode == .enroll ? 8 : Self.watchRate
        let forSetup = mode == .enroll
        camera.onFrame = { FaceRecognizer.process($0, forSetup: forSetup) }
        camera.start()
    }

    func stop() {
        mode = .off
        camera.onFrame = nil
        camera.stop()
        reset()
        latest = .nobody
        scores = []
        chances = []
        verdict = .nobody
    }

    /// Stops looking for a moment (Face ID needs the camera), then carries on.
    func pause(_ paused: Bool) {
        guard mode == .recognize else { return }
        if paused { camera.stop() } else { camera.start() }
    }

    /// Lower the frame rate at night or while a doorbell card is up.
    func setSlow(_ slow: Bool) {
        self.slow = slow
        guard mode == .recognize else { return }
        camera.framesPerSecond = slow ? Self.nightRate : Self.watchRate
    }

    /// The last clear look, if it was within the past couple of seconds. For Not-you picks.
    func recentEmbedding(within seconds: TimeInterval = 2) -> [Float]? {
        guard let recent, Date.now.timeIntervalSince(recent.at) <= seconds else { return nil }
        return recent.embedding
    }

    /// "Who's here?" picked someone while a face was in view: remember this look as theirs,
    /// unless it's clearly closer to someone else.
    func learn(_ memberID: UUID) {
        guard mode == .recognize, let embedding = recentEmbedding() else { return }
        store.learn(embedding, for: memberID)
        reset()
    }

    private func reset() {
        votes = []
        steady = nil
        recent = nil
        askedPair = nil
        track = []
        following = nil
        lostSince = nil
        FaceTarget.shared.box = nil
    }

    /// Runs on the camera's queue.
    nonisolated private static func process(_ buffer: CVPixelBuffer, forSetup: Bool) {
        let reading = FaceAnalyzer.read(buffer, embedder: FaceEmbedder.current, forSetup: forSetup, target: forSetup ? nil : FaceTarget.shared.box)
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

    private func pooled(_ look: [Float], _ reading: FaceReading) -> [Float] {
        if let last = track.last {
            let moved = Self.overlap(last.box, reading.box) < 0.3
            // Someone else stepped into the same spot: start over, so the last person's looks
            // don't blend into theirs and their old votes don't have to be outvoted.
            let pooled = FaceMath.weightedCentroid(track.map { ($0.embedding, Float(max($0.quality, 0.05))) })
            let someoneElse = pooled.map { FaceMath.similarity(FaceFeatures.face($0), FaceFeatures.face(look)) < FaceEmbedder.current.matchThreshold - 0.02 } ?? false
            if someoneElse {
                votes = []
                askedPair = nil
            }
            if moved || someoneElse || reading.at.timeIntervalSince(last.at) > 1 { track = [] }
        }
        track.append((look, reading.quality, reading.box, reading.at))
        track.removeAll { reading.at.timeIntervalSince($0.at) > Self.trackWindow }
        if track.count > Self.trackLength { track.removeFirst(track.count - Self.trackLength) }
        return FaceMath.weightedCentroid(track.map { ($0.embedding, Float(max($0.quality, 0.05))) }) ?? look
    }

    /// Intersection over union of two boxes.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        let both = a.width * a.height + b.width * b.height - shared.width * shared.height
        return both > 0 ? shared.width * shared.height / both : 0
    }

    private func recognize(_ reading: FaceReading) {
        // Look briskly while there's a face to read, easily otherwise.
        let rate = slow && !reading.hasFace ? Self.nightRate : reading.hasFace ? Self.fastRate : Self.watchRate
        if camera.framesPerSecond != rate { camera.framesPerSecond = rate }

        // Stay with the person being followed: their face is read first, and anyone else is
        // ignored until they've been out of view for a moment.
        if let followed = following {
            if reading.hasFace, reading.onTarget {
                lostSince = nil
                FaceTarget.shared.box = reading.box
            } else {
                let since = lostSince ?? reading.at
                lostSince = since
                guard reading.at.timeIntervalSince(since) >= Self.leaveAfter else {
                    verdict = .nobody
                    return
                }
                // Gone: let them go, and start fresh for whoever's next.
                votes = []
                track = []
                steady = nil
                askedPair = nil
                following = nil
                lostSince = nil
                FaceTarget.shared.box = nil
                onLeft?(followed)
            }
        }

        var vote = FamilyFaceModel.Verdict.nobody
        if reading.hasFace, let look = reading.embedding, !store.isEmpty {
            // One frame is noisy; the same face over the last second and a bit is not. Pool the
            // last few looks, clearer ones counting for more, as long as it's still the same
            // face in about the same place.
            let embedding = pooled(look, reading)
            recent = (embedding, reading.at)
            let judged = store.judge(embedding)
            scores = judged.scores
            chances = judged.chances
            vote = judged.verdict
        } else if !reading.hasFace {
            scores = []
            chances = []
            askedPair = nil
            track = []
        }
        verdict = vote
        votes.append(vote)
        if votes.count > Self.voteWindow { votes.removeFirst(votes.count - Self.voteWindow) }

        var counts: [UUID: Int] = [:]
        var pairs: [Set<UUID>: (count: Int, order: (UUID, UUID))] = [:]
        for vote in votes {
            switch vote {
            case .match(let id):
                counts[id, default: 0] += 1
            case .closeCall(let first, let second):
                let pair: Set<UUID> = [first, second]
                pairs[pair] = ((pairs[pair]?.count ?? 0) + 1, (first, second))
            case .nobody:
                break
            }
        }
        // While following someone, only a clear run of looks (every recent one) says it's
        // actually someone else; one odd look never switches people.
        let needed = following == nil ? Self.votesNeeded : Self.voteWindow
        guard let candidate = counts.first(where: { $0.value >= needed })?.key ?? following else {
            if counts.isEmpty { steady = nil }
            // The same two people, about even, in most recent looks: ask once while they stay.
            if let found = pairs.first(where: { $0.value.count >= Self.votesNeeded }), found.key != askedPair, let recent {
                askedPair = found.key
                onCloseCall?(found.value.order.0, found.value.order.1, recent.embedding)
            }
            return
        }
        let winner = candidate
        following = winner
        lostSince = nil
        if reading.hasFace { FaceTarget.shared.box = reading.box }
        if winner != steady {
            steady = winner
            steadySince = .now
        }
        onRecognized?(winner, Date.now.timeIntervalSince(steadySince))
    }
}
