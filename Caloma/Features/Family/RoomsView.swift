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
    @State private var bridge = HomeBridge.shared
    /// Waiting for Apple Home to answer (the permission prompt, or the homes loading).
    @State private var importing = false
    @State private var importNotice: ImportNotice?
    @Environment(\.openURL) private var openURL

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
                    importFromHome()
                } label: {
                    HStack {
                        Label("Import from Apple Home", systemImage: "homekit")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing)
                Button {
                    withAnimation {
                        StarterData.insertRooms(into: context, existing: rooms)
                        Persistence.save(context)
                    }
                } label: {
                    Label("Add Common Rooms", systemImage: "house")
                }
            } footer: {
                Text("Import brings in the rooms from \(bridge.homeTitle ?? "the Home app"), each with an icon you can change. Common rooms are Kitchen, Living Room, Dining Room, Bathroom, Laundry Room, Garage, Yard and Playroom. Rooms you already have are skipped.")
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
        // Apple Home answers after the permission prompt, or once the homes have loaded.
        .onChange(of: bridge.homeNames) {
            if importing { finishImport() }
        }
        .onChange(of: bridge.authorized) { _, allowed in
            if importing && allowed != nil { finishImport() }
        }
        .alert(importNotice?.title ?? "", isPresented: Binding(get: { importNotice != nil }, set: { if !$0 { importNotice = nil } }), presenting: importNotice) { notice in
            if notice.opensSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: Import from Apple Home

    private struct ImportNotice {
        var title: String
        var message: String
        var opensSettings = false
    }

    private func importFromHome() {
        bridge.start()
        guard bridge.authorized == nil else {
            finishImport()
            return
        }
        // First time: HomeKit asks for permission, then hands over the homes.
        importing = true
        Task {
            try? await Task.sleep(for: .seconds(10))
            if importing { finishImport() }
        }
    }

    private func finishImport() {
        importing = false
        guard bridge.authorized == true else {
            importNotice = ImportNotice(
                title: "Caloma can't see your home",
                message: "Allow Caloma to use your Home data in Settings, then try again.",
                opensSettings: true
            )
            return
        }
        let names = bridge.homeRoomNames
        guard !names.isEmpty else {
            importNotice = ImportNotice(
                title: bridge.homeNames.isEmpty ? "No home set up yet" : "No rooms in \(bridge.homeTitle ?? "your home")",
                message: "Add rooms in the Home app, and they can come into Caloma from here."
            )
            return
        }
        var added = 0
        withAnimation {
            added = HomeRoomImport.insert(names, into: context, existing: rooms)
            Persistence.save(context)
        }
        if added == 0 {
            importNotice = ImportNotice(
                title: "Already up to date",
                message: "Every room in \(bridge.homeTitle ?? "your home") is already here."
            )
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
