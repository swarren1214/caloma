import SwiftData
import SwiftUI

/// Chores › Rotations: chore groups that pass from person to person, and single chores that
/// take turns. Tap one for whose turn it is next, and to skip, swap or pause a turn.
struct RotationsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var groups: [ChoreGroup]
    @Query private var chores: [Chore]
    @Query(filter: #Predicate<Room> { !$0.isArchived }, sort: \Room.sortOrder) private var rooms: [Room]
    @AppStorage(SettingsKey.rotationMakeUp) private var makeUp = true

    @State private var newGroup: NewGroup?

    /// A new group, maybe started from a room's chores.
    struct NewGroup: Identifiable {
        let id = UUID()
        var roomID: UUID?
    }

    var body: some View {
        let summaries = Rotations.summaries(groups: groups, chores: chores)
        let fromGroups = summaries.filter(\.isGroup)
        let singles = summaries.filter { !$0.isGroup }
        List {
            if summaries.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("No rotations yet").font(.headline)
                        Text("Group chores like the kitchen or the bathrooms, then pass them from one person to the next each day, week or month.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }

            if !fromGroups.isEmpty {
                Section("Chore Groups") {
                    ForEach(fromGroups) { summary in
                        NavigationLink {
                            RotationDetailView(rotationID: summary.id)
                        } label: {
                            RotationRow(summary: summary, members: members)
                        }
                    }
                    .onMove(perform: moveGroups)
                }
            }

            if !singles.isEmpty {
                Section {
                    ForEach(singles) { summary in
                        NavigationLink {
                            RotationDetailView(rotationID: summary.id)
                        } label: {
                            RotationRow(summary: summary, members: members)
                        }
                    }
                } header: {
                    Text("Single Chores That Rotate")
                } footer: {
                    Text("Turn on Take Turns when you edit a chore to add it here.")
                }
            }

            Section {
                Button {
                    newGroup = NewGroup()
                } label: {
                    Label("New Chore Group", systemImage: "plus.circle.fill")
                }
                .tint(.primary)
                if !roomsWithChores.isEmpty {
                    Menu {
                        ForEach(roomsWithChores) { room in
                            Button(room.name, menuIcon: room.symbol) { newGroup = NewGroup(roomID: room.id) }
                        }
                    } label: {
                        Label("Group a Room’s Chores", systemImage: "door.left.hand.open")
                    }
                    .tint(.primary)
                }
            } footer: {
                Text("A group passes its chores along together: one person has the whole kitchen this week, the next person has it next week.")
            }

            if !summaries.isEmpty {
                Section {
                    NavigationLink {
                        RotationChartView()
                    } label: {
                        Label("Rotation Chart", systemImage: "tablecells")
                            // The row's icon in its text color, not the app's.
                            .tint(.primary)
                    }
                    Toggle(isOn: $makeUp) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Make Up Skipped Turns")
                                Text("Someone who skips takes the next person’s turn")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        // On the label only, so the switch keeps the app's color.
                        .tint(.primary)
                    }
                } footer: {
                    Text(makeUp
                         ? "When someone skips, they trade with the next person, so everyone still does their share."
                         : "When someone skips, everyone after them moves up one, and they wait for their next turn.")
                }
            }
        }
        .tint(accent)
        .refreshesFromICloud()
        .navigationTitle("Rotations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newGroup = NewGroup()
                } label: {
                    Label("New Chore Group", systemImage: "plus")
                }
            }
        }
        .sheet(item: $newGroup) { start in
            ChoreGroupEditor(group: nil, roomID: start.roomID)
        }
    }

    private var roomsWithChores: [Room] {
        rooms.filter { room in chores.contains { $0.roomID == room.id && !$0.isArchived } }
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        var ordered = groups.filter { !$0.isArchived }.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, group) in ordered.enumerated() where group.sortOrder != index { group.sortOrder = index }
        Persistence.save(context)
    }
}

#Preview {
    NavigationStack { RotationsView() }
        .previewEnvironment()
}
