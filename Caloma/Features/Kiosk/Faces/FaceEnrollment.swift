import SwiftData
import SwiftUI

/// Face setup, step by step, like Face ID's: hold still in the circle, then two slow head
/// circles. Each of the 72 ticks lights when the camera gets a clear look from that angle,
/// so the ring is real progress, not a timer. The clearest look from each part of the circle
/// becomes this person's face; photos are never kept.
@Observable
final class EnrollmentModel {
    enum Step: Equatable {
        case intro, position, scanning, firstScanDone, done
        case failed(String)
    }

    let memberID: UUID
    let name: String
    /// Other people already set up, for checking the new face isn't someone else's.
    let others: [UUID: String]

    private(set) var step: Step = .intro
    private(set) var pass = 1
    private(set) var lit = Array(repeating: false, count: EnrollmentModel.tickCount)
    private(set) var hint: String?
    /// Accessibility: one scan, and fewer angles needed.
    var oneScan = false

    static let tickCount = 72
    private static let sectors = 12

    private var collected: [[Float]] = []
    private var sectorBest: [Int: (quality: Double, embedding: [Float])] = [:]
    private var frontal: [(quality: Double, embedding: [Float])] = []
    private var heldSince: Date?
    private var passStarted = Date.now

    init(memberID: UUID, name: String, others: [UUID: String]) {
        self.memberID = memberID
        self.name = name
        self.others = others
    }

    var litCount: Int { lit.filter { $0 }.count }
    var progress: Double { Double(litCount) / Double(Self.tickCount) }

    func begin() {
        step = .position
        hint = nil
        heldSince = nil
    }

    func nextScan() {
        pass = 2
        startPass()
    }

    func retry() {
        collected = []
        pass = 1
        lit = Array(repeating: false, count: Self.tickCount)
        begin()
    }

    func handle(_ reading: FaceReading) {
        switch step {
        case .position: position(reading)
        case .scanning: scan(reading)
        default: break
        }
    }

    // MARK: Steps

    private func position(_ reading: FaceReading) {
        guard reading.hasFace else {
            hint = nil
            heldSince = nil
            return
        }
        guard reading.faceCount == 1 else {
            hint = "Just one person, please."
            heldSince = nil
            return
        }
        let size = reading.box.height
        if size < 0.18 {
            hint = "Move a little closer."
        } else if size > 0.7 {
            hint = "Move back a little."
        } else if abs(reading.box.midX - 0.5) > 0.18 || abs(reading.box.midY - 0.5) > 0.2 {
            hint = "Move into the circle."
        } else if reading.quality < 0.3 {
            hint = "Find a little more light."
        } else {
            hint = nil
            if heldSince == nil { heldSince = .now }
            if let heldSince, Date.now.timeIntervalSince(heldSince) >= 0.6 {
                startPass()
            }
            return
        }
        heldSince = nil
    }

    private func startPass() {
        lit = Array(repeating: false, count: Self.tickCount)
        sectorBest = [:]
        frontal = []
        hint = nil
        passStarted = .now
        step = .scanning
    }

    private func scan(_ reading: FaceReading) {
        guard reading.hasFace else {
            hint = "Keep your face in the circle."
            return
        }
        guard reading.faceCount == 1 else {
            hint = "Just one person, please."
            return
        }
        // Turned heads read as less clear, so the bar is lower here than for holding still.
        guard reading.quality >= FaceAnalyzer.minimumQuality, let embedding = reading.embedding else { return }
        hint = nil

        // The preview is mirrored, so turning right moves right on the ring.
        let x = -reading.yaw
        let y = -reading.pitch
        let magnitude = (x * x + y * y).squareRoot()
        if magnitude < 7 {
            frontal.append((reading.quality, embedding))
            frontal.sort { $0.quality > $1.quality }
            if frontal.count > 2 { frontal.removeLast(frontal.count - 2) }
        } else {
            // Clockwise from the top, like the ring.
            var degrees = atan2(x, y) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            let tick = Int((degrees / (360 / Double(Self.tickCount))).rounded()) % Self.tickCount
            for offset in -2...2 {
                lit[(tick + offset + Self.tickCount) % Self.tickCount] = true
            }
            let sector = tick * Self.sectors / Self.tickCount
            if reading.quality > sectorBest[sector]?.quality ?? -1 {
                sectorBest[sector] = (reading.quality, embedding)
            }
        }

        let elapsed = Date.now.timeIntervalSince(passStarted)
        let needed = oneScan ? 40 : 66
        let enough = litCount >= needed || (elapsed > 20 && litCount >= (oneScan ? 30 : 50)) || (elapsed > 45 && litCount >= 24)
        if elapsed > 30 && litCount < 24 {
            hint = "Turn your head a little more, slowly."
        }
        guard enough, !sectorBest.isEmpty || !frontal.isEmpty else { return }
        lit = Array(repeating: true, count: Self.tickCount)
        collected += sectorBest.values.map { $0.embedding } + frontal.map { $0.embedding }
        if pass == 1 && !oneScan {
            step = .firstScanDone
        } else {
            finish()
        }
    }

    private func finish() {
        guard collected.count >= 6 else {
            step = .failed("Caloma couldn't get a clear enough look. Try somewhere brighter.")
            return
        }
        // Each new look gets the same test the wall uses. If a third of them would be taken
        // for someone already set up, this isn't safe to save.
        let embedder = FaceEmbedder.current
        let rivals = FaceStore.shared.faces.filter { $0.key != memberID }
        var hits: [UUID: Int] = [:]
        for look in collected {
            if let best = FaceMath.rank(look, in: rivals).first, best.score >= embedder.matchThreshold {
                hits[best.id, default: 0] += 1
            }
        }
        if let rival = hits.max(by: { $0.value < $1.value }), rival.value * 3 > collected.count {
            step = .failed("That looked a lot like \(others[rival.key] ?? "someone else"). Let's try again, with just \(name) in view.")
            return
        }
        FaceStore.shared.set(collected, for: memberID)
        step = .done
    }
}

/// The face setup sheet: intro, the camera in a ring of ticks for two scans, and done.
struct FaceEnrollmentView: View {
    var member: Member
    /// Who's next, for Set Up Another Person.
    var onAnother: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var model: EnrollmentModel?
    private let recognizer = FaceRecognizer.shared

    private var color: Color { member.color.color }
    private var isKid: Bool { member.isKid }

    var body: some View {
        NavigationStack {
            Group {
                if let model, model.memberID == member.id {
                    content(model)
                } else {
                    Color.clear
                }
            }
            .toolbar {
                if model?.step != .done {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .onChange(of: member.id) { _, _ in makeModel() }
        .onAppear { makeModel() }
        .onDisappear {
            recognizer.onReading = nil
            recognizer.stop()
        }
        .interactiveDismissDisabled(model?.step == .scanning)
        .sensoryFeedback(.success, trigger: model?.step == .done)
    }

    /// A fresh setup for whoever is showing (Set Up Another swaps the person in place).
    private func makeModel() {
        let others = Dictionary(uniqueKeysWithValues: members.filter { $0.id != member.id }.map { ($0.id, $0.name) })
        let model = EnrollmentModel(memberID: member.id, name: member.name, others: others)
        self.model = model
        recognizer.stop()
        recognizer.onReading = { [weak model] reading in model?.handle(reading) }
    }

    @ViewBuilder
    private func content(_ model: EnrollmentModel) -> some View {
        switch model.step {
        case .intro:
            intro(model)
        case .position, .scanning, .firstScanDone:
            scanner(model)
        case .done:
            done(model)
        case .failed(let message):
            failed(model, message)
        }
    }

    // MARK: Intro

    private func intro(_ model: EnrollmentModel) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Image(systemName: "faceid")
                .font(.system(size: 120, weight: .thin))
                .foregroundStyle(color)
                .symbolEffect(.pulse)
                .padding(.bottom, 36)
            Text("Set Up Faces for \(member.name)")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(isKid
                 ? "\(member.name) looks at the iPad and slowly turns their head in a circle. Caloma learns their face so the wall can say hi and open their chores when they walk up."
                 : "Look at the iPad and slowly turn your head in a circle. Caloma learns your face so the wall can open your tasks and what's waiting on you.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.top, 14)
            Spacer(minLength: 24)
            Label {
                Text("Stays on this iPad and never leaves it. Faces only open someone's day; they never approve, unlock or pay.")
            } icon: {
                Image(systemName: "checkmark.shield")
                    .font(.title2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.bottom, 18)
            Button {
                Task {
                    await recognizer.start(.enroll)
                    if !recognizer.cameraDenied {
                        withAnimation(.smooth) { model.begin() }
                    }
                }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: 440, minHeight: 54)
            }
            .buttonStyle(.glassProminent)
            if recognizer.cameraDenied {
                Text("Caloma needs the camera. Turn it on in Settings › Caloma › Camera.")
                    .font(.footnote)
                    .foregroundStyle(Brand.late)
                    .padding(.top, 8)
            }
            Button("Set Up Later") { dismiss() }
                .padding(.vertical, 12)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    // MARK: Scanning

    private func scanner(_ model: EnrollmentModel) -> some View {
        let between = model.step == .firstScanDone
        return VStack(spacing: 10) {
            Text(title(model))
                .font(.title.bold())
                .contentTransition(.opacity)
                .animation(.smooth, value: model.step)
            Text(model.hint ?? detail(model))
                .font(.title3)
                .foregroundStyle(model.hint == nil ? Color.secondary : Brand.waiting)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440, minHeight: 56, alignment: .top)
                .animation(.smooth, value: model.hint)

            ZStack {
                TickRing(lit: model.lit, dim: model.step == .position)
                FaceCameraPreview(camera: recognizer.camera)
                    .frame(width: 300, height: 300)
                    .clipShape(Circle())
                    .blur(radius: between ? 8 : 0)
                    .overlay {
                        if model.step == .position {
                            Circle()
                                .strokeBorder(.white.opacity(0.75), style: StrokeStyle(lineWidth: 3, dash: [8, 8]))
                                .padding(36)
                        }
                    }
                if between {
                    Image(systemName: "checkmark")
                        .font(.system(size: 50, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(Color(hex: 0x34C759), in: Circle())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 400, height: 400)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: between)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Face scan")
            .accessibilityValue("\(Int(model.progress * 100)) percent")

            Spacer(minLength: 12)
            if between {
                Button {
                    withAnimation(.smooth) { model.nextScan() }
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: 440, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .transition(.opacity)
            } else if model.pass == 1 {
                Button(model.oneScan ? "Use Two Scans" : "Accessibility: One Scan Only") {
                    model.oneScan.toggle()
                }
                .font(.subheadline)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.impact(weight: .light), trigger: model.litCount / 12)
        .sensoryFeedback(.success, trigger: between)
    }

    private func title(_ model: EnrollmentModel) -> String {
        switch model.step {
        case .position: "Position \(isKid ? member.name + "'s face" : "your face") in the circle"
        case .firstScanDone: "First scan complete"
        default: model.pass == 1 ? "Move your head slowly" : "One more circle"
        }
    }

    private func detail(_ model: EnrollmentModel) -> String {
        switch model.step {
        case .position: isKid ? "Have \(member.name) stand about an arm's length away and look at the screen." : "Stand about an arm's length away and look at the screen."
        case .firstScanDone: "Nice. One more turn, a little slower this time."
        default: model.pass == 1 ? "Keep looking at the iPad and roll your head in a circle until the ring is all green." : "Same as before. Slow and steady."
        }
    }

    // MARK: Done

    private func done(_ model: EnrollmentModel) -> some View {
        let next = members.first { !$0.isArchived && $0.id != member.id && !FaceStore.shared.isEnrolled($0.id) }
        return VStack(spacing: 0) {
            Spacer(minLength: 20)
            DoneCheck(reduceMotion: reduceMotion)
                .padding(.bottom, 40)
            Text("\(member.name) Is Set Up")
                .font(.largeTitle.bold())
            Text(isKid
                 ? "Next time \(member.name) walks up to the wall, Caloma will say hi and show their chores, \(PointWords.current().plural) and what's next."
                 : "Next time you walk up, Caloma will open your tasks and show what needs your OK. Approving still takes the PIN.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, 14)
            HStack(spacing: 12) {
                MemberAvatar(member, size: 44)
                    .overlay(Circle().strokeBorder(color, lineWidth: 3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isKid ? "There you are, \(member.name)!" : "\(kioskGreeting()), \(member.name)")
                        .font(.headline)
                    Text("What \(member.name) will see on the wall")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .padding(.trailing, 6)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 18))
            .padding(.top, 26)
            Spacer(minLength: 24)
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: 440, minHeight: 54)
            }
            .buttonStyle(.glassProminent)
            if let next, let onAnother {
                Button("Set Up \(next.name)") {
                    onAnother(next.id)
                }
                .padding(.vertical, 12)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func failed(_ model: EnrollmentModel, _ message: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Brand.waiting)
            Text("That Didn't Look Right")
                .font(.title.bold())
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Spacer()
            Button {
                withAnimation(.smooth) { model.retry() }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .frame(maxWidth: 440, minHeight: 54)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// 72 ticks around the camera, grey until a clear look from that angle lights them green.
private struct TickRing: View {
    var lit: [Bool]
    var dim: Bool

    var body: some View {
        ZStack {
            ForEach(0..<lit.count, id: \.self) { index in
                let on = lit[index]
                Capsule()
                    .fill(on ? Color(hex: 0x34C759) : Color(.systemGray3))
                    .frame(width: 4, height: on ? 22 : 14)
                    .offset(y: -(170 + (on ? 11 : 7)))
                    .rotationEffect(.degrees(Double(index) * 360 / Double(lit.count)))
                    .animation(.easeOut(duration: 0.25), value: on)
            }
        }
        .opacity(dim ? 0.5 : 1)
        .animation(.smooth, value: dim)
    }
}

/// The green ring and check at the end, drawn in.
private struct DoneCheck: View {
    var reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: 0x34C759), lineWidth: 6)
                .frame(width: 168, height: 168)
                .scaleEffect(shown || reduceMotion ? 1 : 0.7)
                .opacity(shown || reduceMotion ? 1 : 0)
            CheckShape()
                .trim(from: 0, to: shown || reduceMotion ? 1 : 0)
                .stroke(Color(hex: 0x34C759), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .frame(width: 76, height: 56)
        }
        .shadow(color: Color(hex: 0x34C759).opacity(shown ? 0.35 : 0), radius: 24)
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.35)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}

nonisolated private struct CheckShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
