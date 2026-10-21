import SwiftData
import SwiftUI

/// Caloma's own section on a household person's page (`HearthPersonView`, through
/// `\.hearthPersonExtras`): their role here and, for a kid, their points, chores and Kid View.
/// Names, photos and colors are the household's; this is only what Caloma keeps on `Member`.
struct CalomaPersonExtras: View {
    var person: HearthMember

    private var router: AppRouter { .shared }
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var points: [PointEntry]
    @Query(filter: #Predicate<Chore> { !$0.isArchived }) private var chores: [Chore]

    /// Caloma's member for this person, through the household's link.
    private var member: Member? {
        let ids = Set(members.map(\.id.uuidString))
        guard let id = HearthHouseholdStore.shared.localID(of: person, app: .caloma, among: ids) else { return nil }
        return members.first { $0.id.uuidString == id }
    }

    var body: some View {
        if let member {
            Section {
                LabeledContent("Role", value: member.role.label)
                if member.isKid {
                    LabeledContent {
                        PointsLabel(points: ChoreMath.balance(of: member.id, entries: points.map(\.record)))
                    } label: {
                        Text(PointWords.current().title)
                    }
                    LabeledContent("Chores", value: "\(chores.filter { $0.assigneeIDs.contains(member.id) }.count)")
                    NavigationLink {
                        KidDetailView(kidID: member.id)
                    } label: {
                        Label("Today, History and \(PointWords.current().title)", systemImage: "checklist")
                            // The row's icon in its text color, not the app's.
                            .tint(.primary)
                    }
                    Button {
                        openKidView(member.id)
                    } label: {
                        Label("Open Kid View for \(member.name)", systemImage: "figure.and.child.holdinghands")
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Caloma")
            } footer: {
                if member.isKid {
                    Text("Kid View shows just \(member.name)'s day, with big buttons, on this device.")
                }
            }
        }
    }

    /// Kid View covers the whole app, so Family closes first when it's open.
    private func openKidView(_ id: UUID) {
        guard router.sheet != nil else {
            router.openKidView(for: id)
            return
        }
        router.sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            router.openKidView(for: id)
        }
    }
}
