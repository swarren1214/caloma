import SwiftData
import SwiftUI

/// Kid View: "Kitchen Week!" when it's this kid's turn with a chore group, with the days left
/// before it moves on.
struct KidTurnBanner: View {
    var kid: Member

    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var groups: [ChoreGroup]
    @Query private var chores: [Chore]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let mine = Rotations.summaries(groups: groups, chores: chores).filter { summary in
            summary.isGroup && summary.holder(ofPeriod: RotationMath.periodIndex(of: .now, rule: summary.rule)) == kid.id
        }
        if !mine.isEmpty {
            VStack(spacing: 12) {
                ForEach(mine) { summary in
                    banner(summary)
                }
            }
        }
    }

    private func banner(_ summary: RotationSummary) -> some View {
        let tint = summary.tint(accent: kid.color.color)
        let current = RotationMath.periodIndex(of: .now, rule: summary.rule)
        let next = summary.holder(ofPeriod: current + 1).flatMap { id in members.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: summary.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR TURN")
                        .font(.caption.weight(.bold))
                        .opacity(0.9)
                    Text("\(summary.name) \(summary.rule.period == .day ? "Day" : summary.rule.period == .month ? "Month" : "Week")!")
                        .font(.system(size: sizeClass == .compact ? 26 : 30, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            if summary.rule.period == .week || summary.rule.period == .twoWeeks {
                DaysLeft(summary: summary, index: current)
            }
            Text(next.map { next in
                next.id == kid.id
                    ? "You have it next time too. Keep it up!"
                    : RotationText.handOver(next: next.name, name: "the \(summary.name)", index: current, rule: summary.rule) + " Finish strong!"
            } ?? "Finish strong!")
                .font(.subheadline.weight(.semibold))
                .opacity(0.95)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The days of a weekly turn: gone, today, and still to come.
private struct DaysLeft: View {
    var summary: RotationSummary
    var index: Int

    var body: some View {
        let calendar = Calendar.current
        let start = RotationMath.start(ofPeriod: index, rule: summary.rule)
        let count = summary.rule.period == .twoWeeks ? 14 : 7
        let today = calendar.startOfDay(for: .now)
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let left = days.filter { $0 >= today }.count
        HStack(spacing: count == 14 ? 3 : 6) {
            ForEach(days, id: \.self) { day in
                let past = day < today
                let isToday = calendar.isDate(day, inSameDayAs: today)
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption.weight(.heavy))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .foregroundStyle(isToday ? Color.black.opacity(0.75) : .white.opacity(past ? 1 : 0.85))
                    .background(.white.opacity(isToday ? 1 : past ? 0.4 : 0.16), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(left == 1 ? "Last day" : "\(left) days left")
    }
}

/// Kid View: when this kid's next turns come around, for every rotation they're in.
struct KidComingUp: View {
    var kid: Member

    @Query private var groups: [ChoreGroup]
    @Query private var chores: [Chore]

    var body: some View {
        let upcoming = Rotations.summaries(groups: groups, chores: chores).compactMap { summary -> NextTurn? in
            let current = RotationMath.periodIndex(of: .now, rule: summary.rule)
            return summary.nextTurn(of: kid.id, after: current).map {
                NextTurn(summary: summary, index: $0, start: RotationMath.start(ofPeriod: $0, rule: summary.rule))
            }
        }
        .sorted { $0.start < $1.start }
        .prefix(4)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Coming Up for You")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                ForEach(Array(upcoming)) { turn in
                    let summary = turn.summary
                    let index = turn.index
                    HStack(spacing: 12) {
                        Image(systemName: summary.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(summary.tint(accent: kid.color.color), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(summary.name).font(.body.weight(.bold))
                            Text(when(summary, index: index))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private struct NextTurn: Identifiable {
        var summary: RotationSummary
        var index: Int
        var start: Date
        var id: UUID { summary.id }
    }

    private func when(_ summary: RotationSummary, index: Int) -> String {
        let start = RotationMath.start(ofPeriod: index, rule: summary.rule)
        let calendar = Calendar.current
        switch summary.rule.period {
        case .day:
            if calendar.isDateInTomorrow(start) { return "Your turn tomorrow" }
            return "Your turn " + start.formatted(.dateTime.weekday(.wide))
        case .week:
            return "Your week starts " + start.formatted(.dateTime.month(.abbreviated).day())
        case .twoWeeks:
            return "Your two weeks start " + start.formatted(.dateTime.month(.abbreviated).day())
        case .month:
            return "Your month is " + start.formatted(.dateTime.month(.wide))
        }
    }
}
