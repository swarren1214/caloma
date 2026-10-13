import SwiftData
import SwiftUI

/// The Kid View button in the parent's toolbar. With more than one kid it's a menu: open it
/// straight to one kid's chores, or to "Who's doing chores?" so they pick.
struct KidViewButton: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \Member.sortOrder) private var members: [Member]

    private var kids: [Member] { members.filter { $0.isKid && !$0.isArchived } }

    var body: some View {
        if kids.count > 1 {
            Menu {
                Section("Open Kid View for") {
                    ForEach(kids) { kid in
                        Button(kid.name, systemImage: "person.fill") { router.openKidView(for: kid.id) }
                    }
                }
                Button("Let the Kids Pick", systemImage: "person.3.fill") { router.openKidViewPicker() }
            } label: {
                Label("Kid View", systemImage: "figure.and.child.holdinghands")
            }
        } else {
            Button {
                router.openKidView(for: kids.first?.id)
            } label: {
                Label("Kid View", systemImage: "figure.and.child.holdinghands")
            }
        }
    }
}
