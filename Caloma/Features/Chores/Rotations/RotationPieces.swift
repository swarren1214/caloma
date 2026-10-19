import SwiftUI

// Small pieces the rotation screens share: how a turn is named, and who has it.

enum RotationText {
    /// "This Week", "Next Week", "Oct 25 – 31", "Today", "Tomorrow", "Wed, Oct 21", "November".
    static func turnName(_ index: Int, current: Int, rule: RotationRule, calendar: Calendar = .current) -> String {
        let start = RotationMath.start(ofPeriod: index, rule: rule, calendar: calendar)
        let end = RotationMath.end(ofPeriod: index, rule: rule, calendar: calendar)
        switch rule.period {
        case .day:
            if index == current { return "Today" }
            if index == current + 1 { return "Tomorrow" }
            return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week, .twoWeeks:
            if index == current { return rule.period == .week ? "This Week" : "These 2 Weeks" }
            if index == current + 1 { return rule.period == .week ? "Next Week" : "Next 2 Weeks" }
            return range(start, end, calendar: calendar)
        case .month:
            if index == current { return "This Month" }
            if index == current + 1 { return "Next Month" }
            return start.formatted(.dateTime.month(.wide))
        }
    }

    /// "Oct 25 – 31" or "Oct 25 – Nov 7".
    static func range(_ start: Date, _ end: Date, calendar: Calendar = .current) -> String {
        let first = start.formatted(.dateTime.month(.abbreviated).day())
        let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
        let last = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(first) – \(last)"
    }

    /// "Weekly, switching Sundays", "Every 2 weeks, switching Wednesdays", "Daily", "Monthly".
    static func schedule(_ rule: RotationRule, calendar: Calendar = .current) -> String {
        guard rule.period.usesWeekday else { return rule.period.title }
        let weekday = rule.weekday == 0 ? calendar.firstWeekday : rule.weekday
        let day = calendar.weekdaySymbols[weekday - 1]
        return (rule.period == .week ? "Weekly" : "Every 2 weeks") + ", switching \(day)s"
    }

    /// "Max's week", "Ella's day", "Nobody's turn (paused)".
    static func holderTitle(_ name: String?, rule: RotationRule) -> String {
        guard let name else { return "Paused" }
        return "\(name)’s \(rule.period.noun)"
    }

    /// When the current turn hands over: "Sunday, the Kitchen goes to Ella."
    static func handOver(next: String?, name: String, index: Int, rule: RotationRule, calendar: Calendar = .current) -> String {
        let start = RotationMath.start(ofPeriod: index + 1, rule: rule, calendar: calendar)
        let when: String
        if calendar.isDateInTomorrow(start) {
            when = "Tomorrow"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: start).day, days < 7 {
            when = start.formatted(.dateTime.weekday(.wide))
        } else {
            when = start.formatted(.dateTime.month(.abbreviated).day())
        }
        guard let next else { return "\(when), it’s paused." }
        return "\(when), \(name) goes to \(next)."
    }
}

/// A row of overlapping faces for the people in a rotation.
struct MemberStack: View {
    var members: [Member]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(members) { member in
                MemberAvatar(member, size: size)
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(members.map(\.name).formatted(.list(type: .and)))
    }
}

/// The icon tile for a rotation, in its group's color (or the accent for a single chore).
struct RotationTile: View {
    var summary: RotationSummary
    var size: CGFloat = 40
    @Environment(\.accent) private var accent

    var body: some View {
        IconTile(symbol: summary.symbol, color: summary.tint(accent: accent), size: size)
    }
}

/// One rotation in a list: icon, name, whose turn it is, and the people in it.
struct RotationRow: View {
    var summary: RotationSummary
    var members: [Member]

    var body: some View {
        let current = RotationMath.periodIndex(of: .now, rule: summary.rule)
        let people = summary.members.compactMap { id in members.first { $0.id == id } }
        HStack(spacing: 12) {
            RotationTile(summary: summary)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail(current: current, people: people))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            MemberStack(members: people, size: 24)
        }
        .padding(.vertical, 2)
    }

    private func detail(current: Int, people: [Member]) -> String {
        let count = summary.choreTitles.count
        let chores = summary.isGroup ? (count == 1 ? "1 chore" : "\(count) chores") : nil
        let turn: String
        switch summary.rule.mode {
        case .turns:
            let holder = summary.holder(ofPeriod: current).flatMap { id in people.first { $0.id == id }?.name }
            turn = RotationText.holderTitle(holder, rule: summary.rule)
        case .split:
            turn = "Split up, " + (summary.rule.period == .twoWeeks ? "every 2 weeks" : summary.rule.period.title.lowercased())
        case .everyone:
            turn = "Everyone does it"
        }
        return [turn, chores].compactMap { $0 }.joined(separator: " · ")
    }
}
