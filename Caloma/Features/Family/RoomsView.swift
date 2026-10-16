import SwiftData
import SwiftUI

/// Family › Rooms: the rooms chores can be assigned to. Add, rename, reorder or remove them.
struct RoomsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(filter: #Predicate<Room> { !$0.isArchived }, sort: \Room.sortOrder) private var rooms: [Room]
    @Query private var chores: [Chore]

    @State private var editing: Room?
    @State private var adding = false

    var body: some View {
        List {
            if rooms.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "door.left.hand.open")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("No rooms yet").font(.headline)
                        Text("Rooms are optional. They help kids know where a chore is, and let you see the board one room at a time.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else {
                Section {
                    ForEach(rooms) { room in
                        Button {
                            editing = room
                        } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: room.symbol, color: accent, size: 34)
                                Text(room.name).foregroundStyle(.primary)
                                Spacer()
                                let count = choreCount(room)
                                if count > 0 {
                                    Text(count == 1 ? "1 chore" : "\(count) chores")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Tap a room to rename it or change its icon. Drag to reorder.")
                }
            }

            Section {
                Button {
                    adding = true
                } label: {
                    Label("Add Room", systemImage: "plus.circle.fill")
                }
                Button {
                    withAnimation {
                        StarterData.insertRooms(into: context, existing: rooms)
                        Persistence.save(context)
                    }
                } label: {
                    Label("Add Common Rooms", systemImage: "house")
                }
            } footer: {
                Text("Kitchen, Living Room, Dining Room, Bathroom, Laundry Room, Garage, Yard and Playroom. Any you already have are skipped.")
            }
        }
        .refreshesFromICloud()
        .navigationTitle("Rooms")
        .toolbar {
            if !rooms.isEmpty {
                EditButton()
            }
        }
        .sheet(item: $editing) { room in
            RoomEditor(room: room)
        }
        .sheet(isPresented: $adding) {
            RoomEditor(room: nil)
        }
    }

    private func choreCount(_ room: Room) -> Int {
        chores.filter { $0.roomID == room.id && !$0.isArchived }.count
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = rooms
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, room) in ordered.enumerated() { room.sortOrder = index }
        Persistence.save(context)
    }
}

/// Adding or editing a room: its name and icon.
struct RoomEditor: View {
    var room: Room?
    /// Called with the room after saving, so New Chore can pick a room it just made.
    var onSave: ((Room) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query private var rooms: [Room]
    @Query private var chores: [Chore]

    @State private var name = ""
    @State private var symbol = "door.left.hand.closed"
    @State private var loaded = false
    @State private var confirmsDelete = false
    @State private var pickingIcon = false

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol, color: accent, size: 40)
                        TextField("Room name", text: $name)
                            .font(.title3)
                            .textInputAutocapitalization(.words)
                    }
                } footer: {
                    Text("Like Kitchen, Ella's Room or Basement.")
                }

                Section {
                    // Rooms don't have a color of their own: they show in the family's accent.
                    Button { pickingIcon = true } label: {
                        HearthIconColorLabel(icon: symbol, color: HearthColorChoice(hex: accent.hexValue), title: "Icon", showsColorName: false)
                    }
                    .hearthIconPicker(
                        isPresented: $pickingIcon, title: name, caption: "Room", context: .room,
                        icon: $symbol, tint: HearthColorChoice(hex: accent.hexValue)
                    )
                }

                if room != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmsDelete = true
                        } label: {
                            Label("Delete Room", systemImage: "trash")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .tint(.red)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("Chores in this room stay; they just won't have a room.")
                    }
                }
            }
            .contentMargins(.bottom, 56, for: .scrollContent)
            .navigationTitle(room == nil ? "New Room" : "Edit Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .alert("Delete \(name)?", isPresented: $confirmsDelete) {
                Button("Delete Room", role: .destructive) {
                    if let room {
                        for chore in chores where chore.roomID == room.id { chore.roomID = nil }
                        room.isArchived = true
                        Persistence.save(context)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let room {
                    name = room.name
                    symbol = room.symbol
                }
            }
        }
    }

    private func save() {
        let target: Room
        if let room {
            target = room
        } else {
            target = Room(name: name, symbol: symbol, sortOrder: (rooms.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.symbol = symbol
        Persistence.save(context)
        onSave?(target)
        dismiss()
    }
}

/// A small room label with its icon: "Kitchen".
struct RoomLabel: View {
    var room: Room
    var font: Font = .caption

    var body: some View {
        Label {
            Text(room.name)
        } icon: {
            Image(systemName: room.symbol)
        }
        .labelStyle(.titleAndIcon)
        .font(font)
        .lineLimit(1)
    }
}
