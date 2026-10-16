import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The iPhone's widgets (Home Screen, Lock Screen and, on iOS 26, the CarPlay dashboard) and the
// "You're driving" Live Activity. Widgets read the `WatchSnapshot` the app saves to the shared
// app group whenever the family changes.

@main
struct CalomaWidgets: WidgetBundle {
    var body: some Widget {
        ComingUpWidget()
        KidsTodayWidget()
        HomeCareWidget()
        DrivingActivityWidget()
    }
}

// MARK: - Timeline

struct FamilyEntry: TimelineEntry {
    var date: Date
    var snapshot: WatchSnapshot
    var relevance: TimelineEntryRelevance?
}

/// An entry now, at each event's start and end, an hour before each start, and at midnight,
/// so the widgets move on with the clock. The app reloads them whenever the family changes.
struct FamilyProvider: TimelineProvider {
    enum Kind { case comingUp, kids, homeCare }
    var kind: Kind

    func placeholder(in context: Context) -> FamilyEntry {
        FamilyEntry(date: .now, snapshot: .widgetSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (FamilyEntry) -> Void) {
        completion(FamilyEntry(date: .now, snapshot: context.isPreview ? .widgetSample : (WatchSnapshot.load() ?? .widgetSample)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FamilyEntry>) -> Void) {
        let snapshot = WatchSnapshot.load() ?? WatchSnapshot()
        let now = Date.now
        let horizon = now.addingTimeInterval(12 * 3600)
        var dates: Set<Date> = [now]
        for event in snapshot.events where !event.isAllDay {
            for date in [event.start, event.end, event.start.addingTimeInterval(-3600)] where date > now && date < horizon {
                dates.insert(date)
            }
        }
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        if midnight < horizon { dates.insert(midnight) }
        let entries = dates.sorted().map { FamilyEntry(date: $0, snapshot: snapshot, relevance: relevance(of: snapshot, at: $0)) }
        completion(Timeline(entries: entries, policy: .after(min(horizon, now.addingTimeInterval(3600)))))
    }

    private func relevance(of snapshot: WatchSnapshot, at date: Date) -> TimelineEntryRelevance {
        switch kind {
        case .comingUp:
            guard let next = snapshot.upcoming(now: date).first(where: { !$0.isAllDay }) else { return .init(score: 0) }
            let minutes = next.start.timeIntervalSince(date) / 60
            if minutes <= 60 && minutes > -15 { return .init(score: next.youDrive ? 100 : 70, duration: next.end.timeIntervalSince(date)) }
            return .init(score: 10)
        case .kids:
            return .init(score: snapshot.needsOKCount > 0 ? 80 : 5)
        case .homeCare:
            return .init(score: snapshot.homeCare.contains { $0.isLate(now: date) } ? 40 : 2)
        }
    }
}

/// Small caps over each widget, with Caloma's mark.
private struct WidgetHeader: View {
    var title: String
    var color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "house.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(color, in: .rect(cornerRadius: 4))
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

// MARK: - Coming Up

struct ComingUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "comingUp", provider: FamilyProvider(kind: .comingUp)) { entry in
            ComingUpView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "caloma://calendar"))
        }
        .configurationDisplayName("Coming Up")
        .description("The family's next events, who's going and who's driving.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct ComingUpView: View {
    var entry: FamilyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snapshot = entry.snapshot
        let events = snapshot.upcoming(now: entry.date)
        switch family {
        case .accessoryInline:
            Text(events.first.map { "\($0.title) \($0.timeLabel(now: entry.date))" } ?? "Nothing coming up")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let next = events.first {
                    Text(next.title).font(.headline).lineLimit(1)
                    Text(next.detail).font(.caption).lineLimit(2)
                } else {
                    Text("Nothing coming up").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            let dinner = snapshot.dinner(on: entry.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WidgetHeader(title: "Coming up", color: Color(rgb: snapshot.accent))
                        .layoutPriority(1)
                    // Medium: tonight's dinner fits beside the header.
                    if family == .systemMedium, let dinner {
                        Spacer(minLength: 4)
                        DinnerLine(dinner: dinner)
                    }
                }
                if events.isEmpty {
                    Text("Nothing planned")
                        .font(.headline)
                    Text("A free couple of days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events.prefix(family == .systemSmall ? 2 : 3)) { event in
                        EventLine(event: event, now: entry.date)
                    }
                }
                Spacer(minLength: 0)
                // Small: only when there's room under a single event.
                if family == .systemSmall, events.count < 2, let dinner {
                    DinnerLine(dinner: dinner)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EventLine: View {
    var event: WatchSnapshot.Event
    var now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(rgb: event.color))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(event.title) · \(event.who)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(event.youDrive ? "\(event.timeLabel(now: now)) · You're driving" : (event.driver.map { "\(event.timeLabel(now: now)) · \($0) drives" } ?? event.timeLabel(now: now)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// fork.knife + "Tacos": tonight's dinner from BigTable.
private struct DinnerLine: View {
    var dinner: WatchSnapshot.Dinner

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: dinner.symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color(rgb: WatchSnapshot.Dinner.color))
            Text(dinner.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dinner: \(dinner.title)")
    }
}

// MARK: - Kids Today

struct KidsTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "kidsToday", provider: FamilyProvider(kind: .kids)) { entry in
            KidsTodayView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: entry.snapshot.needsOKCount > 0 ? "caloma://approvals" : "caloma://chores"))
        }
        .configurationDisplayName("Kids Today")
        .description("Each kid's jobs for today, and what needs your OK.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct KidsTodayView: View {
    var entry: FamilyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Kids today", color: Color(rgb: snapshot.accent))
            HStack(spacing: family == .systemSmall ? 8 : 16) {
                ForEach(snapshot.kids.prefix(family == .systemSmall ? 3 : 5)) { kid in
                    VStack(spacing: 3) {
                        ZStack {
                            Circle().stroke(Color(rgb: kid.color).opacity(0.25), lineWidth: 5)
                            Circle()
                                .trim(from: 0, to: kid.total == 0 ? 1 : Double(kid.done) / Double(kid.total))
                                .stroke(Color(rgb: kid.color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 34, height: 34)
                        Text(kid.name)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        if family != .systemSmall {
                            Text(snapshot.points(kid.balance))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(kid.name), \(kid.done) of \(kid.total) jobs done")
                }
            }
            Spacer(minLength: 0)
            if snapshot.needsOKCount > 0 {
                Label("\(snapshot.needsOKCount) need\(snapshot.needsOKCount == 1 ? "s" : "") your OK", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text("Nothing needs your OK")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Home Care

struct HomeCareWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "homeCare", provider: FamilyProvider(kind: .homeCare)) { entry in
            HomeCareWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "caloma://homecare"))
        }
        .configurationDisplayName("Home Care")
        .description("The next home care job, whether it's late, and what to buy.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct HomeCareWidgetView: View {
    var entry: FamilyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let next = entry.snapshot.homeCare.first
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Text(next?.name ?? "Home care all done").font(.headline).lineLimit(1)
                if let next { Text(next.dueLabel(now: entry.date)).font(.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: "Home care", color: Color(rgb: entry.snapshot.accent))
                if let next {
                    Text(next.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(next.dueLabel(now: entry.date))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(next.isLate(now: entry.date) ? .red : .secondary)
                    if let details = next.details {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text("All caught up")
                        .font(.headline)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - You're driving (Live Activity)

struct DrivingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DrivingAttributes.self) { context in
            DrivingView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let color = Color(rgb: context.attributes.color)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Driving", systemImage: "car.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(color)
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.who)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.start, style: .time)
                            .font(.headline)
                        Text(context.attributes.start, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        PackedLine(state: context.state)
                        Spacer()
                        DirectionsButton(attributes: context.attributes)
                    }
                }
            } compactLeading: {
                Image(systemName: "car.fill")
                    .foregroundStyle(color)
            } compactTrailing: {
                Text(context.attributes.start, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
                    .foregroundStyle(color)
            } minimal: {
                Image(systemName: "car.fill")
                    .foregroundStyle(color)
            }
            .keylineTint(color)
        }
        // The small layout is what CarPlay and Apple Watch show.
        .supplementalActivityFamilies([.small, .medium])
    }
}

/// The Lock Screen and CarPlay layout.
private struct DrivingView: View {
    var attributes: DrivingAttributes
    var state: DrivingAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        let color = Color(rgb: attributes.color)
        if family == .small {
            // CarPlay and Apple Watch: the essentials, big enough to read at a glance. What's
            // not packed gets its own line, since it's the thing to turn around for.
            VStack(alignment: .leading, spacing: 3) {
                Label("YOU'RE DRIVING", systemImage: "car.fill")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(color)
                Text("\(attributes.title) · \(attributes.who)")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(attributes.start, style: .time)
                    Text("·")
                    Text(attributes.start, style: .relative)
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                if let missing = state.missing.first {
                    Label(state.missing.count == 1 ? "\(missing.name) · not packed" : "\(state.missing.count) things not packed", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if !state.bring.isEmpty {
                    Label("All packed", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                } else if let then = state.then {
                    ThenLine(then: then)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A tap on the card opens directions when there's somewhere to go.
            .widgetURL(attributes.directionsURL)
        } else {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("YOU'RE DRIVING", systemImage: "car.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(color)
                        Spacer()
                        Text(attributes.start, style: .relative)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.trailing)
                    }
                    Text("\(attributes.title) · \(attributes.who) · \(attributes.start.formatted(date: .omitted, time: .shortened))")
                        .font(.headline)
                        .lineLimit(1)
                    if !state.bring.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(state.bring.prefix(4)) { item in
                                Label(item.name, systemImage: item.packed ? "checkmark.circle.fill" : "circle")
                                    .font(.caption)
                                    .foregroundStyle(item.packed ? Color.green : Color.orange)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if let then = state.then {
                        ThenLine(then: then)
                    }
                    if !attributes.location.isEmpty {
                        HStack {
                            Text(attributes.location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            DirectionsButton(attributes: attributes)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

/// "Then Soccer · Ella · 4:30 · Dad drives": the next stop of the day.
private struct ThenLine: View {
    var then: DrivingAttributes.ContentState.Then

    var body: some View {
        Text("Then \(then.title) · \(then.who) · \(then.detail)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// "2 of 3 packed · Water bottle", or "All packed".
private struct PackedLine: View {
    var state: DrivingAttributes.ContentState

    var body: some View {
        if state.bring.isEmpty {
            EmptyView()
        } else if state.missing.isEmpty {
            Label("All packed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Label("\(state.packedCount) of \(state.bring.count) packed · \(state.missing.map(\.name).formatted(.list(type: .and)))", systemImage: "bag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }
}

private struct DirectionsButton: View {
    var attributes: DrivingAttributes

    var body: some View {
        if let url = attributes.directionsURL {
            Link(destination: url) {
                Label("Directions", systemImage: "location.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Sample

extension WatchSnapshot {
    /// For the widget gallery.
    static var widgetSample: WatchSnapshot {
        let now = Date.now
        var snapshot = WatchSnapshot(pointWord: "stars")
        snapshot.events = [
            .init(id: "1", title: "Piano", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(5400), isAllDay: false, who: "Max", color: 0x0A84FF, location: "Harmony Music Studio", driver: "Dad", youDrive: true, bring: ["Piano books"]),
            .init(id: "2", title: "Soccer", start: now.addingTimeInterval(5400), end: now.addingTimeInterval(9000), isAllDay: false, who: "Ella", color: 0xAF52DE, location: "", driver: "Mom", youDrive: false, bring: []),
        ]
        snapshot.kids = [
            .init(id: UUID(), name: "Ella", color: 0xAF52DE, done: 3, total: 4, balance: 120),
            .init(id: UUID(), name: "Max", color: 0x0A84FF, done: 3, total: 5, balance: 185),
            .init(id: UUID(), name: "June", color: 0xFF9F0A, done: 3, total: 3, balance: 60),
        ]
        snapshot.approvals = [
            .init(id: UUID(), kind: .chore, kidID: nil, kidName: "Max", kidColor: 0x0A84FF, title: "Clean the bathroom sink", points: 15, photo: nil, at: now),
        ]
        snapshot.homeCare = [
            .init(id: UUID(), name: "Replace HVAC filter", symbol: "air.purifier", due: now.addingTimeInterval(-3 * 86400), location: "Upstairs hallway", details: "16×25×1 MERV 11"),
        ]
        snapshot.dinner = .init(day: Calendar.current.startOfDay(for: now), title: "Tacos", symbol: "fork.knife")
        return snapshot
    }
}
