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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                    ForEach(KidColor.swatches) { option in
                        Button {
                            color = option
                        } label: {
                            swatch(option.color, isSelected: option == color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(option == color ? .isSelected : [])
                    }
                    // Any other color, from the system color picker.
                    ColorPicker("Custom color", selection: Binding(
                        get: { color.color },
                        set: { color = KidColor(hex: $0.hexValue) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 44)
                    .overlay {
                        if color.isCustom {
                            Circle()
                                .strokeBorder(color.color, lineWidth: 3)
                                .frame(width: 44, height: 44)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Color")
            } footer: {
                Text(role == .kid ? "Their avatar, their column on the chore board and all of Kid View." : "Their avatar around the app.")
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
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark", role: .confirm) { save() }
                    .disabled(!isValid)
            }
        }
        .confirmationDialog("Remove \(name)?", isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                member?.isArchived = true
                Persistence.save(context)
                dismiss()
            }
        }
        .onAppear(perform: load)
    }

    private func swatch(_ fill: Color, isSelected: Bool) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 36, height: 36)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let member {
            name = member.name
            color = member.color
            photo = member.photoData
        } else {
            color = role == .kid ? KidColor.next(after: members.filter { $0.isKid && !$0.isArchived }.map(\.color)) : .gray
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
