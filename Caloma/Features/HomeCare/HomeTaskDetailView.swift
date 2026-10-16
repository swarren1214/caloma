import SwiftData
import SwiftUI

/// One home care task: Mark Done, hand it to a kid, its details, history and notes.
struct HomeTaskDetailView: View {
    @Bindable var task: HomeTask

    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \HomeTaskLog.doneAt, order: .reverse) private var allLogs: [HomeTaskLog]
    @Query private var chores: [Chore]

    @State private var editing = false
    @State private var giving: Member?
    @State private var justDone = false

    private var logs: [HomeTaskLog] { allLogs.filter { $0.taskID == task.id } }
    private var kids: [Member] { members.filter { $0.isKid && !$0.isArchived } }
    private var doneToday: Bool { logs.first.map { Calendar.current.isDateInToday($0.doneAt) } ?? false }

    /// A kid already has this as an open chore.
    private var handedTo: Member? {
        guard let chore = chores.first(where: { $0.homeTaskID == task.id && !$0.isArchived }),
              let kidID = chore.assigneeIDs.first else { return nil }
        let finished = logs.contains { $0.doneAt >= chore.createdAt }
        return finished ? nil : members.first { $0.id == kidID }
    }

    var body: some View {
        let due = HomeCareMath.due(task.nextDue)
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    IconTile(symbol: task.symbol, color: Color(hex: task.area.colorHex), size: 72)
                    Text(task.name)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    statusPill(due)
                }
                .padding(.top, 8)

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy) {
                            if doneToday {
                                Family.undoLastHomeTask(task, in: context)
                            } else {
                                Family.markHomeTaskDone(task, by: UUID(uuidString: currentMember), in: context)
                                justDone.toggle()
                            }
                        }
                    } label: {
                        Label(doneToday ? "Done" : "Mark Done", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .sensoryFeedback(.success, trigger: justDone)

                    if !kids.isEmpty {
                        Menu {
                            Section("Give to") {
                                ForEach(kids) { kid in
                                    Button(kid.name) { giving = kid }
                                }
                            }
                        } label: {
                            Label(handedTo.map { "With \($0.name)" } ?? "Give to a Kid", systemImage: PointWords.current().symbol)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }

                detailsCard
                historyCard
                if !task.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("NOTES")
                        Card {
                            Text(task.notes)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .refreshesFromICloud()
        .navigationTitle(task.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            HomeTaskEditor(task: task)
        }
        .sheet(item: $giving) { kid in
            GiveTaskSheet(task: task, kid: kid)
                .presentationDetents([.medium])
        }
    }

    private func statusPill(_ due: HomeDue) -> some View {
        let text: String
        let color: Color
        if doneToday {
            text = "Done today · next due \(task.nextDue.formatted(.dateTime.month(.abbreviated).day()))"
            color = accent
        } else {
            switch due {
            case .overdue(let days):
                text = days == 1 ? "1 day overdue" : "\(days) days overdue"
                color = Brand.late
            case .today:
                text = "Due today"
                color = Brand.waiting
            default:
                text = "Due \(task.nextDue.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))"
                color = .secondary
            }
        }
        return Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.13), in: Capsule())
            .contentTransition(.opacity)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("DETAILS")
            VStack(spacing: 0) {
                detailRow("Repeats", task.intervalLabel)
                Divider().padding(.leading, 16)
                detailRow("Next Due", task.nextDue.formatted(date: .abbreviated, time: .omitted))
                Divider().padding(.leading, 16)
                detailRow("Area", task.area.label)
                if !task.location.isEmpty {
                    Divider().padding(.leading, 16)
                    detailRow("Where", task.location)
                }
                if !task.details.isEmpty {
                    Divider().padding(.leading, 16)
                    detailRow("Size or Model", task.details)
                }
                Divider().padding(.leading, 16)
                detailRow("Remind", task.remindDaysBefore == 0 ? "On the day" : "\(task.remindDaysBefore) days before")
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("HISTORY")
            if logs.isEmpty {
                Card { Text("Not done yet in Caloma.").foregroundStyle(.secondary) }
            } else {
                CardList(items: Array(logs.prefix(8)), inset: 16) { log in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(log.doneAt.formatted(date: .abbreviated, time: .omitted))
                            Text(members.first { $0.id == log.memberID }?.name ?? "Someone")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(log.daysLate == 0 ? "On time" : (log.daysLate == 1 ? "1 day late" : "\(log.daysLate) days late"))
                            .font(.subheadline)
                            .foregroundStyle(log.daysLate == 0 ? Color.secondary : Brand.waiting)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                }
            }
        }
    }
}

/// Handing a home care task to a kid: how many points it's worth.
private struct GiveTaskSheet: View {
    var task: HomeTask
    var kid: Member

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var points = 20

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        MemberAvatar(kid, size: 44)
                        VStack(alignment: .leading) {
                            Text(task.name).font(.headline)
                            Text("Shows up on \(kid.name)'s board until it's done. When you approve it, the task is marked done here too.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Worth") {
                    Stepper(value: $points, in: 5...500, step: 5) {
                        PointsLabel(points: points, font: .body)
                    }
                }
            }
            .navigationTitle("Give to \(kid.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Give") {
                        Family.give(task, to: kid, points: points, in: context)
                        dismiss()
                    }
                }
            }
        }
    }
}
