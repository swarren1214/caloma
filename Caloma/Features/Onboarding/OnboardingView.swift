import SwiftData
import SwiftUI

/// First run, from the canvas's onboarding flow: Welcome, the household (set one up or join the
/// family's: the people come from it), what chores earn, a few starter chores, the extras
/// (calendar, home care, Apple Home, Family Board), notifications, inviting the other parent to
/// the household, and "Welcome home".
///
/// The chores and settings are saved on leaving "Make it your home" (or skipping past it).
/// After that there's no going back, so nothing is added twice. Joining a family that already
/// uses Caloma skips straight to the app.
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
        case 1: HouseholdStep()
        case 2: PointsStep()
        case 3: ChoresStep()
        case 4: HomeExtrasStep()
        case 5: NotificationsStep()
        case 6: InviteStep()
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
    /// The extras on "Make it your home".
    struct Extras {
        var calendar = false
        var homeCare = true
        var appleHome = false
        var familyBoard = false
    }

    static let lastStep = 7
    /// The steps with a progress bar: everything between Welcome and "Welcome home".
    static let progressSteps = 1...6
    /// The first step with Skip.
    static let firstSkippable = 4

    private(set) var step = 0
    /// Which way the last move went, for the slide.
    private(set) var forward = true
    var draft = FamilyDraft()
    var extras = Extras()
    /// The family is saved; there's no going back past this.
    private(set) var committed = false
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

    /// The household's kids, by first name (Caloma's members mirror them).
    var kidNames: [String] { HearthHouseholdStore.shared.kids.map(\.firstName).filter { !$0.isEmpty } }
    var firstKidName: String? { kidNames.first }

    /// The family is already in Caloma: this account joined someone else's household (their
    /// Caloma comes down by itself), or this account's family is already in iCloud.
    func familyIsAlreadySetUp(in context: ModelContext) -> Bool {
        HearthHouseholdStore.shared.isMember || Self.hasFamilyData(in: context)
    }

    /// Chores, rewards or events already here, from iCloud.
    static func hasFamilyData(in context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<Chore>())) ?? 0) > 0
            || ((try? context.fetchCount(FetchDescriptor<Reward>())) ?? 0) > 0
            || ((try? context.fetchCount(FetchDescriptor<FamilyEvent>())) ?? 0) > 0
    }

    /// Straight into the app with the family that's already there.
    func finishWithExistingFamily(defaults: UserDefaults = .standard) {
        committed = true
        // Starter home care came with the family, so nothing to add.
        defaults.set(true, forKey: SettingsKey.seeded)
        defaults.set(true, forKey: SettingsKey.onboarded)
    }

    /// Saves the chores picked for the household's kids, the store, home care and the points
    /// settings. Once only. The people are the household's (Caloma's members mirror it), and a
    /// family that arrived from iCloud in the meantime gets no second set of starters.
    @discardableResult
    func commit(in context: ModelContext, defaults: UserDefaults = .standard) -> Bool {
        guard !committed else { return true }
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
        CalomaHousehold.sync(in: context)
        let alreadyThere = Self.hasFamilyData(in: context)
        if !alreadyThere {
            let kids = Persistence.fetchAll(Member.self, in: context)
                .filter { $0.isKid && !$0.isArchived }
                .sorted { $0.sortOrder < $1.sortOrder }
            if !kids.isEmpty {
                let picked = StarterData.chores.filter { draft.pickedChores.contains($0.title) }
                StarterData.insertChores(picked, kids: kids, into: context)
            }
            if draft.addRewards { StarterData.insertRewards(into: context) }
            Persistence.save(context)
        }

        if extras.homeCare && !alreadyThere {
            StarterData.seedIfNeeded(in: context, defaults: defaults)
        } else {
            // No starter list, and don't add one on the next launch either.
            defaults.set(true, forKey: SettingsKey.seeded)
        }
        if extras.appleHome {
            Task { await HomeRoomImport.run(in: context) }
        }
        return true
    }
}

/// What onboarding collects before anything is saved.
struct FamilyDraft {
    var pickedChores: Set<String> = Set(StarterData.chores.prefix(6).map(\.title))
    var addRewards = true

    var pickedCount: Int { StarterData.chores.filter { pickedChores.contains($0.title) }.count }
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
