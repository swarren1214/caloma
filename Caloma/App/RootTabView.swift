import SwiftUI

enum AppTab: Hashable {
    case home, chores, calendar, rewards, homeCare
}

/// The system Liquid Glass tab bar: Home, Chores, Calendar, Rewards and Home Care. On iPad it's a bar at
/// the top that opens into a sidebar.
struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(value: AppTab.home) {
                NavigationStack { HomeView() }
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

            Tab(value: AppTab.homeCare) {
                NavigationStack { HomeCareView() }
            } label: {
                tabLabel("Home Care", "wrench.and.screwdriver")
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
