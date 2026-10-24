import SwiftData
import SwiftUI

/// Family › Devices: every iPhone and iPad running Caloma for the family, what each is called
/// and where it is. Names and rooms sync, so a board renamed from a parent's phone shows the new
/// name everywhere, and the intercom calls it by that name.
struct DevicesView: View {
    @Query(sort: \HouseDevice.createdAt) private var devices: [HouseDevice]
    @Query(sort: \Room.sortOrder) private var rooms: [Room]
    @Environment(\.modelContext) private var context
    @State private var service = IntercomService.shared

    private var me: HouseDevice? { devices.first { $0.id == DeviceIdentity.id } }
    private var boards: [HouseDevice] { devices.filter { $0.isBoard && $0.id != DeviceIdentity.id }.sorted(by: Self.byName) }
    private var others: [HouseDevice] { devices.filter { !$0.isBoard && $0.id != DeviceIdentity.id }.sorted(by: Self.byName) }

    private static func byName(_ a: HouseDevice, _ b: HouseDevice) -> Bool {
        a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }

    var body: some View {
        List {
            if service.networkDenied {
                LocalNetworkOffSection()
            }
            if let me {
                Section {
                    NavigationLink {
                        DeviceEditor(device: me)
                    } label: {
                        DeviceRow(device: me, room: room(me), status: "This \(me.kind.label)")
                    }
                } header: {
                    Text("This Device")
                }
            }
            if !boards.isEmpty {
                Section {
                    ForEach(boards) { device in
                        NavigationLink {
                            DeviceEditor(device: device)
                        } label: {
                            DeviceRow(device: device, room: room(device), status: status(device))
                        }
                    }
                } header: {
                    Text("Family Boards")
                } footer: {
                    Text("Name each board after where it is, so everyone knows which one they're calling.")
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { device in
                        NavigationLink {
                            DeviceEditor(device: device)
                        } label: {
                            DeviceRow(device: device, room: room(device), status: status(device))
                        }
                    }
                } header: {
                    Text("Phones and iPads")
                }
            }
            if boards.isEmpty {
                Section {
                    Label("Start the Family Board on an iPad and it shows up here, ready to name and call.", systemImage: "rectangle.inset.filled.and.person.filled")
                        .foregroundStyle(.secondary)
                        .tint(.secondary)
                }
            }
        }
        .navigationTitle("Devices")
        .onAppear { DeviceRegistry.register(in: context) }
    }

    private func room(_ device: HouseDevice) -> Room? {
        guard let id = device.roomID else { return nil }
        return rooms.first { $0.id == id }
    }

    private func status(_ device: HouseDevice) -> String {
        if service.isOnline(device.id) { return "Available" }
        return "Seen " + device.lastSeen.formatted(.relative(presentation: .named))
    }
}

struct DeviceRow: View {
    let device: HouseDevice
    let room: Room?
    let status: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                Text([room?.name, status].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: device.symbol)
        }
        // The icon in the text's color.
        .tint(.primary)
    }
}

/// One device's name, room and calls.
struct DeviceEditor: View {
    @Bindable var device: HouseDevice
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Room.sortOrder) private var rooms: [Room]
    @State private var service = IntercomService.shared
    @State private var name = ""
    @State private var loaded = false
    @State private var addingRoom = false
    @State private var confirmsRemove = false

    private var isThisDevice: Bool { device.id == DeviceIdentity.id }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .onSubmit(saveName)
            } header: {
                Text("Name")
            } footer: {
                Text(device.isBoard ? "Like \"Kitchen Board\" or \"Playroom\"." : "Shown when this device calls a Family Board.")
            }

            Section {
                Picker("Room", selection: Binding(get: { device.roomID }, set: { setRoom($0) })) {
                    Text("None").tag(UUID?.none)
                    ForEach(rooms.filter { !$0.isArchived }) { room in
                        Label(room.name, systemImage: room.symbol).tag(Optional(room.id))
                    }
                }
                Button("New Room…") { addingRoom = true }
            } header: {
                Text("Where Is It?")
            }

            Section {
                Toggle("Takes Intercom Calls", isOn: Binding(get: { device.takesCalls }, set: {
                    device.takesCalls = $0
                    device.updatedAt = .now
                    Persistence.save(context)
                }))
                if !isThisDevice {
                    Button {
                        CallCenter.shared.find(device)
                    } label: {
                        Label("Show Name on Its Screen", systemImage: "sparkle.magnifyingglass")
                            .tint(.primary)
                    }
                    .disabled(!service.isOnline(device.id))
                }
            } footer: {
                if !isThisDevice && !service.isOnline(device.id) {
                    Text("It isn't on this Wi-Fi right now (or Caloma isn't open on it).")
                }
            }

            Section {
                LabeledContent("Device", value: device.model.isEmpty ? device.kind.label : device.model)
                LabeledContent("Last Seen") {
                    Text(isThisDevice || service.isOnline(device.id) ? "Now" : device.lastSeen.formatted(.relative(presentation: .named)))
                }
            }

            if !isThisDevice {
                Section {
                    Button("Remove from Devices", role: .destructive) { confirmsRemove = true }
                } footer: {
                    Text("It comes back if Caloma opens on it again.")
                }
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = device.name
        }
        .onDisappear(perform: saveName)
        .sheet(isPresented: $addingRoom) {
            RoomEditor(room: nil) { room in setRoom(room.id) }
        }
        .alert("Remove \(device.displayName)?", isPresented: $confirmsRemove) {
            Button("Remove", role: .destructive) {
                // Off screen first: the editor mustn't draw a deleted device.
                let removed = device
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    context.delete(removed)
                    Persistence.save(context)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It won't show in Devices or the intercom until Caloma opens on it again.")
        }
    }

    private func saveName() {
        guard device.modelContext != nil, !device.isDeleted else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != device.name else { return }
        DeviceRegistry.rename(device, to: trimmed, room: device.roomID, in: context)
    }

    private func setRoom(_ id: UUID?) {
        DeviceRegistry.rename(device, to: device.name, room: id, in: context)
    }
}

/// The first time the Family Board opens on an iPad: what to call it and where it is.
struct NameBoardSheet: View {
    @Bindable var device: HouseDevice
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Room.sortOrder) private var rooms: [Room]
    @State private var name = ""
    @State private var room: UUID?
    /// The name still follows the room ("Kitchen Board") until someone types their own.
    @State private var nameFollowsRoom = true
    @State private var addingRoom = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: Binding(get: { name }, set: {
                        name = $0
                        nameFollowsRoom = false
                    }))
                    .font(.title3)
                } header: {
                    Text("Name")
                } footer: {
                    Text("So the family knows which board they're calling, and where it is.")
                }
                Section {
                    Picker("Room", selection: Binding(get: { room }, set: { pick($0) })) {
                        Text("None").tag(UUID?.none)
                        ForEach(rooms.filter { !$0.isArchived }) { room in
                            Label(room.name, systemImage: room.symbol).tag(Optional(room.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("New Room…") { addingRoom = true }
                } header: {
                    Text("Where Is It?")
                } footer: {
                    Text("Change it later in Family › Devices on any parent's phone.")
                }
            }
            .navigationTitle("Name This Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { finish(keepingName: true) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish(keepingName: false) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $addingRoom) {
                RoomEditor(room: nil) { new in pick(new.id) }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            name = device.name
            room = device.roomID
        }
    }

    private func pick(_ id: UUID?) {
        room = id
        guard nameFollowsRoom else { return }
        if let id, let picked = rooms.first(where: { $0.id == id }) {
            name = "\(picked.name) Board"
        } else {
            name = "Family Board"
        }
    }

    private func finish(keepingName: Bool) {
        DeviceRegistry.rename(device, to: keepingName ? device.name : name, room: keepingName ? device.roomID : room, in: context)
        dismiss()
    }
}

/// Local Network turned off for Caloma: the intercom can't see anything.
struct LocalNetworkOffSection: View {
    var body: some View {
        Section {
            Label("Turn on Local Network for Caloma in Settings to call the family's devices at home.", systemImage: "wifi.exclamationmark")
                .tint(.primary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }
}
