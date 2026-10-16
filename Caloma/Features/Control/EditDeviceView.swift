import HomeKit
import SwiftData
import SwiftUI

/// What the editor is changing before Save: Caloma's own style for the device.
struct DeviceDraft: Equatable {
    var symbol = ""
    var colorHex = ""
    var tileStyle: TileStyle = .tinted
    var photo: Data?
    var hidden = false
    var kidsAllowed = false
    var pinnedToHome = false

    init() {}

    init(_ style: DeviceStyle?) {
        guard let style else { return }
        symbol = style.symbol
        colorHex = style.colorHex
        tileStyle = style.tileStyle
        photo = style.photoData
        hidden = style.hidden
        kidsAllowed = style.kidsAllowed
        pinnedToHome = style.pinnedToHome
    }

    func apply(to style: DeviceStyle) {
        style.symbol = symbol
        style.colorHex = colorHex
        style.tileStyle = tileStyle
        style.photoData = photo
        style.hidden = hidden
        style.kidsAllowed = kidsAllowed
        style.pinnedToHome = pinnedToHome
    }

    var isEmpty: Bool {
        symbol.isEmpty && colorHex.isEmpty && tileStyle == .tinted && photo == nil && !hidden && !kidsAllowed && !pinnedToHome
    }
}

extension DeviceLook {
    /// The look a draft gives a device, for the editor's preview.
    init(kind: HomeControl.Kind, draft: DeviceDraft, accent: Color) {
        let defaults = Self.defaults(for: kind)
        symbolOn = draft.symbol.isEmpty ? defaults.on : draft.symbol
        symbolOff = draft.symbol.isEmpty ? defaults.off : draft.symbol
        color = Color(hexString: draft.colorHex) ?? Self.defaultColor(for: kind, accent: accent)
        tileStyle = draft.tileStyle
        photo = draft.photo
    }
}

/// Edit a device: its name and room (written to Apple Home, so Siri and the Home app agree),
/// what a plug shows as, and Caloma's own icon, color, style and photo, plus whether it shows
/// in Control, whether kids can use it, and whether it's pinned to Home.
struct EditDeviceView: View {
    var control: HomeControl

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query private var styles: [DeviceStyle]
    private let home = HomeBridge.shared

    @State private var draft = DeviceDraft()
    @State private var name = ""
    @State private var roomID: UUID?
    @State private var showAs: ShowAs?
    @State private var loaded = false
    @State private var saving = false
    @State private var problem: String?
    @State private var addingRoom = false
    @State private var newRoomName = ""

    private var existing: DeviceStyle? {
        StyleBook(styles).style(serviceID: control.id.uuidString, matchKey: control.matchKey)
    }

    /// The kind the tile will be once Show As is saved.
    private var kind: HomeControl.Kind {
        switch showAs {
        case .light?: .light
        case .fan?: .fan
        case .outlet?, .switch?: .switchOrOutlet
        case nil: control.kind
        }
    }

    var body: some View {
        let canEdit = home.canEditHome
        let look = DeviceLook(kind: kind, draft: draft, accent: accent)
        let roomName = home.homeRooms.first { $0.uniqueIdentifier == roomID }?.name ?? control.roomName
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 12) {
                        NavigationLink {
                            DeviceIconPicker(draft: $draft, name: displayName, kind: kind)
                        } label: {
                            DevicePreviewTile(name: displayName, detail: roomName, look: look, size: 176)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "pencil")
                                        .font(.footnote.weight(.bold))
                                        .frame(width: 30, height: 30)
                                        .background(.thinMaterial, in: Circle())
                                        .padding(12)
                                }
                        }
                        .buttonStyle(KidPressStyle())
                        .accessibilityLabel("Change icon and color")
                        NavigationLink {
                            DeviceIconPicker(draft: $draft, name: displayName, kind: kind)
                        } label: {
                            Text("Change Icon & Color")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 36)
                                .controlCard(cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)

                    field("NAME", note: canEdit ? "Also renames it in Apple Home and for Siri." : nil) {
                        TextField(control.name, text: $name)
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
                            .disabled(!canEdit)
                    }

                    field("ROOM", note: canEdit ? "Moves it in Apple Home too." : nil) {
                        RoomPicker(rooms: home.homeRooms.map { RoomOption(id: $0.uniqueIdentifier, name: $0.name) }, selection: $roomID, accent: accent) {
                            newRoomName = ""
                            addingRoom = true
                        }
                        .disabled(!canEdit)
                    }

                    if !canEdit {
                        Label("Only the home's owner, or someone they made an admin in the Home app, can rename or move devices. You can still change how it looks here.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }

                    if showAs != nil {
                        field("SHOW AS", note: "For plugs and switches: what's plugged in, so scenes and \u{201C}turn off the lights\u{201D} include it.") {
                            HStack(spacing: 6) {
                                ForEach(ShowAs.allCases) { option in
                                    let on = option == showAs
                                    Button {
                                        showAs = option
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: option.symbol)
                                                .font(.system(size: 18, weight: .semibold))
                                            Text(option.label)
                                                .font(.footnote.weight(.bold))
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 64)
                                        .foregroundStyle(on ? Color.primary : Color.secondary)
                                        .background(on ? accent.opacity(0.16) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 16, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? accent : .clear, lineWidth: 1.5)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(on ? .isSelected : [])
                                }
                            }
                            .disabled(!canEdit)
                        }
                    }

                    VStack(spacing: 0) {
                        toggle("Show in Control", detail: "Hide things you never touch", isOn: Binding(get: { !draft.hidden }, set: { draft.hidden = !$0 }))
                        Divider().padding(.leading, 14)
                        toggle("Kids can use it", detail: kind.isKidSafe ? "In Kid View and on the wall iPad" : "Only for lights, plugs, fans, shades and purifiers", isOn: $draft.kidsAllowed)
                            .disabled(!kind.isKidSafe)
                        Divider().padding(.leading, 14)
                        toggle("Pin to Home", detail: "A shortcut on the Home tab", isOn: $draft.pinnedToHome)
                    }
                    .controlCard()

                    Text("Name and room sync to Apple Home. Icons, colors and photos are Caloma's own, so you can pick anything, and they sync to everyone in your family.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Edit Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        SheetDoneButton("Save", action: save)
                            .fontWeight(.semibold)
                    }
                }
            }
            .alert("New Room", isPresented: $addingRoom) {
                TextField("Playroom", text: $newRoomName)
                Button("Cancel", role: .cancel) {}
                Button("Add") { addRoom() }
            } message: {
                Text("It's added to your home in Apple Home too.")
            }
            .alert("Couldn't Change Everything", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") { dismiss() }
            } message: {
                Text(problem ?? "")
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = DeviceDraft(existing)
            name = control.name
            roomID = control.accessory.room?.uniqueIdentifier
            showAs = home.showAs(control)
        }
        .interactiveDismissDisabled(saving)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? control.name : trimmed
    }

    private func field<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCard()
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func addRoom() {
        let wanted = newRoomName
        Task {
            do {
                let room = try await home.addRoom(named: wanted)
                if let room { roomID = room.uniqueIdentifier }
            } catch {
                problem = HomeBridge.describe(error)
            }
        }
    }

    private func save() {
        saving = true
        Task {
            var problems: [String] = []
            if home.canEditHome {
                do {
                    try await home.rename(control, to: name)
                } catch {
                    problems.append(HomeBridge.describe(error))
                }
                if let roomID {
                    do {
                        try await home.move(control, to: roomID)
                    } catch {
                        problems.append(HomeBridge.describe(error))
                    }
                }
                if let showAs, showAs != home.showAs(control) {
                    do {
                        try await home.setShowAs(control, showAs)
                    } catch {
                        problems.append(HomeBridge.describe(error))
                    }
                }
            }
            saveStyle(renamed: problems.isEmpty)
            saving = false
            if let first = problems.first {
                problem = first
            } else {
                dismiss()
            }
        }
    }

    /// Writes Caloma's style, keyed by the service and by the name and room it has now.
    private func saveStyle(renamed: Bool) {
        let finalName = renamed ? displayName : control.name
        let finalRoom = renamed ? (home.homeRooms.first { $0.uniqueIdentifier == roomID }?.name ?? control.roomName) : control.roomName
        let key = DeviceMatch.key(name: finalName, room: finalRoom, kind: kind.rawValue)
        if let style = existing {
            if draft.isEmpty {
                context.delete(style)
            } else {
                draft.apply(to: style)
                style.serviceID = control.id.uuidString
                style.matchKey = key
                style.homeID = home.home?.uniqueIdentifier.uuidString ?? style.homeID
                style.updatedAt = .now
            }
        } else if !draft.isEmpty {
            let style = DeviceStyle(homeID: home.home?.uniqueIdentifier.uuidString ?? "", serviceID: control.id.uuidString, matchKey: key)
            draft.apply(to: style)
            context.insert(style)
        }
        try? context.save()
    }
}

private struct RoomOption: Identifiable {
    let id: UUID
    let name: String
}

/// Rooms as chips, the chosen one filled, then New Room.
private struct RoomPicker: View {
    var rooms: [RoomOption]
    @Binding var selection: UUID?
    var accent: Color
    var onNew: () -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(rooms) { room in
                let on = room.id == selection
                Button {
                    selection = room.id
                } label: {
                    Text(room.name)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button(action: onNew) {
                Label("New Room", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .foregroundStyle(accent)
                    .overlay { Capsule().strokeBorder(accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
            }
            .buttonStyle(.plain)
        }
    }
}

/// A device's tile as it will look, for the editor and the icon picker.
struct DevicePreviewTile: View {
    var name: String
    var detail: String
    var look: DeviceLook
    var size: CGFloat

    var body: some View {
        let text = TileText(on: true, look: look)
        VStack(alignment: .leading) {
            DeviceIcon(symbol: look.symbol(true), on: true, look: look, size: size * 0.36)
            Spacer(minLength: 0)
            Text(name)
                .font(size > 140 ? Font.headline : Font.footnote.weight(.bold))
                .foregroundStyle(text.primary)
                .lineLimit(1)
            if size > 140 {
                Text("\(detail.isEmpty ? "" : "\(detail) · ")On")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(text.secondary)
                    .lineLimit(1)
            }
        }
        .padding(size > 140 ? 18 : 12)
        .frame(width: size, height: size, alignment: .leading)
        .tileSurface(on: true, look: look, cornerRadius: size * 0.19)
    }
}
