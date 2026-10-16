import SwiftData
import SwiftUI

/// Home Care: what's overdue, what's coming up, and everything else, by date or by area.
struct HomeCareView: View {
    @Environment(\.accent) private var accent
    @Query(filter: #Predicate<HomeTask> { !$0.isArchived }, sort: \HomeTask.nextDue) private var tasks: [HomeTask]
    @Query private var logs: [HomeTaskLog]

    @State private var grouping: Grouping = .upcoming
    @State private var addingTask = false

    enum Grouping: String, CaseIterable, Identifiable {
        case upcoming = "Upcoming", area = "By Area"
        var id: String { rawValue }
    }

    var body: some View {
        CalomaScreen(title: "Home Care") {
            summary
            Picker("Group by", selection: $grouping) {
                ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if tasks.isEmpty {
                EmptyCard(symbol: "wrench.and.screwdriver", title: "Nothing to look after yet", message: "Add the things that need doing now and then, and Caloma will remind you.")
            }
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.title3.bold())
                        .foregroundStyle(group.isLate ? Brand.late : Color.primary)
                        .padding(.horizontal, 4)
                        .accessibilityAddTraits(.isHeader)
                    CardList(items: group.tasks) { task in
                        NavigationLink {
                            HomeTaskDetailView(task: task)
                        } label: {
                            HomeTaskRow(task: task, showsArea: grouping == .upcoming)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Group {
                    Button {
                        addingTask = true
                    } label: {
                        Label("New Task", systemImage: "plus")
                    }
                }
                // White over the color header.
                .tint(.white)
            }
        }
        .sheet(isPresented: $addingTask) {
            HomeTaskEditor(task: nil)
        }
    }

    private var summary: some View {
        let overdue = tasks.filter { if case .overdue = HomeCareMath.due($0.nextDue) { return true } else { return false } }.count
        let soon = tasks.filter {
            switch HomeCareMath.due($0.nextDue) {
            case .today, .soon: return true
            default: return false
            }
        }.count
        let year = Calendar.current.dateInterval(of: .year, for: .now)?.start ?? .now
        let done = logs.filter { $0.doneAt >= year }.count
        return HStack(spacing: 10) {
            summaryTile(overdue, "Overdue", overdue > 0 ? Brand.late : Color.secondary)
            summaryTile(soon, "Next 30 days", Brand.waiting)
            summaryTile(done, "Done this year", accent)
        }
    }

    private func summaryTile(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title.bold())
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private struct DueGroup {
        var title: String
        var tasks: [HomeTask]
        var isLate = false
    }

    private var groups: [DueGroup] {
        switch grouping {
        case .upcoming:
            var overdue: [HomeTask] = [], soon: [HomeTask] = [], later: [HomeTask] = []
            for task in tasks {
                switch HomeCareMath.due(task.nextDue) {
                case .overdue: overdue.append(task)
                case .today, .soon: soon.append(task)
                case .later: later.append(task)
                }
            }
            return [
                DueGroup(title: "Overdue", tasks: overdue, isLate: true),
                DueGroup(title: "Next 30 Days", tasks: soon),
                DueGroup(title: "Later", tasks: later),
            ].filter { !$0.tasks.isEmpty }
        case .area:
            return HomeArea.allCases.compactMap { area in
                let mine = tasks.filter { $0.area == area }
                return mine.isEmpty ? nil : DueGroup(title: area.label, tasks: mine)
            }
        }
    }
}

/// A home care task in a list: its area-colored icon, name, how often, and when it's due.
struct HomeTaskRow: View {
    var task: HomeTask
    var showsArea = true

    var body: some View {
        let due = HomeCareMath.due(task.nextDue)
        HStack(spacing: 12) {
            IconTile(symbol: task.symbol, color: Color(hex: task.area.colorHex), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name).lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(HomeCareMath.dueLabel(task.nextDue))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color(for: due))
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsArea { parts.append(task.area.label) }
        parts.append(task.intervalLabel)
        if !task.location.isEmpty { parts.append(task.location) }
        return parts.joined(separator: " · ")
    }

    private func color(for due: HomeDue) -> Color {
        switch due {
        case .overdue: Brand.late
        case .today: Brand.waiting
        case .soon(let days) where days <= 7: Brand.waiting
        default: .secondary
        }
    }
}

#Preview {
    NavigationStack { HomeCareView() }
        .previewEnvironment()
}
