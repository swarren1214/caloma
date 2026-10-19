import SwiftData
import SwiftUI

/// The Kid View button in the parent's toolbar. With more than one kid (or on iPad) it's a
/// menu: open it straight to one kid's chores, to "Who's doing chores?" so they pick, or, on
/// iPad, start the Family Board.
struct KidViewButton: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    /// The Family Board needs a parent PIN first, so there's always a way back out.
    @State private var settingPIN = false
    /// The Family Board without Caloma Plus or Hearth+.
    @State private var showsPaywall = false

    private var kids: [Member] { members.filter { $0.isKid && !$0.isArchived } }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            if kids.count > 1 || isPad {
                Menu {
                    if !kids.isEmpty {
                        Section("Open Kid View for") {
                            ForEach(kids) { kid in
                                Button(kid.name, menuIcon: "person.fill") { router.openKidView(for: kid.id) }
                            }
                        }
                    }
                    if kids.count > 1 {
                        Button("Let the Kids Pick", menuIcon: "person.3.fill") { router.openKidViewPicker() }
                    }
                    if isPad {
                        Section {
                            Button("Start Family Board", menuIcon: "rectangle.inset.filled.and.person.filled", action: startBoard)
                        }
                    }
                } label: {
                    Label("Kid View", systemImage: "figure.and.child.holdinghands")
                }
                // Menu icons take the tint; keep them the same color as their text, not the accent.
                .tint(.primary)
            } else {
                Button {
                    router.openKidView(for: kids.first?.id)
                } label: {
                    Label("Kid View", systemImage: "figure.and.child.holdinghands")
                }
            }
        }
        .sheet(isPresented: $settingPIN) {
            PINSetupSheet {
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    router.openKiosk()
                }
            }
            .tint(accent)
        }
        .hearthPaywall(isPresented: $showsPaywall, feature: CalomaPlus.familyBoard)
    }

    private func startBoard() {
        guard CalomaPlus.isUnlocked else {
            showsPaywall = true
            return
        }
        if ParentPIN.isSet {
            router.openKiosk()
        } else {
            settingPIN = true
        }
    }
}
