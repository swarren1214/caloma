import EventKit
import Foundation
import OSLog
import SwiftData
import SwiftUI

/// An event from the Apple Calendar app, shown read-only on the family calendar.
struct AppleEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var calendarTitle: String
    var color: Color
}

/// Apple Calendar, both ways, each off until turned on in Profile › Apple Calendar:
/// - Show Apple Calendar events: the calendars picked there show on the family calendar.
/// - Add family events to Apple Calendar: the next two months of family events go into a
///   "Caloma" calendar, kept in step whenever an event changes. That calendar is Caloma's;
///   changes made to it in the Calendar app are replaced the next time Caloma writes.
@Observable
final class AppleCalendar {
    static let shared = AppleCalendar()

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "apple-calendar")

    private enum Key {
        static let read = "appleCalendar.read"
        static let write = "appleCalendar.write"
        static let hidden = "appleCalendar.hiddenCalendars"
        static let calomaCalendar = "appleCalendar.calomaCalendarID"
        static let written = "appleCalendar.writtenEvents"
    }

    /// Bumped when the Calendar app's data changes, so views showing Apple events refresh.
    private(set) var revision = 0
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    var showsAppleEvents: Bool {
        didSet { defaults.set(showsAppleEvents, forKey: Key.read) }
    }

    var addsFamilyEvents: Bool {
        didSet { defaults.set(addsFamilyEvents, forKey: Key.write) }
    }

    /// Calendars someone unticked in Profile › Apple Calendar.
    var hiddenCalendarIDs: Set<String> {
        didSet {
            defaults.set(Array(hiddenCalendarIDs), forKey: Key.hidden)
            revision += 1
        }
    }

    private init() {
        showsAppleEvents = defaults.bool(forKey: Key.read)
        addsFamilyEvents = defaults.bool(forKey: Key.write)
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    var hasAccess: Bool { status == .fullAccess }

    /// Asks for full calendar access. Returns whether it was given.
    func requestAccess() async -> Bool {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            log.error("Calendar access failed: \(error.localizedDescription, privacy: .public)")
        }
        status = EKEventStore.authorizationStatus(for: .event)
        revision += 1
        return hasAccess
    }

    /// The calendars that can be shown, without Caloma's own.
    var calendars: [EKCalendar] {
        guard hasAccess else { return [] }
        let ours = defaults.string(forKey: Key.calomaCalendar)
        return store.calendars(for: .event)
            .filter { $0.calendarIdentifier != ours }
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// Apple Calendar events from the start of one day through the end of another.
    func events(from: Date, through: Date, calendar: Calendar = .current) -> [AppleEvent] {
        _ = revision
        // Screenshot mode shows the demo family's calendar only.
        guard !ScreenshotMode.isOn, showsAppleEvents, hasAccess else { return [] }
        let shown = calendars.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { return [] }
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)) ?? through
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        return store.events(matching: predicate).map { event in
            AppleEvent(
                id: "\(event.eventIdentifier ?? UUID().uuidString)@\(Int(event.startDate.timeIntervalSince1970))",
                title: event.title ?? "Event",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location ?? "",
                calendarTitle: event.calendar.title,
                color: Color(cgColor: event.calendar.cgColor)
            )
        }
        .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// Writes the next two months of family events to the Caloma calendar (and takes away
    /// ones that were deleted or moved). Does nothing unless it's turned on.
    func pushFamilyEvents(in context: ModelContext) {
        guard !ScreenshotMode.isOn, addsFamilyEvents, hasAccess, let target = calomaCalendar() else { return }
        let members = Persistence.fetchAll(Member.self, in: context)
        let events = Persistence.fetchAll(FamilyEvent.self, in: context).filter { !$0.isArchived }
        let now = Date.now
        let from = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let until = Calendar.current.date(byAdding: .day, value: 60, to: now) ?? now
        let occurrences = CalendarMath.occurrences(of: events.map(\.record), from: from, through: until)
        var written = defaults.dictionary(forKey: Key.written) as? [String: String] ?? [:]
        let wanted = Set(occurrences.map(\.id))

        // Remove what's no longer wanted.
        for (key, identifier) in written where !wanted.contains(key) {
            if let old = store.event(withIdentifier: identifier) {
                try? store.remove(old, span: .thisEvent, commit: false)
            }
            written[key] = nil
        }
        // Add or update the rest.
        for occurrence in occurrences {
            let event = written[occurrence.id].flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
            event.calendar = target
            event.title = occurrence.event.title
            event.startDate = occurrence.start
            event.endDate = occurrence.event.isAllDay ? occurrence.start : occurrence.end
            event.isAllDay = occurrence.event.isAllDay
            event.location = occurrence.event.location.isEmpty ? nil : occurrence.event.location
            event.notes = notes(for: occurrence.event, members: members)
            do {
                try store.save(event, span: .thisEvent, commit: false)
                if let identifier = event.eventIdentifier { written[occurrence.id] = identifier }
            } catch {
                log.error("Couldn't write an event: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try store.commit()
        } catch {
            log.error("Couldn't save to Apple Calendar: \(error.localizedDescription, privacy: .public)")
        }
        defaults.set(written, forKey: Key.written)
    }

    /// Takes every family event back out of Apple Calendar (when it's turned off).
    func removeFamilyEvents() {
        guard hasAccess else { return }
        let written = defaults.dictionary(forKey: Key.written) as? [String: String] ?? [:]
        for identifier in written.values {
            if let event = store.event(withIdentifier: identifier) {
                try? store.remove(event, span: .thisEvent, commit: false)
            }
        }
        try? store.commit()
        defaults.removeObject(forKey: Key.written)
    }

    private func notes(for event: EventRecord, members: [Member]) -> String {
        var lines: [String] = []
        let who = event.isEveryone ? "Everyone" : members.filter { event.attendeeIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        if !who.isEmpty { lines.append("Who: \(who)") }
        if let driver = members.first(where: { $0.id == event.driverID }) { lines.append("Driving: \(driver.name)") }
        if !event.bring.isEmpty { lines.append("Bring: \(event.bring.joined(separator: ", "))") }
        lines.append("From the Caloma family calendar.")
        return lines.joined(separator: "\n")
    }

    /// The "Caloma" calendar, made the first time it's needed.
    private func calomaCalendar() -> EKCalendar? {
        if let id = defaults.string(forKey: Key.calomaCalendar), let existing = store.calendar(withIdentifier: id) {
            return existing
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = AppConfig.appName
        calendar.cgColor = UIColor(Brand.defaultAccent).cgColor
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local }) else { return nil }
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
            defaults.set(calendar.calendarIdentifier, forKey: Key.calomaCalendar)
            return calendar
        } catch {
            log.error("Couldn't make the Caloma calendar: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
