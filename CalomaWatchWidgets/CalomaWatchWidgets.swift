import SwiftUI
import WidgetKit

// The watch's Smart Stack widgets and complications, from the Tend designs: Coming Up, Kids
// Today and Home Care. They read the snapshot the Watch app saved in the shared app group.

@main
struct CalomaWatchWidgets: WidgetBundle {
    var body: some Widget {
        ComingUpWidget()
        KidsTodayWidget()
        HomeCareWidget()
    }
}

// MARK: Timeline

struct FamilyEntry: TimelineEntry {
    var date: Date
    var snapshot: WatchSnapshot
    var relevance: TimelineEntryRelevance?
}

/// One entry now, then one as each upcoming event starts and ends, so "coming up" moves on by
/// itself. The Watch app asks for new timelines whenever the phone sends news.
struct FamilyProvider: TimelineProvider {
    /// Which widget is asking, for how much it should matter in the Smart Stack.
    var kind: Kind

    enum Kind { case comingUp, kids, homeCare }

    func placeholder(in context: Context) -> FamilyEntry {
        FamilyEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (FamilyEntry) -> Void) {
        let snapshot = context.isPreview ? WatchSnapshot.sample : (WatchSnapshot.load() ?? WatchSnapshot())
        completion(FamilyEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FamilyEntry>) -> Void) {
        let snapshot = WatchSnapshot.load() ?? WatchSnapshot()
        let now = Date.now
        let horizon = now.addingTimeInterval(12 * 3600)
        var dates = [now]
        for event in snapshot.events where !event.isAllDay {
            if event.start > now && event.start < horizon { dates.append(event.start) }
            if event.end > now && event.end < horizon { dates.append(event.end) }
        }
        // Midnight, so "due today" and "1 day late" move on.
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        if midnight < horizon { dates.append(midnight) }
        // Just before each start too, so the stack can bring it up ahead of time.
        for event in snapshot.events where !event.isAllDay {
            let early = event.start.addingTimeInterval(-3600)
            if early > now && early < horizon { dates.append(early) }
        }
        let entries = Set(dates).sorted().map { date in
            FamilyEntry(date: date, snapshot: snapshot, relevance: relevance(of: snapshot, at: date))
        }
        completion(Timeline(entries: entries, policy: .after(min(horizon, now.addingTimeInterval(3600)))))
    }

    private func relevance(of snapshot: WatchSnapshot, at date: Date) -> TimelineEntryRelevance {
        switch kind {
        case .comingUp:
            guard let next = snapshot.upcoming(now: date).first(where: { !$0.isAllDay }) else { return .init(score: 0) }
            let minutes = next.start.timeIntervalSince(date) / 60
            // Most important in the hour before, especially when you're driving.
            if minutes <= 60 && minutes > -15 { return .init(score: next.youDrive ? 100 : 70, duration: next.end.timeIntervalSince(date)) }
            return .init(score: 10)
        case .kids:
            return .init(score: snapshot.needsOKCount > 0 ? 80 : 5)
        case .homeCare:
            return .init(score: snapshot.homeCare.contains { $0.isLate(now: date) } ? 40 : 2)
        }
    }
}

// MARK: Coming Up

struct ComingUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "comingUp", provider: FamilyProvider(kind: .comingUp)) { entry in
            ComingUpView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "caloma://comingup"))
        }
        .configurationDisplayName("Coming Up")
        .description("The family's next events and who's driving.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .accessoryCorner])
    }
}

struct ComingUpView: View {
    var entry: FamilyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let events = entry.snapshot.upcoming(now: entry.date)
        switch family {
        case .accessoryInline:
            if let next = events.first {
                Text("\(next.title) \(next.timeLabel(now: entry.date))")
            } else {
                Text("Nothing coming up")
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if let next = events.first {
                    VStack(spacing: 0) {
                        Image(systemName: next.youDrive ? "car.fill" : "calendar")
                            .font(.caption)
                        Text(next.isAllDay ? "Today" : next.start.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .minimumScaleFactor(0.6)
                    }
                } else {
                    Image(systemName: "calendar")
                }
            }
            .accessibilityLabel(events.first.map { "\($0.title) at \($0.timeLabel(now: entry.date))" } ?? "Nothing coming up")
        case .accessoryCorner:
            Image(systemName: events.first?.youDrive == true ? "car.fill" : "calendar")
                .font(.title3)
                .widgetLabel {
                    Text(events.first.map { "\($0.title) \($0.timeLabel(now: entry.date))" } ?? "Free")
                }
        default:
            VStack(alignment: .leading, spacing: 3) {
                Text("COMING UP")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if events.isEmpty {
                    Text("Nothing planned")
                        .font(.headline)
                } else {
                    ForEach(events.prefix(2)) { event in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(rgb: event.color))
                                .frame(width: 3)
                                .widgetAccentable()
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(event.title) · \(event.who)")
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(event.youDrive ? "\(event.timeLabel(now: entry.date)) · You're driving" : (event.driver.map { "\(event.timeLabel(now: entry.date)) · \($0) drives" } ?? event.timeLabel(now: entry.date)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Kids Today

struct KidsTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "kidsToday", provider: FamilyProvider(kind: .kids)) { entry in
            KidsTodayView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: entry.snapshot.needsOKCount > 0 ? "caloma://approvals" : "caloma://kids"))
        }
        .configurationDisplayName("Kids Today")
        .description("Each kid's jobs for the day, and what needs your OK.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct KidsTodayView: View {
    var entry: FamilyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snapshot = entry.snapshot
        switch family {
        case .accessoryInline:
            Text(snapshot.needsOKCount > 0 ? "\(snapshot.needsOKCount) need your OK" : "\(snapshot.kids.filter { $0.total > 0 && $0.done >= $0.total }.count) of \(snapshot.kids.count) kids done")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption)
                        .widgetAccentable()
                    Text("\(snapshot.needsOKCount)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
            }
            .accessibilityLabel("\(snapshot.needsOKCount) need your OK")
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("KIDS TODAY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(snapshot.kids.prefix(4)) { kid in
                        VStack(spacing: 1) {
                            Gauge(value: kid.total == 0 ? 1 : Double(kid.done) / Double(kid.total)) {
                                EmptyView()
                            }
                            .gaugeStyle(.accessoryCircularCapacity)
                            .tint(Color(rgb: kid.color))
                            .scaleEffect(0.62)
                            .frame(width: 30, height: 30)
                            Text(kid.name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(kid.name), \(kid.done) of \(kid.total)")
                    }
                }
                if snapshot.needsOKCount > 0 {
                    Label("\(snapshot.needsOKCount) need\(snapshot.needsOKCount == 1 ? "s" : "") your OK", systemImage: "checkmark.shield.fill")
                        .font(.caption2.weight(.semibold))
                        .widgetAccentable()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Home Care

struct HomeCareWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "homeCare", provider: FamilyProvider(kind: .homeCare)) { entry in
            HomeCareWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "caloma://homecare"))
        }
        .configurationDisplayName("Home Care")
        .description("The next home care job, and whether it's late.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct HomeCareWidgetView: View {
    var entry: FamilyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let next = entry.snapshot.homeCare.first
        switch family {
        case .accessoryInline:
            Text(next.map { "\($0.name) · \($0.dueLabel(now: entry.date))" } ?? "Home care all done")
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("HOME CARE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if let next {
                    Label(next.name, systemImage: next.symbol)
                        .font(.headline)
                        .lineLimit(1)
                    Text([next.dueLabel(now: entry.date), next.location].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(next.isLate(now: entry.date) ? .red : .secondary)
                        .lineLimit(1)
                    if entry.snapshot.homeCare.count > 1 {
                        Text("+\(entry.snapshot.homeCare.count - 1) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("All caught up")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Sample

extension WatchSnapshot {
    /// For the widget gallery.
    static var sample: WatchSnapshot {
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
            .init(id: UUID(), kind: .reward, kidID: nil, kidName: "June", kidColor: 0xFF9F0A, title: "Movie night pick", points: 50, photo: nil, at: now),
        ]
        snapshot.homeCare = [
            .init(id: UUID(), name: "Replace HVAC filter", symbol: "air.purifier", due: now.addingTimeInterval(-3 * 86400), location: "Upstairs hallway"),
        ]
        return snapshot
    }
}
