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
        // Screenshot mode (Debug only) runs on an in-memory store of demo content, with no
        // sync, watch or settings mirroring, so the device's own family and iCloud are untouched.
        let container = Persistence.makeContainer(inMemory: ScreenshotMode.isOn)
        self.container = container
        AppRouter.shared.container = container
        guard !ScreenshotMode.isOn else { return }
        // Starter home care is added at the end of onboarding, so a device that picks up a
        // family already in iCloud doesn't add a second copy.
        if UserDefaults.standard.bool(forKey: SettingsKey.onboarded) {
            StarterData.seedIfNeeded(in: container.mainContext)
        }
        Upgrades.run(in: container.mainContext)
        CloudSync.shared.start(with: container)
        SharedSettings.shared.start(with: container)
        WatchBridge.shared.start(with: container)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(router)
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
            Button("Home Care") { router.tab = .homeCare }.keyboardShortcut("5")
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
    case newChore, newReward, approvals, family

    var id: String { rawValue }
}

/// Onboarding the first time, the tabs after that, and Kid View over everything when it's on.
struct AppRoot: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @AppStorage(SettingsKey.accentHex) private var accentHex = hexString(Brand.defaultAccentHex)
    @Environment(\.scenePhase) private var scenePhase
    private var sync: CloudSync { CloudSync.shared }

    private var accent: Color { Color(hexString: accentHex) ?? Brand.defaultAccent }

    var body: some View {
        @Bindable var router = router
        Group {
            if onboarded {
                RootTabView()
                    // The wall iPad: the family calendar and everyone's screens, nothing else.
                    .fullScreenCover(isPresented: Binding(get: { router.kioskOpen }, set: { router.kioskOpen = $0 })) {
                        KioskRootView()
                            .environment(\.accent, accent)
                    }
            } else {
                OnboardingView()
            }
        }
        .tint(accent)
        .environment(\.accent, accent)
        .animation(.smooth, value: onboarded)
        .sheet(item: $router.sheet) { sheet in
            Group {
                switch sheet {
                case .newChore: ChoreEditor(chore: nil)
                case .newReward: RewardEditor(reward: nil)
                case .approvals: ApprovalsView()
                case .family: NavigationStack { FamilyView() }
                }
            }
            .tint(accent)
            .environment(\.accent, accent)
        }
        .fullScreenCover(isPresented: Binding(get: { onboarded && router.kidViewOpen }, set: { router.kidViewOpen = $0 })) {
            KidModeView()
                .environment(\.accent, accent)
        }
        .task {
            EventAlerts.reschedule(in: context)
            AppleCalendar.shared.pushFamilyEvents(in: context)
            HearthLink.shared.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await CloudSync.shared.syncNow() }
            EventAlerts.reschedule(in: context)
            // "Coming up" and today's chores move on with the clock.
            WatchBridge.shared.setNeedsUpdate()
            HearthLink.shared.reload()
        }
        .sheet(item: Binding(get: { sync.pendingInvite.map(InviteRef.init) }, set: { if $0 == nil { sync.pendingInvite = nil } })) { invite in
            JoinFamilySheet(metadata: invite.metadata)
                .tint(accent)
                .environment(\.accent, accent)
        }
        .alert(sync.notice ?? "", isPresented: Binding(get: { sync.notice != nil }, set: { if !$0 { sync.notice = nil } })) {
            Button("OK") { sync.notice = nil }
        }
        // Notifications open caloma://homecare, caloma://chores, caloma://rewards.
        .onOpenURL { url in router.open(url) }
    }
}

/// An invitation waiting for an answer, for `.sheet(item:)`.
struct InviteRef: Identifiable {
    var metadata: CKShare.Metadata
    var id: String { metadata.share.recordID.recordName + metadata.share.recordID.zoneID.ownerName }
}

/// "Join the family?" after tapping an invitation. Joining replaces what's on this device.
struct JoinFamilySheet: View {
    var metadata: CKShare.Metadata
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var joining = false

    private var familyName: String {
        metadata.share[CKShare.SystemFieldKey.title] as? String ?? "a family"
    }

    private var ownerName: String {
        metadata.ownerIdentity.nameComponents.map { $0.formatted(.name(style: .short)) } ?? "Someone"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(accent)
                .padding(.top, 28)
            Text("Join \(familyName)?")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("\(ownerName) invited you. You'll both see and change the same chores, rewards, points, home care and calendar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Label("Anything already in Caloma on this iPhone is replaced by the family's.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Brand.waiting)
                .padding(12)
                .background(Brand.waiting.opacity(0.12), in: .rect(cornerRadius: 14))
            Spacer()
            Button {
                joining = true
                Task {
                    await CloudSync.shared.acceptInvite()
                    dismiss()
                }
            } label: {
                HStack {
                    if joining { ProgressView().tint(.white) }
                    Text(joining ? "Joining…" : "Join Family")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .disabled(joining)
            Button("Not Now") {
                CloudSync.shared.pendingInvite = nil
                dismiss()
            }
            .disabled(joining)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(joining)
    }
}
