import Combine
import CloudKit
import SwiftData
import SwiftUI

@main
struct CalomaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = AppRouter.shared
    private let container: ModelContainer

    init() {
        ScreenshotMode.prepareLaunch()
        // Alert buttons in the text color, not Caloma's color; only a destructive button is red
        // (its role). See AGENT.md › Confirmations.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
        // Screenshot mode (Debug only) runs on an in-memory store of demo content, with no
        // sync, watch or settings mirroring, so the device's own family and iCloud are untouched.
        let container = Persistence.makeContainer(inMemory: ScreenshotMode.isOn)
        self.container = container
        AppRouter.shared.container = container
        // What's paid for (Caloma Plus or Hearth+). Screenshot mode shows everything unlocked.
        CalomaPlus.configure()
        guard !ScreenshotMode.isOn else { return }
        // Starter home care is added at the end of onboarding, so a device that picks up a
        // family already in iCloud doesn't add a second copy.
        if UserDefaults.standard.bool(forKey: SettingsKey.onboarded) {
            StarterData.seedIfNeeded(in: container.mainContext)
            // Onboarded before the family's settings remembered it: say so now (SharedSettings
            // sends it up below), so the family's other devices skip onboarding.
            if UserDefaults.standard.object(forKey: SettingsKey.familySetUp) == nil {
                UserDefaults.standard.set(true, forKey: SettingsKey.familySetUp)
            }
            // And for this person's own devices (iCloud key-value storage).
            HearthOnboarding.rememberInCloud(.caloma)
        }
        Upgrades.run(in: container.mainContext)
        // Registers Caloma's zone with the household store, which starts in AppRoot's task.
        CloudSync.shared.start(with: container)
        SharedSettings.shared.start(with: container)
        PersonalSettings.shared.start()
        WatchBridge.shared.start(with: container)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                // The Hearth launch splash.
                .hearthSplash(.caloma, isEnabled: !ScreenshotMode.isOn)
                .environment(router)
                // iPhone Duo: which pose the device is in, for every screen (HearthDuo.swift).
                .hearthDuoPose()
        }
        .modelContainer(container)
        .commands { CalomaCommands(router: router) }
    }
}

/// Keyboard shortcuts for iPad (hold ⌘ to see them).
struct CalomaCommands: Commands {
    let router: AppRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chore") { if !router.kioskOpen { router.sheet = .newChore } }
                .keyboardShortcut("n")
            Button("New Reward") { if !router.kioskOpen { router.sheet = .newReward } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Event") { if !router.kioskOpen { router.newEvent() } }
                .keyboardShortcut("e")
        }
        CommandMenu("Go") {
            Button("Home") { router.tab = .home }.keyboardShortcut("1")
            Button("Chores") { router.tab = .chores }.keyboardShortcut("2")
            Button("Calendar") { router.tab = .calendar }.keyboardShortcut("3")
            Button("Rewards") { router.tab = .rewards }.keyboardShortcut("4")
            Button("Control") { router.tab = .control }.keyboardShortcut("5")
            Button("Home Care") { router.tab = .homeCare }.keyboardShortcut("6")
            Button("Whiteboard") { router.tab = .whiteboard }.keyboardShortcut("7")
            Divider()
            Button("Needs Your OK") { if !router.kioskOpen { router.sheet = .approvals } }.keyboardShortcut("o")
            Button("Kid View") { router.openKidView() }.keyboardShortcut("k")
        }
    }
}

/// Which tab is showing, which sheet is up, and Kid View.
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var tab: AppTab = .home
    var sheet: AppSheet?
    /// Set to open New Event on the calendar (⌘E); the calendar clears it.
    var pendingNewEvent = false
    /// The app's store, for notification actions that arrive outside a view.
    var container: ModelContainer?

    func newEvent() {
        tab = .calendar
        pendingNewEvent = true
    }

    /// Kid View covers the whole app. Remembered, so a kid's iPad opens back into it (except
    /// in screenshot mode, which leaves the device's setting alone).
    var kidViewOpen: Bool = ScreenshotMode.isOn ? false : UserDefaults.standard.bool(forKey: SettingsKey.kidViewOpen) {
        didSet {
            guard !ScreenshotMode.isOn else { return }
            UserDefaults.standard.set(kidViewOpen, forKey: SettingsKey.kidViewOpen)
        }
    }

    /// Kiosk Mode covers the whole app on a wall iPad. Remembered, so the iPad opens back into
    /// it after a restart.
    var kioskOpen: Bool = ScreenshotMode.isOn ? false : UserDefaults.standard.bool(forKey: SettingsKey.kioskOpen) {
        didSet {
            guard !ScreenshotMode.isOn else { return }
            UserDefaults.standard.set(kioskOpen, forKey: SettingsKey.kioskOpen)
        }
    }

    /// Starts Kiosk Mode, closing Family settings first if they're open.
    func openKiosk() {
        kidViewOpen = false
        guard sheet != nil else {
            kioskOpen = true
            return
        }
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            kioskOpen = true
        }
    }

    /// Opens Kid View on a kid, or on the last kid it showed.
    func openKidView(for memberID: UUID? = nil) {
        guard !kioskOpen else { return }
        if let memberID {
            UserDefaults.standard.set(memberID.uuidString, forKey: SettingsKey.kidViewMember)
        }
        kidViewOpen = true
    }

    /// caloma://calendar, caloma://approvals and so on, from widgets and notifications.
    func open(_ url: URL) {
        guard url.scheme == "caloma" else { return }
        switch url.host() {
        case "chores": tab = .chores
        case "calendar": tab = .calendar
        case "rewards": tab = .rewards
        case "homecare": tab = .homeCare
        case "control": tab = .control
        case "whiteboard": tab = .whiteboard
        case "directions":
            // From the "You're driving" Live Activity: hand the address to Maps.
            let to = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "to" }?.value
            if let to, let maps = DrivingAttributes.mapsURL(to: to) {
                UIApplication.shared.open(maps)
            }
        case "approvals":
            // A kid's device in Kid View, or the wall iPad, shouldn't open the parents' approvals.
            guard !kidViewOpen && !kioskOpen else { return }
            sheet = .approvals
        default: tab = .home
        }
    }

    /// Opens Kid View on "Who's doing chores?", so the kids pick.
    func openKidViewPicker() {
        guard !kioskOpen else { return }
        UserDefaults.standard.removeObject(forKey: SettingsKey.kidViewMember)
        kidViewOpen = true
    }
}

enum AppSheet: String, Identifiable {
    case newChore, newReward, approvals

    var id: String { rawValue }
}

/// Onboarding the first time, the tabs after that, and Kid View over everything when it's on.
/// A family that's already set up (on another device, or a household this account joined)
/// skips onboarding: a new device waits a moment for iCloud to say so before showing it.
struct AppRoot: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    /// Family-wide, from the family's settings in iCloud (SharedSettings).
    @AppStorage(SettingsKey.familySetUp) private var familySetUp = false
    /// A device that hasn't onboarded asks iCloud first, so it doesn't show Welcome to a family
    /// that's already set up.
    @State private var checkingCloud = !UserDefaults.standard.bool(forKey: SettingsKey.onboarded)
    @Environment(\.scenePhase) private var scenePhase
    @State private var household = HearthHouseholdStore.shared
    private var sync: CloudSync { CloudSync.shared }

    private var accent: Color { Brand.defaultAccent }

    /// What decides who Caloma's zone is shared with: the household, who's joined it, and the
    /// family zone's link.
    private var sharingKey: String {
        let joined = household.participants.filter { $0.acceptanceStatus == .accepted }.count
        return "\(household.exists)|\(household.mode)|\(household.account)|\(joined)|\(household.info?.appShareURLs[HearthApp.caloma.rawValue] ?? "")"
    }

    /// What's paid for: Caloma Plus or Hearth+, and Hearth+ for the other apps' data.
    private var planKey: String {
        "\(CalomaPlus.isUnlocked)|\(CalomaPlus.hasHearthPlus)"
    }

    /// Ends onboarding here when the family's already set up. True when it did (or already was).
    @discardableResult
    private func skipsOnboarding() -> Bool {
        guard !onboarded, !ScreenshotMode.isOn else { return onboarded }
        guard OnboardingFlow.familyIsSetUp() else { return false }
        OnboardingFlow.finishForSetUpFamily()
        checkingCloud = false
        return true
    }

    /// Caloma's part of a person's page in Household.
    private var personExtras: @MainActor (HearthMember) -> AnyView {
        { person in AnyView(CalomaPersonExtras(person: person)) }
    }

    var body: some View {
        @Bindable var router = router
        Group {
            if onboarded {
                RootTabView()
                    // The wall iPad: the family calendar and everyone's screens, nothing else.
                    .fullScreenCover(isPresented: Binding(get: { router.kioskOpen }, set: { router.kioskOpen = $0 })) {
                        // The Family Board is part of Caloma Plus and Hearth+.
                        Group {
                            if CalomaPlus.isUnlocked {
                                KioskRootView()
                            } else {
                                KioskLockedView()
                            }
                        }
                        .environment(\.accent, accent)
                    }
            } else if checkingCloud {
                CloudCheckView()
            } else {
                OnboardingView()
            }
        }
        .tint(accent)
        .environment(\.accent, accent)
        .animation(.smooth, value: onboarded)
        .animation(.smooth, value: checkingCloud)
        // Up to a few seconds for iCloud to answer: the household, and the family's Caloma
        // settings with it. No iCloud, or no answer in time, goes on to onboarding.
        .task {
            guard checkingCloud else { return }
            let deadline = ContinuousClock.now + .seconds(6)
            while ContinuousClock.now < deadline {
                if skipsOnboarding() { return }
                if household.account == .noAccount || household.account == .unavailable { break }
                if household.cloudLoaded {
                    // The family's zone comes in the same fetch; a moment for it to be applied.
                    try? await Task.sleep(for: .milliseconds(400))
                    if skipsOnboarding() { return }
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            checkingCloud = false
        }
        // The family's settings (or the household) can also arrive while onboarding is showing.
        .onChange(of: familySetUp) { _, _ in skipsOnboarding() }
        .onChange(of: household.isMember) { _, _ in skipsOnboarding() }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification).receive(on: RunLoop.main)) { _ in
            skipsOnboarding()
        }
        .sheet(item: $router.sheet) { sheet in
            Group {
                switch sheet {
                case .newChore: ChoreEditor(chore: nil)
                case .newReward: RewardEditor(reward: nil)
                case .approvals: ApprovalsView()
                }
            }
            .tint(accent)
            .environment(\.accent, accent)
            .environment(\.hearthPersonExtras, personExtras)
        }
        // Profile, opened by the photo at the top right of every main screen.
        .hearthProfile {
            FamilyView()
                .tint(accent)
                .environment(\.accent, accent)
                .environment(\.hearthPersonExtras, personExtras)
        }
        .fullScreenCover(isPresented: Binding(get: { onboarded && router.kidViewOpen }, set: { router.kidViewOpen = $0 })) {
            // A full-screen cover takes the presenter out of the window, so Kid View reads the
            // iPhone Duo pose itself (the pocket layout on the outer display).
            KidModeView()
                .environment(\.accent, accent)
                .hearthDuoPose()
        }
        .task {
            FamilyLists.clearFinished(in: context)
            EventAlerts.reschedule(in: context)
            AppleCalendar.shared.pushFamilyEvents(in: context)
            HearthLink.shared.start()
            // The family every Hearth app shares. Caloma's zone syncs on its engines, so
            // CloudSync registered before this.
            household.start(app: .caloma)
            sync.householdStarted()
            CalomaHousehold.sync(in: context)
            await sync.updateSharing()
        }
        .onChange(of: household.snapshot) { _, _ in
            sync.refreshLocation()
            CalomaHousehold.sync(in: context)
        }
        // iCloud has answered: anyone the household links to Caloma who still has no member
        // here gets one now (CalomaHousehold.sync), so Home always shows the kids.
        .onChange(of: household.cloudLoaded) { _, _ in CalomaHousehold.sync(in: context) }
        .onChange(of: sharingKey) { _, _ in
            Task { await sync.updateSharing() }
        }
        // A plan starting or ending: Home Care reminders, and Home Care and BigTable's dinner
        // on the watch and widgets, follow it.
        .onChange(of: planKey) { _, _ in
            Reminders.reschedule(in: context)
            WatchBridge.shared.setNeedsUpdate()
        }
        .hearthHouseholdInvitations()
        // Every Hearth app works inside a household (a household of one is fine).
        .hearthHouseholdRequired(isActive: onboarded && !ScreenshotMode.isOn, accent: Brand.defaultAccent)
        .environment(\.hearthPersonExtras, personExtras)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                // Coming back to the app: what changed. (Sync Now and pull to refresh read
                // everything.)
                await sync.syncNow(full: false)
                await sync.updateSharing()
            }
            FamilyLists.clearFinished(in: context)
            EventAlerts.reschedule(in: context)
            // "Coming up" and today's chores move on with the clock.
            WatchBridge.shared.setNeedsUpdate()
            HearthLink.shared.reload()
            CalomaHousehold.sync(in: context)
        }
        // Above any open sheet (Profile included), not waiting behind it (HearthProfile.swift).
        .hearthNotice(sync.notice ?? "", isPresented: Binding(get: { sync.notice != nil }, set: { if !$0 { sync.notice = nil } }))
        // Notifications open caloma://homecare, caloma://chores, caloma://rewards.
        .onOpenURL { url in router.open(url) }
    }
}

/// A new device, for a moment, while iCloud says whether the family already uses Caloma.
private struct CloudCheckView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Looking for your family in iCloud…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
