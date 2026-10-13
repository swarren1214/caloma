import LocalAuthentication
import SwiftData
import SwiftUI

/// Kid View: the whole screen is one kid's day, in their color, with big buttons and a
/// celebration for every chore. Leaving it takes Face ID (or the passcode), so it's safe to
/// hand over a phone or leave on a shared iPad.
struct KidModeView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.kidViewMember) private var kidIDString = ""

    @State private var leaving = false
    @State private var cantAuthenticate = false

    private var kids: [Member] { members.filter { $0.isKid && !$0.isArchived } }
    private var kid: Member? {
        kids.first { $0.id.uuidString == kidIDString } ?? (kids.count == 1 ? kids.first : nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let kid {
                    KidDayView(kid: kid, canSwitch: kids.count > 1, onSwitch: { kidIDString = "" }, onLeave: leave)
                } else {
                    KidPicker(kids: kids, onPick: { kidIDString = $0.id.uuidString }, onLeave: leave)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(kid?.color.color ?? .accentColor)
        .confirmationDialog("Leave Kid View?", isPresented: $cantAuthenticate, titleVisibility: .visible) {
            Button("Leave Kid View") { router.kidViewOpen = false }
        } message: {
            Text("Set a passcode on this device so only a parent can leave Kid View.")
        }
    }

    /// Face ID or the passcode, then back to the parent's app.
    private func leave() {
        guard !leaving else { return }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            cantAuthenticate = true
            return
        }
        leaving = true
        Task {
            defer { leaving = false }
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Leave Kid View")) ?? false
            if ok { router.kidViewOpen = false }
        }
    }
}

/// "Who's doing chores?" Big avatar buttons, one per kid.
private struct KidPicker: View {
    var kids: [Member]
    var onPick: (Member) -> Void
    var onLeave: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("Who's doing chores?")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            if kids.isEmpty {
                Text("Add kids in Family first.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 20) {
                ForEach(kids) { kid in
                    Button {
                        onPick(kid)
                    } label: {
                        VStack(spacing: 12) {
                            MemberAvatar(kid, size: 110)
                                .shadow(color: kid.color.color.opacity(0.4), radius: 14, y: 8)
                            Text(kid.name)
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KidPressStyle())
                }
            }
            .frame(maxWidth: 640)
            Spacer()
            Button(action: onLeave) {
                Label("Parent", systemImage: "lock.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// Squishes a little when pressed, like a toy button.
struct KidPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.5), value: configuration.isPressed)
    }
}

/// One kid's day: hello, their stars, a progress track to the trophy, and their jobs.
struct KidDayView: View {
    var kid: Member
    var canSwitch: Bool
    var onSwitch: () -> Void
    var onLeave: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(filter: #Predicate<Reward> { $0.isFamilyGoal && !$0.isArchived }) private var goals: [Reward]

    /// The job celebrating right now, and where its button and the star counter are.
    @State private var celebrating: String?
    @State private var celebration = 0
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var counterFrame: CGRect = .zero
    @State private var flight: Flight?
    @State private var counterBump = 0
    @State private var showParty = false
    @State private var photoFor: BoardItem?

    private struct Flight: Identifiable, Equatable {
        let id = UUID()
        var from: CGPoint
        var to: CGPoint
    }

    private var color: Color { kid.color.color }
    private var words: PointWords { PointWords.current() }

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    var body: some View {
        let family = family
        let items = family.items(for: kid)
        let mine = items.filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
        let done = mine.filter { $0.status.isDone }.count
        ScrollView {
            VStack(spacing: 18) {
                header(family)
                ProgressTrack(done: done, total: mine.count, kid: kid)
                if items.isEmpty {
                    nothingToday
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items) { item in
                            JobTile(item: item, kid: kid, isNext: item.id == items.first(where: { $0.status == .open })?.id, isCelebrating: celebrating == item.id, celebration: celebration, compact: sizeClass == .compact) {
                                tapped(item, family: family)
                            }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("kid")) } action: { tileFrames[item.id] = $0 }
                            .zIndex(celebrating == item.id ? 1 : 0)
                        }
                    }
                }
                if sizeClass == .compact {
                    storeButton
                }
                if let goal = goals.first {
                    NavigationLink {
                        KidStoreView(kid: kid)
                    } label: {
                        GoalStrip(goal: goal, family: family, kid: kid)
                    }
                    .buttonStyle(KidPressStyle())
                }
                Text(mine.contains { $0.chore.requiresApproval } ? "\(words.title) show up after Mom or Dad says OK." : " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, sizeClass == .compact ? 16 : 28)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(color.opacity(0.07).ignoresSafeArea())
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .coordinateSpace(.named("kid"))
        .overlay {
            if let flight, !reduceMotion {
                FlyingStars(from: flight.from, to: flight.to)
                    .id(flight.id)
            }
        }
        .overlay {
            if showParty {
                AllDoneParty(kid: kid, pending: family.pending(of: kid), family: family) {
                    withAnimation(.smooth) { showParty = false }
                }
                .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: celebration)
        .sheet(item: $photoFor) { item in
            CameraPicker { image in
                finish(item, photo: PhotoTools.jpeg(from: image), family: family)
            }
            .ignoresSafeArea()
        }
    }

    private var columns: [GridItem] {
        sizeClass == .compact ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 260), spacing: 14)]
    }

    private func header(_ family: FamilySnapshot) -> some View {
        let mine = family.items(for: kid).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
        let done = mine.filter { $0.status.isDone }.count
        return HStack(spacing: 14) {
            Button(action: onSwitch) {
                MemberAvatar(kid, size: sizeClass == .compact ? 56 : 64)
            }
            .buttonStyle(KidPressStyle())
            .disabled(!canSwitch)
            .accessibilityLabel(canSwitch ? "Switch kid" : kid.name)

            VStack(alignment: .leading, spacing: 2) {
                Text("Hi, \(kid.name)!")
                    .font(.system(size: sizeClass == .compact ? 30 : 36, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(cheer(done: done, total: mine.count))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)

            starCounter(family)

            if sizeClass != .compact {
                NavigationLink {
                    KidStoreView(kid: kid)
                } label: {
                    Label("Store", systemImage: "gift.fill")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 20)
                        .frame(height: 60)
                        .foregroundStyle(.white)
                        .background(color, in: Capsule())
                        .shadow(color: color.opacity(0.35), radius: 10, y: 6)
                }
                .buttonStyle(KidPressStyle())
            }

            Button(action: onLeave) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Parent: leave Kid View")
        }
    }

    private var storeButton: some View {
        NavigationLink {
            KidStoreView(kid: kid)
        } label: {
            Label("My Store", systemImage: "gift.fill")
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(.white)
                .background(color, in: Capsule())
                .shadow(color: color.opacity(0.35), radius: 10, y: 6)
        }
        .buttonStyle(KidPressStyle())
    }

    private func starCounter(_ family: FamilySnapshot) -> some View {
        let pending = family.pending(of: kid)
        return HStack(spacing: 8) {
            Image(systemName: words.symbol)
                .font(.system(size: 30))
                .foregroundStyle(Brand.starBright)
                .symbolEffect(.bounce, value: counterBump)
            VStack(alignment: .leading, spacing: 0) {
                Text(family.balance(of: kid).formatted())
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if pending > 0 {
                    Text("+\(pending) on the way")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(minHeight: 60)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .phaseAnimator([1.0, 1.15, 1.0], trigger: counterBump) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in
            .spring(duration: 0.25, bounce: 0.5)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("kid")) } action: { counterFrame = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(words.count(family.balance(of: kid)))\(pending > 0 ? ", \(pending) on the way" : "")")
    }

    private var nothingToday: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 64))
                .foregroundStyle(Brand.starBright)
                .symbolEffect(.pulse, options: .repeat(.continuous))
            Text("No jobs today!")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("Go play.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30))
    }

    private func cheer(done: Int, total: Int) -> String {
        guard total > 0 else { return "Nothing to do today." }
        if done == total { return "All done. You're a star!" }
        if done == 0 { return "Let's get started!" }
        if total - done == 1 { return "One more to go!" }
        if done * 2 >= total { return "Over halfway there!" }
        return "You're on a roll!"
    }

    // MARK: Doing a job

    private func tapped(_ item: BoardItem, family: FamilySnapshot) {
        guard item.status == .open else { return }
        if item.chore.requiresPhoto {
            photoFor = item
        } else {
            finish(item, photo: nil, family: family)
        }
    }

    private func finish(_ item: BoardItem, photo: Data?, family: FamilySnapshot) {
        let mine = family.items(for: kid).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
        let openBefore = mine.filter { $0.status == .open }.count
        let isMine = mine.contains(where: { $0.id == item.id })
        let finishesDay = isMine && openBefore == 1

        withAnimation(.spring(duration: 0.45, bounce: 0.4)) {
            Family.markDone(item, by: kid.id, byParent: false, photo: photo, in: context)
            celebrating = item.id
            celebration += 1
        }
        if let tile = tileFrames[item.id], counterFrame != .zero {
            flight = Flight(from: CGPoint(x: tile.midX, y: tile.minY + tile.height * 0.35), to: CGPoint(x: counterFrame.minX + 30, y: counterFrame.midY))
        }
        let stamp = celebration
        Task {
            try? await Task.sleep(for: .milliseconds(1050))
            counterBump += 1
            try? await Task.sleep(for: .milliseconds(450))
            if celebration == stamp {
                celebrating = nil
                flight = nil
            }
        }
        if finishesDay {
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.smooth) { showParty = true }
            }
        }
    }
}

/// Avatar running along a track toward the trophy, one stop per job.
private struct ProgressTrack: View {
    var done: Int
    var total: Int
    var kid: Member

    @State private var hop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        HStack(spacing: 18) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 12)
                    Capsule()
                        .fill(kid.color.color)
                        .frame(width: max(12, width * fraction), height: 12)
                    ForEach(0..<max(total, 0), id: \.self) { index in
                        let reached = index < done
                        Circle()
                            .fill(reached ? kid.color.color : Color(.secondarySystemGroupedBackground))
                            .overlay(Circle().strokeBorder(reached ? Color.clear : Color(.systemGray3), lineWidth: 3))
                            .overlay {
                                if reached {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .heavy))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 26, height: 26)
                            .position(x: width * CGFloat(index + 1) / CGFloat(max(total, 1)), y: proxy.size.height / 2)
                    }
                    MemberAvatar(kid, size: 46)
                        .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 4))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
                        .offset(y: hop && !reduceMotion ? -5 : 0)
                        .position(x: min(max(23, width * fraction), width - 23), y: proxy.size.height / 2)
                }
            }
            .frame(height: 56)
            .animation(.spring(duration: 0.8, bounce: 0.4), value: done)

            Image(systemName: "trophy.fill")
                .font(.system(size: 28))
                .foregroundStyle(done == total && total > 0 ? Color.white : Color.secondary)
                .frame(width: 60, height: 60)
                .background(
                    done == total && total > 0
                        ? AnyShapeStyle(LinearGradient(colors: [Brand.starBright, Color(hex: 0xF59E0B)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color(.tertiarySystemFill)),
                    in: Circle()
                )
                .symbolEffect(.bounce, value: done == total)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { hop = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) jobs done")
    }
}

/// One job, big enough for small fingers. Pulses when it's the next one to do, and bursts into
/// confetti when it's done.
private struct JobTile: View {
    var item: BoardItem
    var kid: Member
    var isNext: Bool
    var isCelebrating: Bool
    var celebration: Int
    var compact: Bool
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color { kid.color.color }
    private var words: PointWords { PointWords.current() }
    private var open: Bool { item.status == .open }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 14) {
                    icon(size: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        title
                        subtitle
                    }
                    Spacer(minLength: 4)
                    button(width: 76, height: 58)
                }
                .padding(14)
            } else {
                VStack(spacing: 12) {
                    icon(size: 92)
                    VStack(spacing: 6) {
                        title.multilineTextAlignment(.center)
                        subtitle
                    }
                    Spacer(minLength: 0)
                    button(width: nil, height: 60)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(minHeight: 270)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30))
        .overlay {
            RoundedRectangle(cornerRadius: 30)
                .strokeBorder(color, lineWidth: open ? 0 : 4)
        }
        .overlay(alignment: .topTrailing) {
            if !open {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, item.status == .approved ? Color(hex: 0x1E9E6A) : color)
                    .padding(12)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .overlay {
            if isCelebrating && !reduceMotion {
                ZStack {
                    Circle()
                        .strokeBorder(color, lineWidth: 6)
                        .frame(width: 110, height: 110)
                        .modifier(RingPulse())
                    ConfettiBurst(colors: confettiColors(color))
                    FloatingPoints(points: item.points, color: color)
                }
                .id(celebration)
            }
        }
        .shadow(color: open ? .black.opacity(0.05) : color.opacity(0.25), radius: open ? 8 : 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    private func icon(size: CGFloat) -> some View {
        Image(systemName: item.chore.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(open ? color : .white)
            .frame(width: size, height: size)
            .background(open ? color.opacity(0.14) : color, in: Circle())
            .symbolEffect(.wiggle, value: isCelebrating ? celebration : 0)
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text(item.chore.title)
            .font(.system(size: compact ? 20 : 23, weight: .heavy, design: .rounded))
            .strikethrough(item.status == .approved)
            .foregroundStyle(item.status == .approved ? .secondary : .primary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    private var subtitle: some View {
        Text(subtitleText)
            .font(.system(size: compact ? 15 : 17, weight: .bold, design: .rounded))
            .foregroundStyle(subtitleColor)
            .contentTransition(.opacity)
    }

    private var subtitleText: String {
        switch item.status {
        case .open:
            if item.wasSentBack { return "Mom or Dad asked to try again" }
            if item.chore.upForGrabs { return "Up for grabs! \(words.count(item.points))" }
            if item.chore.requiresPhoto { return "Snap a photo when you're done" }
            return words.count(item.points)
        case .pending:
            return "Great job! \(words.count(item.points)) coming"
        case .approved:
            return "\(words.title) are in your jar!"
        }
    }

    private var subtitleColor: Color {
        switch item.status {
        case .open: item.wasSentBack ? Brand.waiting : .secondary
        case .pending: color
        case .approved: Color(hex: 0x1E9E6A)
        }
    }

    @ViewBuilder
    private func button(width: CGFloat?, height: CGFloat) -> some View {
        Button(action: action) {
            Group {
                if open {
                    if item.chore.requiresPhoto {
                        Label(compact ? "" : "Snap a photo", systemImage: "camera.fill")
                            .labelStyle(.titleAndIcon)
                    } else if item.chore.upForGrabs {
                        Text(compact ? "Mine!" : "I'll do it!")
                    } else {
                        Text(compact ? "Done!" : "I did it!")
                    }
                } else {
                    Image(systemName: "checkmark")
                }
            }
            .font(.system(size: compact ? 18 : 22, weight: .heavy, design: .rounded))
            .foregroundStyle(open ? .white : color)
            .frame(maxWidth: width == nil ? .infinity : width, minHeight: height)
            .frame(width: width)
            .background(open ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.13)), in: Capsule())
            .shadow(color: open ? color.opacity(0.35) : .clear, radius: 10, y: 6)
            .scaleEffect(isNext && pulse && !reduceMotion ? 1.05 : 1)
        }
        .buttonStyle(KidPressStyle())
        .disabled(!open)
        .accessibilityLabel(open ? (item.chore.requiresPhoto ? "Take a photo and mark \(item.chore.title) done" : "Mark \(item.chore.title) done") : "\(item.chore.title) is done")
        .onAppear {
            guard isNext else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: isNext) { _, next in
            if next {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
    }
}

/// A ring that grows and fades once.
private struct RingPulse: ViewModifier {
    @State private var grown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(grown ? 2.4 : 0.3)
            .opacity(grown ? 0 : 0.8)
            .animation(.easeOut(duration: 0.65), value: grown)
            .task {
                try? await Task.sleep(for: .milliseconds(10))
                grown = true
            }
    }
}

/// The family goal, with this kid's share, at the bottom of their day.
private struct GoalStrip: View {
    var goal: Reward
    var family: FamilySnapshot
    var kid: Member

    var body: some View {
        let progress = ChoreMath.goalProgress(goal.id, entries: family.points)
        HStack(spacing: 14) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(kid.color.color, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Family goal: \(goal.name)")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                    Spacer()
                    Text("\(progress.formatted()) / \(goal.cost.formatted())")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: min(Double(progress) / Double(max(goal.cost, 1)), 1))
                    .tint(kid.color.color)
            }
            Image(systemName: "chevron.right")
                .font(.headline)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
    }
}

/// Every job done: confetti over everything, a trophy on spinning rays, and the goal bar.
private struct AllDoneParty: View {
    var kid: Member
    var pending: Int
    var family: FamilySnapshot
    var onClose: () -> Void

    @State private var shown = false
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            if !reduceMotion {
                ConfettiRain(colors: confettiColors(kid.color.color))
            }
            VStack(spacing: 14) {
                ZStack {
                    Sunburst()
                        .fill(Brand.starBright.opacity(0.35))
                        .frame(width: 190, height: 190)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.white)
                        .frame(width: 118, height: 118)
                        .background(LinearGradient(colors: [Brand.starBright, Color(hex: 0xF59E0B)], startPoint: .top, endPoint: .bottom), in: Circle())
                        .shadow(color: .orange.opacity(0.45), radius: 16, y: 10)
                        .scaleEffect(shown ? 1 : 0.3)
                        .animation(.spring(duration: 0.6, bounce: 0.55).delay(0.25), value: shown)
                        .symbolEffect(.bounce, value: shown)
                }
                Text("You did it, \(kid.name)!")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(kid.color.color)
                    .multilineTextAlignment(.center)
                Text(pending > 0 ? "Every job is done today. Your \(PointWords.current().count(pending)) are on the way to Mom and Dad." : "Every job is done today!")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onClose) {
                    Text("Yay!")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .foregroundStyle(.white)
                        .background(kid.color.color, in: Capsule())
                }
                .buttonStyle(KidPressStyle())
                .padding(.top, 6)
            }
            .padding(32)
            .frame(maxWidth: 520)
            .background(Color(.systemBackground), in: .rect(cornerRadius: 40))
            .shadow(color: .black.opacity(0.3), radius: 40, y: 20)
            .padding(24)
            .scaleEffect(shown ? 1 : 0.85)
            .offset(y: shown ? 0 : 40)
            .opacity(shown ? 1 : 0)
            .animation(.spring(duration: 0.55, bounce: 0.4), value: shown)
        }
        .sensoryFeedback(.success, trigger: shown)
        .onAppear {
            shown = true
            if !reduceMotion {
                withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

#Preview("Kid View") {
    KidModeView()
        .previewEnvironment()
}
