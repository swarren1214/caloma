import SwiftData
import SwiftUI

/// A kid's store: a jar filling toward the reward they're saving for, the family goal they can
/// chip in to, and every reward with a big "Get it!" when they have enough.
struct KidStoreView: View {
    var kid: Member

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]
    @Query(filter: #Predicate<Reward> { !$0.isArchived }, sort: \Reward.cost) private var rewards: [Reward]

    @State private var asking: Reward?
    @State private var spent = 0
    @State private var spentKey = 0
    @State private var chippingIn = false
    /// The reward this kid picked to save for.
    @State private var savingID: String?
    @State private var choosingGoal = false

    private var color: Color { kid.color.color }
    private var words: PointWords { PointWords.current() }
    private var goalKey: String { "kidGoal." + kid.id.uuidString }

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    private var store: [Reward] { rewards.filter { !$0.isFamilyGoal && $0.isAvailable(to: kid.id) } }
    private var familyGoal: Reward? { rewards.first { $0.isFamilyGoal } }

    /// The reward this kid picked to save for (Change on the jar), else the cheapest one they
    /// can't afford yet.
    private func savingFor(_ spendable: Int) -> Reward? {
        if let id = savingID, let pinned = store.first(where: { $0.id.uuidString == id }) {
            return pinned
        }
        return store.first { $0.cost > spendable } ?? store.last
    }

    var body: some View {
        let family = family
        let spendable = family.spendable(of: kid)
        let goal = savingFor(spendable)
        ScrollView {
            VStack(spacing: 18) {
                header(spendable)
                if sizeClass == .compact {
                    if let goal { jar(goal, family, spendable, compact: true) }
                    rewardGrid(family, spendable)
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 18) {
                            if let goal { jar(goal, family, spendable, compact: false) }
                            if let familyGoal { familyGoalCard(familyGoal, family, spendable) }
                        }
                        .frame(width: 340)
                        rewardGrid(family, spendable)
                    }
                }
                if sizeClass == .compact, let familyGoal {
                    familyGoalCard(familyGoal, family, spendable)
                }
            }
            .padding(.horizontal, sizeClass == .compact ? 16 : 28)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(color.opacity(0.07).ignoresSafeArea())
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .refreshesFromICloud()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { savingID = UserDefaults.standard.string(forKey: goalKey) }
        .overlay {
            if let asking {
                GiftBoxSheet(reward: asking, kid: kid, have: spendable) { confirmed in
                    if confirmed {
                        Family.request(asking, for: kid.id, in: context)
                        spent = asking.cost
                        spentKey += 1
                    } else {
                        withAnimation(.smooth) { self.asking = nil }
                    }
                } onClose: {
                    withAnimation(.smooth) { self.asking = nil }
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $choosingGoal) {
            SavingForPicker(rewards: store, current: goal?.id, have: spendable, kid: kid) { reward in
                pickGoal(reward)
                choosingGoal = false
            }
        }
        .sheet(isPresented: $chippingIn) {
            if let familyGoal {
                ChipInSheet(goal: familyGoal, kid: kid, have: spendable)
                    .presentationDetents([.medium])
            }
        }
    }

    private func header(_ spendable: Int) -> some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Label("My Jobs", systemImage: "chevron.left")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(.glass)
            Text(sizeClass == .compact ? "Store" : "\(kid.name)'s Store")
                .font(.system(size: sizeClass == .compact ? 28 : 34, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: words.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Brand.starBright)
                    .symbolEffect(.bounce, value: spentKey)
                Text(spendable.formatted())
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .overlay(alignment: .bottomTrailing) {
                if spent > 0 {
                    SpentLabel(amount: spent)
                        .id(spentKey)
                        .offset(y: 34)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(words.count(spendable))
        }
    }

    private func rewardGrid(_ family: FamilySnapshot, _ spendable: Int) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 160 : 220), spacing: 14)], spacing: 14) {
            ForEach(Array(store.enumerated()), id: \.element.id) { index, reward in
                let check = RewardMath.check(cost: reward.cost, limit: reward.limit, eligible: reward.isAvailable(to: kid.id), spendable: spendable, memberID: kid.id, rewardID: reward.id, redemptions: family.redemptions)
                StoreTile(reward: reward, kid: kid, check: check, have: spendable, isSaving: savingFor(spendable)?.id == reward.id, index: index, compact: sizeClass == .compact) {
                    withAnimation(.smooth) { asking = reward }
                }
            }
        }
    }

    private func jar(_ goal: Reward, _ family: FamilySnapshot, _ spendable: Int, compact: Bool) -> some View {
        let check = RewardMath.check(cost: goal.cost, limit: goal.limit, eligible: true, spendable: spendable, memberID: kid.id, rewardID: goal.id, redemptions: family.redemptions)
        return JarCard(reward: goal, have: spendable, kid: kid, compact: compact, canGet: check == .ok) {
            withAnimation(.smooth) { asking = goal }
        } onChange: {
            choosingGoal = true
        }
    }

    private func pickGoal(_ reward: Reward) {
        let id = reward.id.uuidString
        UserDefaults.standard.set(id, forKey: goalKey)
        withAnimation(.snappy) { savingID = id }
    }

    private func familyGoalCard(_ goal: Reward, _ family: FamilySnapshot, _ spendable: Int) -> some View {
        let progress = ChoreMath.goalProgress(goal.id, entries: family.points)
        let shares = ChoreMath.goalShares(goal.id, entries: family.points)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "flag.checkered")
                    .font(.title2.bold())
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 0) {
                    Text("FAMILY GOAL")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                    Text(goal.name)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                }
            }
            ProgressView(value: min(Double(progress) / Double(max(goal.cost, 1)), 1))
                .tint(color)
                .scaleEffect(y: 2)
                .padding(.vertical, 4)
            Text("\(progress.formatted()) of \(goal.cost.formatted()) · You put in \((shares[kid.id] ?? 0).formatted())")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Button {
                chippingIn = true
            } label: {
                Text("Chip In")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(.white)
                    .background(spendable > 0 ? color : Color(.systemGray3), in: Capsule())
            }
            .buttonStyle(KidPressStyle())
            .disabled(spendable <= 0 || progress >= goal.cost)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
    }
}

/// "−40" floating down from the star counter after buying something.
private struct SpentLabel: View {
    var amount: Int
    @State private var gone = false

    var body: some View {
        Text("−\(amount)")
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .foregroundStyle(Brand.late)
            .offset(y: gone ? 40 : 0)
            .opacity(gone ? 0 : 1)
            .animation(.easeOut(duration: 1.3).delay(0.6), value: gone)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                try? await Task.sleep(for: .milliseconds(20))
                gone = true
            }
    }
}

/// The jar filling toward what this kid is saving for, with a gently moving surface and
/// twinkling stars inside.
private struct JarCard: View {
    var reward: Reward
    var have: Int
    var kid: Member
    var compact: Bool
    var canGet: Bool
    var onGet: () -> Void
    var onChange: () -> Void

    @State private var filled = false
    /// A new scatter of stars each time the jar appears.
    @State private var stars: [JarStarSpec] = JarStarSpec.scatter()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { min(Double(max(have, 0)) / Double(max(reward.cost, 1)), 1) }

    var body: some View {
        let color = kid.color.color
        let jar = jarShape
        Group {
            if compact {
                HStack(spacing: 18) {
                    jar.frame(width: 96, height: 128)
                    text
                }
            } else {
                VStack(spacing: 16) {
                    text.multilineTextAlignment(.center)
                    jar.frame(width: 170, height: 226)
                    figure
                    buttons
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30))
        .onAppear { filled = true }
        .animation(.smooth, value: reward.id)
        .tint(color)
    }

    /// Get it (when there's enough) and Change, to save for something else.
    private var buttons: some View {
        HStack(spacing: 10) {
            if canGet {
                Button(action: onGet) {
                    Text("Get it!")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.white)
                        .background(kid.color.color, in: Capsule())
                }
                .buttonStyle(KidPressStyle())
                .accessibilityLabel("Get \(reward.name)")
            }
            Button(action: onChange) {
                Label("Change", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .frame(maxWidth: canGet ? nil : .infinity, minHeight: 48)
                    .padding(.horizontal, canGet ? 16 : 0)
                    .foregroundStyle(kid.color.color)
                    .background(kid.color.color.opacity(0.14), in: Capsule())
            }
            .buttonStyle(KidPressStyle())
            .accessibilityLabel("Change what you're saving for")
        }
    }

    private var text: some View {
        VStack(alignment: compact ? .leading : .center, spacing: 4) {
            Text("SAVING FOR")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(kid.color.color)
            Text(reward.name)
                .font(.system(size: compact ? 22 : 28, weight: .heavy, design: .rounded))
            if compact { figure }
            Text(have >= reward.cost ? "You can get it now!" : "\(PointWords.current().count(reward.cost - max(have, 0))) to go")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            if compact {
                buttons.padding(.top, 6)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var figure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(max(have, 0).formatted())
                .font(.system(size: compact ? 30 : 44, weight: .heavy, design: .rounded))
            Text(" / \(reward.cost.formatted())")
                .font(.system(size: compact ? 17 : 22, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }

    private var jarShape: some View {
        let color = kid.color.color
        return ZStack(alignment: .top) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: size.width * 0.24, style: .continuous)
                        .fill(color.opacity(0.08))
                    TimelineView(.animation(paused: reduceMotion)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate * 2.4
                        Wave(level: filled ? fraction : 0, phase: phase)
                            .fill(color.mix(with: .white, by: 0.15))
                    }
                    .animation(.spring(duration: 1.4, bounce: 0.3), value: filled)
                    .animation(.spring(duration: 1.0, bounce: 0.3), value: fraction)
                    // More stars the fuller the jar, each somewhere in the liquid.
                    let showing = fraction > 0.04 ? max(3, Int((Double(stars.count) * fraction).rounded(.up))) : 0
                    ForEach(stars.prefix(showing)) { star in
                        JarStar(spec: star)
                            .position(
                                x: size.width * CGFloat(star.x),
                                y: size.height * CGFloat(1 - fraction * star.depth)
                            )
                    }
                    // A highlight down the glass.
                    Capsule()
                        .fill(.white.opacity(0.45))
                        .frame(width: size.width * 0.08, height: size.height * 0.5)
                        .position(x: size.width * 0.16, y: size.height * 0.4)
                }
                .clipShape(RoundedRectangle(cornerRadius: size.width * 0.24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size.width * 0.24, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 4))
            }
            .padding(.top, 14)
            Capsule()
                .fill(Color(.systemGray3))
                .frame(height: 20)
                .padding(.horizontal, 22)
        }
    }
}

/// The jar's liquid: a sine wave surface at `level` (0 empty, 1 full).
private struct Wave: Shape {
    var level: Double
    var phase: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let surface = rect.maxY - rect.height * CGFloat(level)
        let amplitude: Double = level > 0.02 && level < 0.98 ? 5 : 0
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: surface))
        var x = rect.minX
        while x <= rect.maxX {
            let angle = Double(x / rect.width) * 2 * .pi * 1.5 + phase
            let y = surface + CGFloat(sin(angle) * amplitude)
            path.addLine(to: CGPoint(x: x, y: y))
            x += 4
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Where one star in the jar sits and how it moves, all picked at random.
private struct JarStarSpec: Identifiable {
    let id: Int
    /// Across the jar, 0 to 1.
    let x: Double
    /// How far up the liquid, 0 (bottom) to 1 (surface).
    let depth: Double
    let size: CGFloat
    let symbol: String
    let color: Color
    let tilt: Double
    let appearDelay: Double
    let twinkleDuration: Double
    let twinkleDelay: Double
    let dimness: Double
    let bobDistance: CGFloat
    let bobDuration: Double
    let sway: Double

    static func scatter(count: Int = 14) -> [JarStarSpec] {
        let colors: [Color] = [Brand.starBright, Brand.starBright, Brand.starBright, Color(hex: 0xFFF3A6), .white, Color(hex: 0xFFB800)]
        // Shuffled depths so the first few (shown when the jar is nearly empty) sit low.
        return (0..<count).map { index in
            let sparkle = Double.random(in: 0...1) < 0.25
            return JarStarSpec(
                id: index,
                x: .random(in: 0.14...0.86),
                depth: .random(in: 0.08...0.9) * (0.45 + 0.55 * Double(index + 1) / Double(count)),
                size: sparkle ? .random(in: 10...16) : .random(in: 8...24),
                symbol: sparkle ? "sparkle" : "star.fill",
                color: colors.randomElement() ?? Brand.starBright,
                tilt: .random(in: -35...35),
                appearDelay: .random(in: 0.2...1.4),
                twinkleDuration: .random(in: 0.7...2.2),
                twinkleDelay: .random(in: 0...1.8),
                dimness: .random(in: 0.25...0.6),
                bobDistance: .random(in: 2...7),
                bobDuration: .random(in: 1.6...3.8),
                sway: .random(in: 8...28) * (Bool.random() ? 1 : -1)
            )
        }
    }
}

/// One star in the jar: pops in, then twinkles, bobs and sways on its own timing.
private struct JarStar: View {
    var spec: JarStarSpec

    @State private var appeared = false
    @State private var bright = false
    @State private var bobbing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: spec.symbol)
            .font(.system(size: spec.size, weight: .bold))
            .foregroundStyle(spec.color)
            .shadow(color: spec.color.opacity(bright ? 0.7 : 0), radius: spec.size * 0.35)
            .rotationEffect(.degrees(spec.tilt + (bobbing ? spec.sway : 0)))
            .scaleEffect(appeared ? (bright ? 1.12 : 0.82) : 0.1)
            .opacity(appeared ? (bright ? 1 : spec.dimness) : 0)
            .offset(y: bobbing ? -spec.bobDistance : spec.bobDistance)
            .onAppear {
                withAnimation(.spring(duration: 0.5, bounce: 0.55).delay(spec.appearDelay)) { appeared = true }
                guard !reduceMotion else {
                    bright = true
                    return
                }
                withAnimation(.easeInOut(duration: spec.twinkleDuration).repeatForever(autoreverses: true).delay(spec.appearDelay + spec.twinkleDelay)) {
                    bright = true
                }
                withAnimation(.easeInOut(duration: spec.bobDuration).repeatForever(autoreverses: true).delay(spec.appearDelay)) {
                    bobbing = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// A reward in the kid's store. Bounces gently when they can get it.
private struct StoreTile: View {
    var reward: Reward
    var kid: Member
    var check: RewardCheck
    var have: Int
    var isSaving: Bool
    var index: Int
    var compact: Bool
    var onGet: () -> Void

    @State private var nudge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let kindColor = Color(hex: reward.kind.colorHex)
        VStack(spacing: 10) {
            Image(systemName: reward.symbol)
                .font(.system(size: compact ? 30 : 40, weight: .semibold))
                .foregroundStyle(kindColor)
                .frame(width: compact ? 66 : 86, height: compact ? 66 : 86)
                .background(kindColor.opacity(0.14), in: Circle())
                .opacity(check == .ok ? 1 : 0.6)
            Text(reward.name)
                .font(.system(size: compact ? 18 : 21, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(minHeight: compact ? 46 : 54)
            PointsLabel(points: reward.cost, font: .system(size: compact ? 18 : 20, weight: .heavy, design: .rounded), color: Brand.starBright)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            action
        }
        .padding(compact ? 14 : 20)
        .frame(maxWidth: .infinity, minHeight: compact ? 250 : 300)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
        .overlay {
            if isSaving {
                RoundedRectangle(cornerRadius: 28).strokeBorder(kid.color.color, lineWidth: 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSaving {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white, kid.color.color)
                    .padding(10)
                    .accessibilityLabel("Saving for this")
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch check {
        case .ok:
            Button(action: onGet) {
                Text("Get it!")
                    .font(.system(size: compact ? 19 : 22, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: compact ? 50 : 58)
                    .foregroundStyle(.white)
                    .background(kid.color.color, in: Capsule())
                    .shadow(color: kid.color.color.opacity(0.35), radius: 8, y: 5)
            }
            .buttonStyle(KidPressStyle())
            .offset(y: nudge && !reduceMotion ? -4 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(Double(index % 4) * 0.2)) { nudge = true }
            }
            .accessibilityLabel("Get \(reward.name) for \(PointWords.current().count(reward.cost))")
        case .needMore(let more):
            VStack(spacing: 6) {
                ProgressView(value: min(Double(max(have, 0)) / Double(max(reward.cost, 1)), 1))
                    .tint(isSaving ? kid.color.color : Color(.systemGray))
                Text("Need \(more.formatted()) more")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: compact ? 50 : 58)
        case .limitReached:
            Text(limitText)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: compact ? 50 : 58)
        case .notForThisKid:
            EmptyView()
        }
    }

    private var limitText: String {
        switch reward.limit {
        case .oncePerDay: "Again tomorrow"
        case .oncePerWeek, .twicePerWeek: "Again next week"
        case .oncePerMonth: "Again next month"
        case .none: ""
        }
    }
}

/// Getting a reward: a gift box that wiggles while they decide, then pops open.
private struct GiftBoxSheet: View {
    var reward: Reward
    var kid: Member
    var have: Int
    var onAnswer: (Bool) -> Void
    var onClose: () -> Void

    @State private var opened = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = kid.color.color
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture { if !opened { onAnswer(false) } }
            VStack(spacing: 14) {
                GiftBox(color: color, opened: opened, rewardSymbol: reward.symbol, kindColor: Color(hex: reward.kind.colorHex), shaking: !opened && !reduceMotion)
                    .frame(width: 180, height: 180)
                if opened {
                    Text(reward.needsApproval ? "Wish sent!" : "It's yours!")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                    Text(reward.needsApproval ? "Mom or Dad will say OK soon. Then \(reward.name) is all yours." : "Enjoy \(reward.name)!")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    bigButton("Awesome!", color: color, action: onClose)
                } else {
                    Text("\(reward.name)?")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("That uses \(PointWords.current().count(reward.cost)). You'll have \(max(have - reward.cost, 0).formatted()) left.")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button {
                            onAnswer(false)
                        } label: {
                            Text("Not yet")
                                .font(.system(size: 20, weight: .heavy, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .foregroundStyle(Color.primary)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(KidPressStyle())
                        bigButton(reward.needsApproval ? "Yes, ask!" : "Yes!", color: color) {
                            withAnimation(.spring(duration: 0.5, bounce: 0.45)) { opened = true }
                            onAnswer(true)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 500)
            .background(Color(.systemBackground), in: .rect(cornerRadius: 40))
            .shadow(color: .black.opacity(0.3), radius: 40, y: 20)
            .padding(24)
            .scaleEffect(appeared ? 1 : 0.85)
            .offset(y: appeared ? 0 : 40)
            .animation(.spring(duration: 0.45, bounce: 0.4), value: appeared)
        }
        .sensoryFeedback(.success, trigger: opened)
        .onAppear { appeared = true }
        .accessibilityAddTraits(.isModal)
    }

    private func bigButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 60)
                .foregroundStyle(.white)
                .background(color, in: Capsule())
        }
        .buttonStyle(KidPressStyle())
    }
}

/// A box with a ribbon. Shakes while closed; the lid flies off and sparkles burst when opened.
private struct GiftBox: View {
    var color: Color
    var opened: Bool
    var rewardSymbol: String
    var kindColor: Color
    var shaking: Bool

    @State private var wobble = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                if opened {
                    ConfettiBurst(colors: confettiColors(color), count: 22)
                        .position(x: w / 2, y: h * 0.45)
                    Image(systemName: rewardSymbol)
                        .font(.system(size: w * 0.2, weight: .semibold))
                        .foregroundStyle(kindColor)
                        .frame(width: w * 0.42, height: w * 0.42)
                        .background(Color(.systemBackground), in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 6)
                        .position(x: w / 2, y: h * 0.3)
                        .transition(.scale(scale: 0.2).combined(with: .offset(y: h * 0.3)))
                }
                // Box
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color)
                    .frame(width: w * 0.7, height: h * 0.48)
                    .position(x: w / 2, y: h * 0.72)
                Rectangle()
                    .fill(Brand.starBright)
                    .frame(width: w * 0.1, height: h * 0.48)
                    .position(x: w / 2, y: h * 0.72)
                // Lid with bow
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.mix(with: .black, by: 0.18))
                        .frame(width: w * 0.8, height: h * 0.17)
                    Rectangle()
                        .fill(Brand.starBright)
                        .frame(width: w * 0.1, height: h * 0.17)
                    Image(systemName: "gift.fill")
                        .font(.system(size: w * 0.16))
                        .foregroundStyle(Brand.starBright)
                        .offset(y: -h * 0.12)
                }
                .rotationEffect(.degrees(opened ? -28 : 0), anchor: .bottomLeading)
                .offset(x: opened ? -w * 0.1 : 0, y: opened ? -h * 0.4 : 0)
                .opacity(opened ? 0 : 1)
                .animation(.spring(duration: 0.55, bounce: 0.4), value: opened)
                .position(x: w / 2, y: h * 0.42)
            }
            .rotationEffect(.degrees(wobble && shaking ? 5 : (shaking ? -5 : 0)), anchor: .bottom)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { wobble = true }
        }
        .accessibilityHidden(true)
    }
}

/// Putting some points toward the family goal.
private struct ChipInSheet: View {
    var goal: Reward
    var kid: Member
    var have: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var amount = 10

    var body: some View {
        VStack(spacing: 22) {
            Text("Chip in to \(goal.name)")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                roundButton("minus") { amount = max(5, amount - 5) }
                    .disabled(amount <= 5)
                PointsLabel(points: amount, font: .system(size: 44, weight: .heavy, design: .rounded), color: Brand.starBright)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 120)
                roundButton("plus") { amount = min(have, amount + 5) }
                    .disabled(amount + 5 > have)
            }
            Button {
                Family.contribute(min(amount, have), from: kid.id, to: goal, in: context)
                dismiss()
            } label: {
                Text("Put it in!")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .foregroundStyle(.white)
                    .background(kid.color.color, in: Capsule())
            }
            .buttonStyle(KidPressStyle())
            .disabled(have <= 0)
        }
        .padding(28)
        .onAppear { amount = min(10, max(have, 0)) }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .heavy))
                .frame(width: 60, height: 60)
                .foregroundStyle(kid.color.color)
                .background(kid.color.color.opacity(0.14), in: Circle())
        }
        .buttonStyle(KidPressStyle())
    }
}


/// "What are you saving for?" Every reward this kid can get, with how close they are. Tapping
/// one makes it the jar's goal.
private struct SavingForPicker: View {
    var rewards: [Reward]
    var current: UUID?
    var have: Int
    var kid: Member
    var onPick: (Reward) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                    ForEach(rewards) { reward in
                        let picked = reward.id == current
                        let enough = have >= reward.cost
                        let kindColor = Color(hex: reward.kind.colorHex)
                        Button {
                            onPick(reward)
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: reward.symbol)
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(kindColor)
                                    .frame(width: 64, height: 64)
                                    .background(kindColor.opacity(0.14), in: Circle())
                                Text(reward.name)
                                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.primary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                    .frame(minHeight: 46)
                                PointsLabel(points: reward.cost, font: .system(size: 18, weight: .heavy, design: .rounded), color: Brand.starBright)
                                    .foregroundStyle(Color.primary)
                                if enough {
                                    Text("You have enough!")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundStyle(kid.color.color)
                                } else {
                                    ProgressView(value: min(Double(max(have, 0)) / Double(max(reward.cost, 1)), 1))
                                        .tint(kid.color.color)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, minHeight: 230)
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
                            .overlay {
                                RoundedRectangle(cornerRadius: 26).strokeBorder(kid.color.color, lineWidth: picked ? 4 : 0)
                            }
                            .overlay(alignment: .topTrailing) {
                                if picked {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(.white, kid.color.color)
                                        .padding(10)
                                }
                            }
                        }
                        .buttonStyle(KidPressStyle())
                        .accessibilityLabel("\(reward.name), \(PointWords.current().count(reward.cost))")
                        .accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }
                .padding(16)
                .padding(.bottom, 32)
            }
            .background(kid.color.color.opacity(0.07).ignoresSafeArea())
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("What are you saving for?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
            }
        }
        .tint(kid.color.color)
    }
}
