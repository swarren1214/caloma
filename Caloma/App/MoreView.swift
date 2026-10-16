import SwiftData
import SwiftUI

/// The tabs that don't fit in the iPhone tab bar. On iPad they're all in the sidebar.
enum MoreItem: Hashable, CaseIterable {
    case control, homeCare, whiteboard

    init?(_ tab: AppTab) {
        switch tab {
        case .control: self = .control
        case .homeCare: self = .homeCare
        case .whiteboard: self = .whiteboard
        default: return nil
        }
    }

    var tab: AppTab {
        switch self {
        case .control: .control
        case .homeCare: .homeCare
        case .whiteboard: .whiteboard
        }
    }
}

/// iPhone's More tab: Control, Home Care and Whiteboard as big cards, and the family's
/// shortcuts under them. Replaces the system More list, which only had icons to show since the
/// iPhone tab bar's labels are icon-only.
///
/// `router.tab` stays the source of truth: setting it to `.homeCare` from anywhere (Home's "See
/// All", a notification) opens More and pushes Home Care; going back to the list sets it to
/// `.more`.
struct MoreView: View {
    @Binding var path: NavigationPath

    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @Query(filter: #Predicate<HomeTask> { !$0.isArchived }) private var homeTasks: [HomeTask]
    /// What's pushed now, so a tab change that's already showing doesn't push it twice.
    @State private var showing: MoreItem?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(spacing: 12) {
                        card(.control, symbol: "lightswitch.on.fill", color: KidColor.teal.color, title: "Control", detail: "Lights, locks, climate and cameras from Apple Home.")
                        card(.homeCare, symbol: "wrench.and.screwdriver.fill", color: Brand.waiting, title: "Home Care", detail: homeCareDetail, badge: dueSoon > 0 ? "\(dueSoon)" : nil)
                        card(.whiteboard, symbol: "applepencil.and.scribble", color: Color(hex: 0x5E5CE6), title: "Whiteboard", detail: "Draw, plan and leave notes for the family.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("FAMILY")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                        VStack(spacing: 0) {
                            shortcut(symbol: "person.2.fill", color: accent, title: "Family & Settings") {
                                router.sheet = .family
                            }
                            Divider().padding(.leading, 62)
                            shortcut(symbol: "figure.child", color: KidColor.blue.color, title: "Kid View") {
                                router.openKidView()
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("More")
            .navigationDestination(for: MoreItem.self) { item in
                destination(item)
            }
            .screenshotDestinations()
        }
        .onChange(of: router.tab, initial: true) { _, tab in
            guard let item = MoreItem(tab), item != showing else { return }
            var newPath = NavigationPath()
            newPath.append(item)
            path = newPath
            showing = item
        }
        .onChange(of: path.count) { _, count in
            // Back to the list.
            guard count == 0 else { return }
            showing = nil
            if MoreItem(router.tab) != nil { router.tab = .more }
        }
    }

    @ViewBuilder
    private func destination(_ item: MoreItem) -> some View {
        switch item {
        case .control: ControlView()
        case .homeCare: HomeCareView()
        case .whiteboard: WhiteboardView()
        }
    }

    /// Home care tasks due in the next week, or late.
    private var dueSoon: Int {
        let soon = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        return homeTasks.filter { $0.nextDue <= soon }.count
    }

    private var homeCareDetail: String {
        switch dueSoon {
        case 0: homeTasks.isEmpty ? "Filters, smoke detectors and gutters, on time." : "Nothing due this week."
        case 1: "1 task due this week."
        case let count: "\(count) tasks due this week."
        }
    }

    private func card(_ item: MoreItem, symbol: String, color: Color, title: String, detail: String, badge: String? = nil) -> some View {
        Button {
            router.tab = item.tab
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(color.gradient, in: .rect(cornerRadius: 15, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Brand.waiting, in: Capsule())
                        .accessibilityLabel("\(badge) due soon")
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func shortcut(symbol: String, color: Color, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, color: color, size: 34)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MoreView(path: .constant(NavigationPath()))
        .previewEnvironment()
}
