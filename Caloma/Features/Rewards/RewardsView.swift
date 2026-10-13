import SwiftData
import SwiftUI

/// The parent's view of rewards: what each kid has, the family goal, and the family store.
struct RewardsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]
    @Query(filter: #Predicate<Reward> { !$0.isArchived }, sort: \Reward.sortOrder) private var rewards: [Reward]

    @State private var kind: RewardKind?
    @State private var editing: Reward?
    @State private var confirmsFinish: Reward?

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    private var store: [Reward] { rewards.filter { !$0.isFamilyGoal } }
    private var goal: Reward? { rewards.first { $0.isFamilyGoal } }

    var body: some View {
        let family = family
        CalomaScreen(title: "Rewards") {
            if !family.kids.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(family.kids) { kid in
                        NavigationLink {
                            KidDetailView(kidID: kid.id)
                        } label: {
                            balanceTile(kid, family)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let goal {
                FamilyGoalCard(goal: goal, family: family)
                    .contextMenu {
                        Button("Edit Goal", systemImage: "pencil") { editing = goal }
                        Button("Mark Reached", systemImage: "flag.checkered") { confirmsFinish = goal }
                    }
                    .onTapGesture { editing = goal }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Family Store") {
                    Button("New Reward") { router.sheet = .newReward }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Chip(title: "All", color: accent, isOn: kind == nil, showsDot: false) { kind = nil }
                        ForEach(RewardKind.allCases) { option in
                            Chip(title: option.plural, color: Color(hex: option.colorHex), isOn: kind == option) {
                                kind = kind == option ? nil : option
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -16)

                let shown = store.filter { kind == nil || $0.kind == kind }
                if shown.isEmpty {
                    EmptyCard(symbol: "gift", title: "Nothing here yet", message: "Add rewards your kids can work toward.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(shown) { reward in
                            Button {
                                editing = reward
                            } label: {
                                RewardTile(reward: reward, redeemed: timesRedeemed(reward))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    router.sheet = .approvals
                } label: {
                    Label("Needs Your OK", systemImage: "checkmark.shield")
                }
                .badge(family.pendingRedemptionCount)
                Button {
                    router.sheet = .newReward
                } label: {
                    Label("New Reward", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { reward in
            RewardEditor(reward: reward)
        }
        .confirmationDialog("Mark \(confirmsFinish?.name ?? "the goal") reached?", isPresented: Binding(get: { confirmsFinish != nil }, set: { if !$0 { confirmsFinish = nil } }), titleVisibility: .visible) {
            Button("Mark Reached") {
                if let goal = confirmsFinish { Family.finishGoal(goal, in: context) }
            }
        } message: {
            Text("It leaves the store. Set up the next goal with New Reward › Make It a Family Goal.")
        }
    }

    private func balanceTile(_ kid: Member, _ family: FamilySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(kid.color.color).frame(width: 9, height: 9)
                Text(kid.name).font(.subheadline.weight(.semibold))
            }
            PointsLabel(points: family.balance(of: kid), font: .title2.bold())
            Text("+\(family.earnedThisWeek(by: kid).formatted()) this week")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private func timesRedeemed(_ reward: Reward) -> Int {
        redemptions.filter { $0.rewardID == reward.id && $0.status == .approved }.count
    }
}

/// A reward in the store: its icon, name, note, cost and kind.
struct RewardTile: View {
    var reward: Reward
    var redeemed: Int = 0

    var body: some View {
        let color = Color(hex: reward.kind.colorHex)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(symbol: reward.symbol, color: color, size: 42)
                Spacer()
                TagLabel(text: reward.kind.label, color: color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(reward.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(reward.note.isEmpty ? reward.limit.label : reward.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: 50, alignment: .top)
            HStack {
                PointsLabel(points: reward.cost, font: .subheadline.bold())
                Spacer()
                if redeemed > 0 {
                    Text("\(redeemed)× so far")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { RewardsView() }
        .previewEnvironment()
}
