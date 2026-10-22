import SwiftData
import SwiftUI

/// iPhone Duo, partly folded and held like a book: "Chores beside rewards". The chosen kid's
/// chores for today on the left page, the reward store on the right, so their points and what
/// they buy are on the same spread. A parent's check approves straight away, so the points on
/// both pages move together. Rewards out of reach say how many points to go.
struct DuoChoresBesideRewards: View {
    var family: FamilySnapshot
    var store: [Reward]
    var completions: [ChoreCompletion]
    /// Which kid the spread shows; kept by the Rewards screen, so it survives folding.
    @Binding var kidID: UUID?
    var onEditReward: (Reward) -> Void

    @Environment(\.modelContext) private var context

    private var kid: Member? {
        family.kids.first { $0.id == kidID } ?? family.kids.first
    }

    var body: some View {
        HearthFoldSplit {
            choresPage
        } secondary: {
            storePage
        }
        .colorHeader("Rewards")
    }

    // MARK: Left page

    private var choresPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderTitle("Chores", subtitle: kid.map { "\($0.name)'s day" })
                if family.kids.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(family.kids) { other in
                                Chip(title: other.name, color: other.color.color, isOn: other.id == kid?.id) {
                                    withAnimation(.snappy) { kidID = other.id }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -16)
                }
                if let kid {
                    let items = family.items(for: kid).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
                    // The same figure as the store's page, so a check moves both.
                    HStack(alignment: .firstTextBaseline) {
                        Text("Today")
                            .font(.title3.bold())
                        Spacer()
                        PointsLabel(points: family.spendable(of: kid), font: .title3.bold())
                    }
                    .padding(.horizontal, 4)
                    if items.isEmpty {
                        Card { Text("Nothing today.").foregroundStyle(.secondary) }
                    } else {
                        CardList(items: items, inset: 56) { item in
                            ChoreRow(item: item, color: kid.color.color, onEdit: nil) {
                                withAnimation(.snappy) {
                                    ParentChoreTap.toggle(item, for: kid.id, completions: completions, in: context)
                                }
                            }
                        }
                    }
                } else {
                    EmptyCard(symbol: "person.badge.plus", title: "No kids yet", message: "Add them in Household to start giving out chores.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .refreshesFromICloud()
    }

    // MARK: Right page

    private var storePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let kid {
                    let spendable = family.spendable(of: kid)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Store")
                            .font(.title2.bold())
                        Spacer()
                        PointsLabel(points: spendable, font: .title2.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(kid.name) can spend \(PointWords.current().count(spendable))")
                    let shown = store.filter { $0.isAvailable(to: kid.id) }
                    if shown.isEmpty {
                        EmptyCard(symbol: "gift", title: "Nothing in the store", message: "Add rewards \(kid.name) can work toward.")
                    } else {
                        DuoAdaptiveGrid(minimum: 150, spacing: 10) {
                            ForEach(shown) { reward in
                                Button {
                                    onEditReward(reward)
                                } label: {
                                    rewardTile(reward, kid: kid, spendable: spendable)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshesFromICloud()
    }

    private func rewardTile(_ reward: Reward, kid: Member, spendable: Int) -> some View {
        let check = RewardMath.check(cost: reward.cost, limit: reward.limit, eligible: reward.isAvailable(to: kid.id), spendable: spendable, memberID: kid.id, rewardID: reward.id, redemptions: family.redemptions)
        return RewardTile(reward: reward)
            .overlay(alignment: .bottomTrailing) {
                status(check)
                    .padding(14)
            }
            .opacity(check == .ok ? 1 : 0.85)
    }

    @ViewBuilder
    private func status(_ check: RewardCheck) -> some View {
        let words = PointWords.current()
        switch check {
        case .ok:
            TagLabel(text: "Can get it", color: .green)
        case .needMore(let more):
            TagLabel(text: "\(words.count(more)) to go", color: .secondary)
        case .limitReached:
            TagLabel(text: "Used up for now", color: .secondary)
        case .notForThisKid:
            EmptyView()
        }
    }
}
