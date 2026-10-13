import SwiftData
import SwiftUI

/// One kid, for a parent: points, streak, today's chores, and every change to their points.
struct KidDetailView: View {
    var kidID: UUID

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query(sort: \PointEntry.date, order: .reverse) private var points: [PointEntry]
    @Query private var redemptions: [Redemption]

    @State private var adjusting = false
    @State private var editingMember = false

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    var body: some View {
        if let kid = members.first(where: { $0.id == kidID }) {
            content(kid, family)
        } else {
            ContentUnavailableView("Not in the family anymore", systemImage: "person.slash")
        }
    }

    private func content(_ kid: Member, _ family: FamilySnapshot) -> some View {
        let items = family.items(for: kid).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
        let history = points.filter { $0.memberID == kid.id }
        return CalomaScreen(title: kid.name, maxWidth: 680) {
            HStack(spacing: 16) {
                MemberAvatar(kid, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    PointsLabel(points: family.balance(of: kid), font: .title.bold())
                    let pending = family.pending(of: kid)
                    if pending > 0 {
                        Text("+\(pending.formatted()) waiting for your OK")
                            .font(.subheadline)
                            .foregroundStyle(Brand.waiting)
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                stat("\(family.streak(of: kid))", "Day streak", "flame.fill", .orange)
                stat("+\(family.earnedThisWeek(by: kid).formatted())", "This week", "calendar", kid.color.color)
            }

            Button {
                router.openKidView(for: kid.id)
            } label: {
                Label("Open Kid View for \(kid.name)", systemImage: "figure.and.child.holdinghands")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(kid.color.color)

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Today")
                if items.isEmpty {
                    Card { Text("Nothing on the board today.").foregroundStyle(.secondary) }
                } else {
                    CardList(items: items, inset: 56) { item in
                        ChoreRow(item: item, color: kid.color.color, onEdit: { _ in }) {
                            toggle(item, kid)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("History") {
                    Button("Adjust") { adjusting = true }
                }
                if history.isEmpty {
                    Card { Text("No \(PointWords.current().plural) yet.").foregroundStyle(.secondary) }
                } else {
                    CardList(items: Array(history.prefix(30)), inset: 16) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.note.isEmpty ? label(for: entry.kind) : entry.note)
                                    .lineLimit(1)
                                Text("\(label(for: entry.kind)) · \(entry.date.formatted(.relative(presentation: .named)))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.points > 0 ? "+\(entry.points.formatted())" : entry.points.formatted())
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(entry.points > 0 ? kid.color.color : Color.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 54)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editingMember = true }
            }
        }
        .sheet(isPresented: $adjusting) {
            AdjustPointsSheet(kid: kid)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $editingMember) {
            NavigationStack { MemberEditor(member: kid, role: .kid, showsCancel: true) }
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title3.bold()).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private func label(for kind: PointKind) -> String {
        switch kind {
        case .chore: "Chore"
        case .bonus: "Streak bonus"
        case .reward: "Reward"
        case .goal: "Family goal"
        case .cashOut: "Allowance"
        case .adjustment: "Adjusted"
        }
    }

    private func toggle(_ item: BoardItem, _ kid: Member) {
        withAnimation(.snappy) {
            switch item.status {
            case .open:
                Family.markDone(item, by: kid.id, byParent: true, in: context)
            case .pending:
                if let completion = completions.first(where: { $0.id == item.completionID }) {
                    Family.approve(completion, in: context)
                }
            case .approved:
                if let completion = completions.first(where: { $0.id == item.completionID }) {
                    Family.undo(completion, in: context)
                }
            }
        }
    }
}

/// Adding or taking away points by hand, with a reason.
private struct AdjustPointsSheet: View {
    var kid: Member

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var amount = 10
    @State private var adding = true
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Change", selection: $adding) {
                    Text("Add").tag(true)
                    Text("Take Away").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper(value: $amount, in: 1...1000, step: amount < 10 ? 1 : 5) {
                    PointsLabel(points: amount, font: .body)
                }
                TextField("Why (Helped Grandma, Lost tablet time)", text: $note)
            }
            .navigationTitle("Adjust \(kid.name)'s \(PointWords.current().title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) {
                        let reason = note.trimmingCharacters(in: .whitespaces)
                        Family.adjust(adding ? amount : -amount, for: kid.id, note: reason.isEmpty ? (adding ? "Bonus" : "Taken away") : reason, in: context)
                        dismiss()
                    }
                }
            }
        }
    }
}
