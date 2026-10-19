import SwiftData
import SwiftUI

/// Long-press a chore row for a Liquid Glass menu: complete it, edit it, or delete it.
///
/// This is the system context menu on purpose. It brings the Apple feel for free: the row
/// eases down in scale while the finger is held, lifts out on a glass platter with a haptic
/// tap as the menu opens, and the menu's icons always take the same color as their titles
/// (label color, or red for Delete), in light and dark mode alike.
struct ChoreActionsMenu<Complete: View>: ViewModifier {
    var title: String
    var choreID: UUID
    /// Nil hides Edit, for screens that can't open the editor.
    var onEdit: ((UUID) -> Void)?
    @ViewBuilder var complete: () -> Complete

    @Environment(\.modelContext) private var context
    @State private var confirmsDelete = false

    func body(content: Content) -> some View {
        content
            // The lifted preview is the row on its own card, so it reads cleanly off the list.
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 22))
            .contextMenu {
                Section {
                    complete()
                    if let onEdit {
                        Button("Edit Chore", menuIcon: "pencil") { onEdit(choreID) }
                    }
                }
                Section {
                    Button("Delete Chore", menuIcon: "trash", role: .destructive) {
                        confirmsDelete = true
                    }
                }
            }
            .alert("Delete \(title)?", isPresented: $confirmsDelete) {
                Button("Delete Chore", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It comes off everyone's board. Points already earned stay.")
            }
    }

    /// Same as Delete in the chore editor: archive it so earned points keep their history.
    private func delete() {
        guard let chore = Family.chore(choreID, in: context) else { return }
        withAnimation(.snappy) {
            chore.isArchived = true
            Rotations.choreLeft(chore, in: context)
            Persistence.save(context)
        }
    }
}

extension View {
    /// Adds the long-press complete / edit / delete menu to a chore row.
    func choreActions<Complete: View>(
        title: String,
        choreID: UUID,
        onEdit: ((UUID) -> Void)?,
        @ViewBuilder complete: @escaping () -> Complete
    ) -> some View {
        modifier(ChoreActionsMenu(title: title, choreID: choreID, onEdit: onEdit, complete: complete))
    }
}
