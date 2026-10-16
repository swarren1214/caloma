import SwiftData
import SwiftUI

/// Adding or editing a parent or kid: name, photo (cropped to the circle) and their color,
/// a preset or any custom color.
struct MemberEditor: View {
    var member: Member?
    var role: MemberRole
    var showsCancel = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""

    @State private var name = ""
    @State private var color: KidColor = .blue
    /// Their color when the editor opened, kept as it was unless someone picks another.
    @State private var loadedColor: KidColor = .blue
    @State private var pickingColor = false
    @State private var photo: Data?
    @State private var loaded = false
    @State private var confirmsRemove = false

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isMe: Bool { member?.id.uuidString == currentMember }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotoPickerAvatar(name: name, color: color.color, photo: $photo, size: 96)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                if photo != nil {
                    Button("Remove Photo", role: .destructive) { photo = nil }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .font(.title3)
            }

            Section {
                Button { pickingColor = true } label: {
                    HearthColorLabel(initial: name, color: colorChoice.wrappedValue)
                }
                .hearthColorPicker(
                    isPresented: $pickingColor, title: name,
                    caption: role == .kid ? "Kid" : "Parent", color: colorChoice
                )
            } footer: {
                Text(role == .kid ? "Their avatar, their column on the chore board, the calendar and all of Kid View." : "Their avatar, their chores and their events on the calendar.")
            }

            if member != nil && !isMe {
                Section {
                    Button(role: .destructive) {
                        confirmsRemove = true
                    } label: {
                        Label("Remove from Family", systemImage: "trash")
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
                    Text(role == .kid ? "Their chores come off the board. Their history stays." : "")
                }
            }
        }
        .navigationTitle(member == nil ? (role == .kid ? "New Kid" : "New Parent") : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if member == nil || showsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                SheetDoneButton("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .alert("Remove \(name)?", isPresented: $confirmsRemove) {
            Button("Remove", role: .destructive) {
                member?.isArchived = true
                Persistence.save(context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: load)
    }

    /// Their color in the Hearth picker. Caloma's old presets ("blue", "gray"…) show as the
    /// nearest palette color, but stay as they are unless someone picks another; a picked color
    /// is saved as "#RRGGBB", which every app reading `KidColor.hex` already handles.
    private var colorChoice: Binding<HearthColorChoice> {
        Binding(
            get: { Self.choice(for: color) },
            set: { newValue in
                if newValue == Self.choice(for: loadedColor) {
                    color = loadedColor
                } else if newValue != Self.choice(for: color) {
                    color = KidColor(hex: newValue.hex)
                }
            }
        )
    }

    private static func choice(for color: KidColor) -> HearthColorChoice {
        color.isCustom ? HearthColorChoice(hex: color.hex) : .palette(HearthPalette.nearest(to: color.hex).id)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let member {
            name = member.name
            color = member.color
            loadedColor = member.color
            photo = member.photoData
        } else {
            color = KidColor.next(for: role, after: members.filter { !$0.isArchived }.map(\.color))
            loadedColor = color
        }
    }

    private func save() {
        let target: Member
        if let member {
            target = member
        } else {
            let order = (members.map(\.sortOrder).max() ?? 0) + 1
            target = Member(name: name, role: role, color: color, sortOrder: order)
            context.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.color = color
        target.photoData = photo
        Persistence.save(context)
        dismiss()
    }
}
