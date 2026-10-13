import SwiftData
import SwiftUI

/// Home: each kid's day at a glance, what needs a parent's OK, home care coming up, and the
/// family goal.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]
    @Query(filter: #Predicate<HomeTask> { !$0.isArchived }, sort: \HomeTask.nextDue) private var homeTasks: [HomeTask]
    @Query(filter: #Predicate<Reward> { $0.isFamilyGoal && !$0.isArchived }) private var goals: [Reward]

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    var body: some View {
        let family = family
        CalomaScreen(title: "Home") {
            kidsToday(family)
            if family.needsOKCount > 0 {
                needsOK(family)
            }
            homeCare
            if let goal = goals.first {
                FamilyGoalCard(goal: goal, family: family)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                KidViewButton()
                Button {
                    router.sheet = .family
                } label: {
                    Label("Family", systemImage: "person.2.fill")
                }
            }
        }
    }

    @ViewBuilder
    private func kidsToday(_ family: FamilySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Kids Today") {
                Button("All Chores") { router.tab = .chores }
            }
            if family.kids.isEmpty {
                EmptyCard(symbol: "person.badge.plus", title: "No kids yet", message: "Add them in Family to start giving out chores.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                    ForEach(family.kids) { kid in
                        NavigationLink {
                            KidDetailView(kidID: kid.id)
                        } label: {
                            KidTodayCard(kid: kid, family: family)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func needsOK(_ family: FamilySnapshot) -> some View {
        Button {
            router.sheet = .approvals
        } label: {
            HStack(spacing: 14) {
                IconTile(symbol: "checkmark.shield", color: accent, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs Your OK")
                        .font(.headline)
                    Text(okSummary(family))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(family.needsOKCount)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .padding(.horizontal, 4)
                    .background(accent, in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }

    private func okSummary(_ family: FamilySnapshot) -> String {
        var parts: [String] = []
        let chores = family.pendingCompletionCount
        let rewards = family.pendingRedemptionCount
        if chores > 0 { parts.append(chores == 1 ? "1 finished chore" : "\(chores) finished chores") }
        if rewards > 0 { parts.append(rewards == 1 ? "1 reward request" : "\(rewards) reward requests") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var homeCare: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Home Care") {
                Button("See All") { router.tab = .homeCare }
            }
            if homeTasks.isEmpty {
                EmptyCard(symbol: "wrench.and.screwdriver", title: "Nothing to look after yet", message: "Add filters, detectors and other things that need doing now and then.")
            } else {
                CardList(items: Array(homeTasks.prefix(3))) { task in
                    NavigationLink {
                        HomeTaskDetailView(task: task)
                    } label: {
                        HomeTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A kid's circle with today's ring, their name, how many are done, and their points.
struct KidTodayCard: View {
    var kid: Member
    var family: FamilySnapshot

    var body: some View {
        let progress = family.progress(for: kid)
        VStack(spacing: 8) {
            ZStack {
                ProgressRing(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), color: kid.color.color, lineWidth: 5)
                MemberAvatar(kid, size: 46)
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 1) {
                Text(kid.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(progress.total == 0 ? "Nothing today" : "\(progress.done) of \(progress.total) done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            PointsLabel(points: family.balance(of: kid), font: .footnote.weight(.semibold))
                .padding(.horizontal, 9)
                .frame(minHeight: 24)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

/// The family goal: everyone's points pooled toward one reward, a colored share for each kid.
struct FamilyGoalCard: View {
    var goal: Reward
    var family: FamilySnapshot
    @Environment(\.accent) private var accent

    var body: some View {
        let progress = ChoreMath.goalProgress(goal.id, entries: family.points)
        let shares = ChoreMath.goalShares(goal.id, entries: family.points)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("FAMILY GOAL", systemImage: "flag.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                if progress >= goal.cost {
                    TagLabel(text: "Reached!", color: accent)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(goal.name).font(.title3.bold())
                Spacer()
                Text("\(progress.formatted()) / \(goal.cost.formatted())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(family.kids) { kid in
                        let share = Double(shares[kid.id] ?? 0) / Double(max(goal.cost, 1))
                        Rectangle()
                            .fill(kid.color.color)
                            .frame(width: proxy.size.width * min(max(share, 0), 1))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill))
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                ForEach(family.kids) { kid in
                    HStack(spacing: 5) {
                        Circle().fill(kid.color.color).frame(width: 8, height: 8)
                        Text("\(kid.name) \((shares[kid.id] ?? 0).formatted())")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Text(progress >= goal.cost ? "Time to plan it!" : "Everyone chips in. \(max(goal.cost - progress, 0).formatted()) to go.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { HomeView() }
        .previewEnvironment()
}
