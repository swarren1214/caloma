import SwiftUI

enum AppTab: Hashable {
    case home, chores, calendar, rewards, control, homeCare, whiteboard
    /// iPhone only: Control, Home Care and Whiteboard (see `MoreView`).
    case more
}

/// The system Liquid Glass tab bar: Home, Chores, Calendar, Rewards, Control, Home Care and
/// Whiteboard. On iPad it's a bar at the top that opens into a sidebar; on iPhone, Control, Home
/// Care and Whiteboard sit under Caloma's own More tab (the system's only had icons to show).
struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Only screenshot mode pushes onto these; the tabs' own links push as before.
    @State private var homePath = NavigationPath()
    @State private var homeCarePath = NavigationPath()

    var body: some View {
        TabView(selection: selection) {
            Tab(value: AppTab.home) {
                NavigationStack(path: $homePath) { HomeView().screenshotDestinations() }
            } label: {
                tabLabel("Home", "house")
            }

            Tab(value: AppTab.chores) {
                NavigationStack { ChoresView() }
            } label: {
                tabLabel("Chores", "checklist")
            }

            Tab(value: AppTab.calendar) {
                NavigationStack { CalendarView() }
            } label: {
                tabLabel("Calendar", "calendar")
            }

            Tab(value: AppTab.rewards) {
                NavigationStack { RewardsView() }
            } label: {
                tabLabel("Rewards", "gift")
            }

            if sizeClass == .regular {
                Tab(value: AppTab.control) {
                    NavigationStack { ControlView() }
                } label: {
                    tabLabel("Control", "lightswitch.on")
                }

                Tab(value: AppTab.homeCare) {
                    NavigationStack(path: $homeCarePath) { HomeCareView().screenshotDestinations() }
                } label: {
                    tabLabel("Home Care", "wrench.and.screwdriver")
                }

                Tab(value: AppTab.whiteboard) {
                    NavigationStack { WhiteboardView() }
                } label: {
                    tabLabel("Whiteboard", "applepencil.and.scribble")
                }
            } else {
                Tab(value: AppTab.more) {
                    MoreView(path: $homeCarePath)
                } label: {
                    tabLabel("More", "ellipsis")
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // On iPad the calendar's family filters live under the tabs, so there's one sidebar.
        .tabViewSidebarFooter {
            if router.tab == .calendar && sizeClass == .regular {
                CalendarSidebarFilters()
                    .transition(.opacity)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Debug: marketing screenshots. Does nothing otherwise.
        .screenshotStage(homePath: $homePath, homeCarePath: $homeCarePath)
    }

    /// On iPhone, Control, Home Care and Whiteboard show as More; on iPad, More is never a tab.
    private var selection: Binding<AppTab> {
        Binding {
            switch (sizeClass, router.tab) {
            case (.regular?, .more): .home
            case (.regular?, _): router.tab
            case (_, let tab) where MoreItem(tab) != nil: .more
            default: router.tab
            }
        } set: { router.tab = $0 }
    }

    /// Icon only in the iPhone tab bar (VoiceOver still reads the name); icon and name on iPad.
    @ViewBuilder
    private func tabLabel(_ title: String, _ systemImage: String) -> some View {
        if sizeClass == .regular {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
        }
    }
}

#Preview {
    RootTabView()
        .previewEnvironment()
}
