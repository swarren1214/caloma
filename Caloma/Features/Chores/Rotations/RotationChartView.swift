import SwiftData
import SwiftUI

/// Rotations › Chart: four weeks of who has what, for the fridge in your head, and how many
/// turns each person has had lately so the family can see it's fair.
struct RotationChartView: View {
    @Environment(\.accent) private var accent
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var groups: [ChoreGroup]
    @Query private var chores: [Chore]
    @AppStorage(SettingsKey.rotationMakeUp) private var makeUp = true

    private let weeks = 4
    /// How far back Fair Shares looks, in turns.
    private let lookBack = 12

    var body: some View {
        let summaries = Rotations.summaries(groups: groups, chores: chores).filter { $0.rule.mode != .everyone }
        let starts = weekStarts
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if summaries.isEmpty {
                    ContentUnavailableView("No Rotations", systemImage: "tablecells", description: Text("Make a chore group or turn on Take Turns for a chore."))
                } else {
                    chart(summaries, starts: starts)
                    fairShares(summaries)
                }
            }
            .padding(16)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Rotation Chart")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The start of this week and the next three.
    private var weekStarts: [Date] {
        let calendar = Calendar.current
        let first = RotationMath.weekStart(of: .now, weekday: 0, calendar: calendar)
        return (0..<weeks).compactMap { calendar.date(byAdding: .day, value: $0 * 7, to: first) }
    }

    // MARK: Chart

    private func chart(_ summaries: [RotationSummary], starts: [Date]) -> some View {
        let nameWidth: CGFloat = sizeClass == .compact ? 96 : 180
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: nameWidth, height: 1)
                ForEach(Array(starts.enumerated()), id: \.offset) { offset, start in
                    Text(offset == 0 ? "This Week" : start.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 8)
            ForEach(summaries) { summary in
                Divider()
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        RotationTile(summary: summary, size: 28)
                        Text(summary.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    .frame(width: nameWidth, alignment: .leading)
                    ForEach(Array(starts.enumerated()), id: \.offset) { offset, start in
                        cell(summary, weekStart: start)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(offset == 0 ? accent.opacity(0.06) : .clear)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder
    private func cell(_ summary: RotationSummary, weekStart: Date) -> some View {
        switch summary.rule.period {
        case .day:
            // Daily turns change too often for a weekly box: show who starts the week.
            VStack(spacing: 2) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Daily").font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Changes daily")
        default:
            // A weekly box shows who has it for most of the week (the middle day).
            let middle = Calendar.current.date(byAdding: .day, value: 3, to: weekStart) ?? weekStart
            let index = RotationMath.periodIndex(of: middle, rule: summary.rule)
            let ids: [UUID] = summary.rule.mode == .turns
                ? summary.holder(ofPeriod: index).map { [$0] } ?? []
                : Array(Set(summary.assignments(ofPeriod: index).flatMap { $0 }))
            let people = members.filter { ids.contains($0.id) }
            if people.isEmpty {
                Text("Paused").font(.caption2).foregroundStyle(.secondary)
            } else if people.count == 1, let person = people.first {
                VStack(spacing: 3) {
                    MemberAvatar(person, size: 28)
                    Text(person.name).font(.caption2).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            } else {
                MemberStack(members: people, size: 22)
            }
        }
    }

    // MARK: Fair shares

    private func fairShares(_ summaries: [RotationSummary]) -> some View {
        let turns = summaries.filter { $0.rule.mode == .turns }
        var counts: [UUID: Int] = [:]
        for summary in turns {
            let current = RotationMath.periodIndex(of: .now, rule: summary.rule)
            let from = Swift.max(0, current - lookBack + 1)
            for (id, count) in RotationMath.turnCounts(from: from, through: current, members: summary.members, adjustments: summary.rule.adjustments) {
                counts[id, default: 0] += count
            }
        }
        let people = members.filter { counts[$0.id] != nil }
        let most = Swift.max(counts.values.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Fair Shares")
                .font(.title3.weight(.bold))
            if people.isEmpty {
                Text("Fair Shares counts turns in rotations where people take turns.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(people) { person in
                let count = counts[person.id] ?? 0
                HStack(spacing: 12) {
                    MemberAvatar(person, size: 30)
                    Text(person.name)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 80, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(person.color.color)
                            .frame(width: Swift.max(8, proxy.size.width * CGFloat(count) / CGFloat(most)))
                    }
                    .frame(height: 12)
                    Text(count == 1 ? "1 turn" : "\(count) turns")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(person.name), \(count) turns")
            }
            Toggle("Make Up Skipped Turns", isOn: $makeUp)
                .padding(.top, 4)
            Text("Counts each person’s turns in the last \(lookBack) turns of every rotation since it started. "
                 + (makeUp ? "Skipped turns are made up, so the counts even out." : "Skipped turns are missed, not made up."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}
