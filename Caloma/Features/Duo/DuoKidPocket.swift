import SwiftData
import SwiftUI

/// iPhone Duo, closed: "Kid View, pocket size". Hand the closed phone to a kid and the outer
/// display shows their ring and today's chores as big rows (64 pt, for small fingers). Switch
/// Person is the one toolbar action; it also holds Parent, which leaves Kid View with the same
/// check as the full Kid View. Checking a chore is the same `Family.markDone` the full Kid View
/// uses, so the ring fills everywhere else too.
struct DuoKidPocketView: View {
    var kid: Member
    var kids: [Member]
    var onPick: (Member) -> Void
    var onLeave: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]
    @Query(sort: \Member.sortOrder) private var members: [Member]

    @State private var photoFor: BoardItem?
    @State private var celebration = 0

    private var color: Color { kid.color.color }
    private var words: PointWords { PointWords.current() }

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    var body: some View {
        let family = family
        let items = family.items(for: kid)
        let mine = items.filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
        let done = mine.filter { $0.status.isDone }.count
        List {
            Section {
                ring(done: done, total: mine.count, family: family)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                if items.isEmpty {
                    Text("No jobs today! Go play.")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    ForEach(items) { item in
                        row(item, family: family)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(color.opacity(0.07).ignoresSafeArea())
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .refreshesFromICloud()
        .navigationTitle(kid.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let others = kids.filter { $0.id != kid.id }
                    if !others.isEmpty {
                        Section("Switch to") {
                            ForEach(others) { other in
                                Button(other.name, menuIcon: "person.fill") { onPick(other) }
                            }
                        }
                    }
                    Section {
                        Button("Parent", menuIcon: "lock.fill", action: onLeave)
                    }
                } label: {
                    Label("Switch Person", systemImage: "person.2.circle")
                }
                // Menu icons in the text color, not the kid's (AGENT.md).
                .tint(.primary)
            }
        }
        .sensoryFeedback(.success, trigger: celebration)
        .sheet(item: $photoFor) { item in
            CameraPicker { image in
                finish(item, photo: PhotoTools.jpeg(from: image))
            }
            .ignoresSafeArea()
        }
    }

    private func ring(done: Int, total: Int, family: FamilySnapshot) -> some View {
        HStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: total == 0 ? 0 : Double(done) / Double(total), color: color, lineWidth: 7)
                MemberAvatar(kid, size: 50)
            }
            .frame(width: 70, height: 70)
            VStack(alignment: .leading, spacing: 2) {
                Text(total == 0 ? "Nothing today" : "\(done) of \(total) done")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                PointsLabel(points: family.balance(of: kid), font: .system(size: 18, weight: .bold, design: .rounded), color: Brand.starBright)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: BoardItem, family: FamilySnapshot) -> some View {
        Button {
            tapped(item)
        } label: {
            HStack(spacing: 14) {
                IconTile(symbol: item.chore.symbol, color: color, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.chore.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .strikethrough(item.status == .approved)
                        .lineLimit(2)
                    if item.status == .pending {
                        Text("Waiting for OK")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.waiting)
                    } else if item.chore.requiresPhoto && item.status == .open {
                        Text("Take a photo")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                PointsLabel(points: item.points, font: .system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.secondary)
                ChoreCheck(status: item.status, color: color, size: 34)
            }
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.status != .open)
        .accessibilityLabel(item.status == .open ? "\(item.chore.title), \(words.count(item.points))" : "\(item.chore.title), done")
        .accessibilityHint(item.status == .open ? "Marks it done" : "")
    }

    private func tapped(_ item: BoardItem) {
        guard item.status == .open else { return }
        if item.chore.requiresPhoto {
            photoFor = item
        } else {
            finish(item, photo: nil)
        }
    }

    private func finish(_ item: BoardItem, photo: Data?) {
        withAnimation(.spring(duration: 0.45, bounce: 0.4)) {
            Family.markDone(item, by: kid.id, byParent: false, photo: photo, in: context)
            celebration += 1
        }
    }
}
