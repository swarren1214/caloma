import SwiftData
import SwiftUI

/// First run, from the canvas's onboarding flow: Welcome, start or join, who's in the family,
/// what chores earn, a few starter chores, the extras (calendar, home care, Apple Home, Family
/// Board), notifications, inviting the other parent, and "Welcome home".
///
/// Nothing is saved until the family is complete: leaving "Make it your home" (or skipping
/// past it) saves everyone at once, since the invite needs the family in iCloud. After that
/// there's no going back, so nobody is added twice. Signing in is optional, after Hearken's
/// App Review rejection: everything works without it, and Sign in with Apple just fills in
/// your name.
struct OnboardingView: View {
    @State private var flow = OnboardingFlow()
    @State private var size = CGSize(width: 390, height: 844)
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if flow.showsBar {
                OnboardingTopBar(flow: flow, skip: skip)
                    .transition(.opacity)
            }
            ZStack {
                stepView
                    .id(flow.step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OnboardingBackground(step: flow.step))
        .environment(flow)
        .environment(\.onboardingLayout, OnboardingLayout(size: size))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .animation(.smooth(duration: 0.3), value: flow.showsBar)
    }

    @ViewBuilder private var stepView: some View {
        switch flow.step {
        case 0: WelcomeStep()
        case 1: StartOrJoinStep()
        case 2: FamilyStep()
        case 3: PointsStep()
        case 4: ChoresStep()
        case 5: HomeExtrasStep()
        case 6: NotificationsStep()
        case 7: InviteStep()
        default: AllSetStep()
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: flow.forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: flow.forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    /// Skip, from "Make it your home" on: saves the family if it isn't yet, then "all set".
    private func skip() {
        guard flow.commit(in: context) else { return }
        flow.go(to: OnboardingFlow.lastStep)
    }
}

// MARK: - The flow

/// Where onboarding is, and everything it's collected so far.
@Observable
final class OnboardingFlow {
    enum Path { case start, join }

    /// The extras on "Make it your home".
    struct Extras {
        var calendar = false
        var homeCare = true
        var appleHome = false
        var familyBoard = false
    }

    static let lastStep = 8
    /// The steps with a progress bar: everything between Welcome and "Welcome home".
    static let progressSteps = 1...7
    /// The first step with Skip.
    static let firstSkippable = 5

    private(set) var step = 0
    /// Which way the last move went, for the slide.
    private(set) var forward = true
    var path: Path = .start
    var draft = FamilyDraft()
    var extras = Extras()
    /// The family is saved; there's no going back past this.
    private(set) var committed = false
    /// The parent who set it up, once saved.
    private(set) var meID: UUID?
    var notificationsAllowed: Bool?
    var invited = false

    var showsBar: Bool { Self.progressSteps.contains(step) }
    var showsBack: Bool { showsBar && !(committed && step > Self.firstSkippable) }
    var showsSkip: Bool { step >= Self.firstSkippable && step < Self.lastStep }

    func go(to next: Int) {
        let target = min(max(next, 0), Self.lastStep)
        guard target != step else { return }
        let isForward = target > step
        guard isForward != forward else {
            withAnimation(.smooth(duration: 0.42)) { step = target }
            return
        }
        // The direction changes first, on its own, so the screen leaving slides the right way.
        forward = isForward
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.42)) { self.step = target }
        }
    }

    func next() { go(to: step + 1) }
    func back() { go(to: step - 1) }

    /// Saves the family: parents, kids, the chores picked for them, the store, home care and
    /// the points settings. Once only. Returns false, and goes to "Join my family" instead, when
    /// a family arrived from iCloud in the meantime, so nobody's added twice.
    @discardableResult
    func commit(in context: ModelContext, defaults: UserDefaults = .standard) -> Bool {
        guard !committed else { return true }
        let existing = (try? context.fetch(FetchDescriptor<Member>())) ?? []
        if existing.contains(where: { !$0.isArchived && !$0.isKid }) {
            path = .join
            go(to: 1)
            return false
        }
        committed = true
        // The points screen's choices, written out even when left as they were, so every
        // screen agrees with what onboarding showed.
        let pointDefaults: [(String, Any)] = [
            (SettingsKey.pointName, PointName.stars.rawValue), (SettingsKey.approvalsByDefault, true),
            (SettingsKey.allowanceOn, true), (SettingsKey.centsPer100, 500), (SettingsKey.payday, 1),
            (SettingsKey.splitSpend, 70), (SettingsKey.splitSave, 20), (SettingsKey.splitGive, 10),
        ]
        for (key, value) in pointDefaults where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        draft.addPendingKid()

        let me = Member(name: draft.myName.trimmingCharacters(in: .whitespaces), role: .parent, color: .teal, sortOrder: 0)
        me.photoData = draft.myPhoto
        context.insert(me)
        let partner = draft.partnerName.trimmingCharacters(in: .whitespaces)
        if !partner.isEmpty {
            let member = Member(name: partner, role: .parent, color: .pink, sortOrder: 1)
            member.photoData = draft.partnerPhoto
            context.insert(member)
        }
        var kids: [Member] = []
        for (index, person) in draft.namedKids.enumerated() {
            let kid = Member(name: person.name.trimmingCharacters(in: .whitespaces), role: .kid, color: person.color, sortOrder: 2 + index)
            kid.photoData = person.photo
            context.insert(kid)
            kids.append(kid)
        }
        if !kids.isEmpty {
            let picked = StarterData.chores.filter { draft.pickedChores.contains($0.title) }
            StarterData.insertChores(picked, kids: kids, into: context)
        }
        if draft.addRewards { StarterData.insertRewards(into: context) }
        Persistence.save(context)

        if extras.homeCare {
            StarterData.seedIfNeeded(in: context, defaults: defaults)
        } else {
            // No starter list, and don't add one on the next launch either.
            defaults.set(true, forKey: SettingsKey.seeded)
        }
        if extras.appleHome {
            Task { await HomeRoomImport.run(in: context) }
        }
        meID = me.id
        defaults.set(me.id.uuidString, forKey: SettingsKey.currentMember)
        return true
    }
}

/// What onboarding collects before anything is saved.
struct FamilyDraft {
    struct Person: Identifiable {
        var id = UUID()
        var name = ""
        var color: KidColor = .blue
        var photo: Data?
    }

    var myName = ""
    var myPhoto: Data?
    var partnerName = ""
    var partnerPhoto: Data?
    var kids: [Person] = []
    /// The "Kid's name" field, not added yet.
    var newKidName = ""
    var newKidColor: KidColor = .blue
    var pickedChores: Set<String> = Set(StarterData.chores.prefix(6).map(\.title))
    var addRewards = true

    var namedKids: [Person] { kids.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
    /// Kids, counting a name typed but not added.
    var kidCount: Int { namedKids.count + (newKidName.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1) }
    var firstKidName: String? { namedKids.first?.name.trimmingCharacters(in: .whitespaces) }
    var pickedCount: Int { StarterData.chores.filter { pickedChores.contains($0.title) }.count }

    /// Adds the kid in the "Kid's name" field, and picks a different color for the next one.
    mutating func addPendingKid() {
        let name = newKidName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        kids.append(Person(name: name, color: newKidColor))
        newKidName = ""
        newKidColor = KidColor.next(after: kids.map(\.color))
    }
}

// MARK: - Top bar

/// Back, the progress segments, and Skip.
private struct OnboardingTopBar: View {
    var flow: OnboardingFlow
    var skip: () -> Void
    @Environment(\.accent) private var accent
    @Environment(\.onboardingLayout) private var layout

    private var segments: Int { OnboardingFlow.progressSteps.count }
    private var current: Int { flow.step - OnboardingFlow.progressSteps.lowerBound + 1 }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: flow.back) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .opacity(flow.showsBack ? 1 : 0)
            .disabled(!flow.showsBack)
            .accessibilityLabel("Back")

            HStack(spacing: 5) {
                ForEach(1...segments, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? accent : Color(.systemGray4))
                        .frame(height: 5)
                }
            }
            .frame(maxWidth: layout.isRegular ? 360 : .infinity)
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: current)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(current) of \(segments)")

            Button("Skip", action: skip)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .opacity(flow.showsSkip ? 1 : 0)
                .disabled(!flow.showsSkip)
        }
        .padding(.horizontal, layout.isRegular ? 28 : 16)
        .padding(.top, layout.isRegular ? 16 : 4)
        .padding(.bottom, 4)
    }
}

/// The grouped background, with a soft wash of the accent behind the welcome and "all set"
/// screens.
private struct OnboardingBackground: View {
    var step: Int
    @Environment(\.accent) private var accent

    private var glows: Bool { step == 0 || step == OnboardingFlow.lastStep }

    var body: some View {
        Color(.systemGroupedBackground)
            .overlay(alignment: .top) {
                RadialGradient(colors: [accent.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 520)
                    .frame(height: 620)
                    .opacity(glows ? 1 : 0)
                    .animation(.smooth(duration: 0.5), value: glows)
            }
            .ignoresSafeArea()
    }
}

#Preview("iPhone") {
    OnboardingView()
        .previewEnvironment()
}

#Preview("iPad landscape", traits: .landscapeLeft) {
    OnboardingView()
        .previewEnvironment()
}
