import SwiftData
import SwiftUI

@main
struct CalomaApp: App {
    @State private var router = AppRouter.shared
    private let container: ModelContainer

    init() {
        let container = Persistence.makeContainer()
        self.container = container
        StarterData.seedIfNeeded(in: container.mainContext)
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
            Button("New Chore") { router.sheet = .newChore }
                .keyboardShortcut("n")
            Button("New Reward") { router.sheet = .newReward }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Home") { router.tab = .home }.keyboardShortcut("1")
            Button("Chores") { router.tab = .chores }.keyboardShortcut("2")
            Button("Rewards") { router.tab = .rewards }.keyboardShortcut("3")
            Button("Home Care") { router.tab = .homeCare }.keyboardShortcut("4")
            Divider()
            Button("Needs Your OK") { router.sheet = .approvals }.keyboardShortcut("o")
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

    /// Kid View covers the whole app. Remembered, so a kid's iPad opens back into it.
    var kidViewOpen: Bool = UserDefaults.standard.bool(forKey: SettingsKey.kidViewOpen) {
        didSet { UserDefaults.standard.set(kidViewOpen, forKey: SettingsKey.kidViewOpen) }
    }

    /// Opens Kid View on a kid, or on the last kid it showed.
    func openKidView(for memberID: UUID? = nil) {
        if let memberID {
            UserDefaults.standard.set(memberID.uuidString, forKey: SettingsKey.kidViewMember)
        }
        kidViewOpen = true
    }

    /// Opens Kid View on "Who's doing chores?", so the kids pick.
    func openKidViewPicker() {
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

    private var accent: Color { Color(hexString: accentHex) ?? Brand.defaultAccent }

    var body: some View {
        @Bindable var router = router
        Group {
            if onboarded {
                RootTabView()
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
        // Notifications open caloma://homecare, caloma://chores, caloma://rewards.
        .onOpenURL { url in
            guard url.scheme == "caloma" else { return }
            switch url.host() {
            case "chores": router.tab = .chores
            case "rewards": router.tab = .rewards
            case "homecare": router.tab = .homeCare
            default: router.tab = .home
            }
        }
    }
}
