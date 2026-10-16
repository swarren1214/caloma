import ActivityKit
import Foundation
import OSLog
import SwiftData
import UIKit

/// Starts, updates and ends the "You're driving" Live Activity (`DrivingAttributes`).
///
/// It appears for the next event this phone's parent is set to drive (the event's driver),
/// starting up to two hours before, and shows on the Lock Screen, in the Dynamic Island and
/// on CarPlay. Without a server, a Live Activity can only start while Caloma is open, or from
/// `StartDrivingIntent` (a Shortcuts automation "When CarPlay connects" can run it). Once
/// started, it updates as the kids pack (sync brings their ticks in) and ends with the event.
@MainActor
enum DrivingLiveActivity {
    /// How long before an event the activity can start.
    nonisolated static let lead: TimeInterval = 2 * 3600
    private static let log = Logger(subsystem: "com.stephenwarren.caloma", category: "liveActivity")

    /// Brings the activity in line with the family: starts it if `allowStart` (the app is open,
    /// or an intent asked), updates what's packed, and ends one that's over or no longer yours.
    static func refresh(in context: ModelContext, now: Date = .now, allowStart: Bool? = nil) async {
        let canStart = allowStart ?? (UIApplication.shared.applicationState == .active)
        let next = nextDrive(in: context, now: now)
        for activity in Activity<DrivingAttributes>.activities {
            if let next, activity.attributes.occurrenceID == next.attributes.occurrenceID {
                if activity.content.state != next.state {
                    await activity.update(ActivityContent(state: next.state, staleDate: next.attributes.end))
                }
            } else {
                // Over, moved, deleted, or someone else is driving now.
                let over = activity.attributes.end <= now
                await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: over ? .default : .immediate)
            }
        }
        guard let next, canStart, ActivityAuthorizationInfo().areActivitiesEnabled,
              !Activity<DrivingAttributes>.activities.contains(where: { $0.attributes.occurrenceID == next.attributes.occurrenceID }) else { return }
        do {
            _ = try Activity.request(attributes: next.attributes, content: ActivityContent(state: next.state, staleDate: next.attributes.end, relevanceScore: 80), pushType: nil)
        } catch {
            log.error("Couldn't start the driving Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The next event this phone's parent drives to, starting within `lead` or already under way.
    static func nextDrive(in context: ModelContext, now: Date = .now, within: TimeInterval = lead) -> (attributes: DrivingAttributes, state: DrivingAttributes.ContentState)? {
        guard let me = UserDefaults.standard.string(forKey: SettingsKey.currentMember).flatMap(UUID.init(uuidString:)) else { return nil }
        let events = Persistence.fetchAll(FamilyEvent.self, in: context).filter { !$0.isArchived && !$0.isAllDay && $0.driverID == me }
        guard !events.isEmpty else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let candidates = CalendarMath.occurrences(of: events.map(\.record), from: today, through: tomorrow)
            .filter { $0.end > now && $0.start.timeIntervalSince(now) <= within }
        guard let occurrence = candidates.min(by: { $0.start < $1.start }),
              let event = events.first(where: { $0.id == occurrence.event.id }) else { return nil }

        let members = Persistence.fetchAll(Member.self, in: context).filter { !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }
        let attendees = event.attendeeIDs.isEmpty ? [] : members.filter { event.attendeeIDs.contains($0.id) }
        let accent = UserDefaults.standard.string(forKey: SettingsKey.accentHex).flatMap { UInt32($0.dropFirst(), radix: 16) } ?? Brand.defaultAccentHex
        let attributes = DrivingAttributes(
            occurrenceID: occurrence.id,
            title: event.title,
            who: event.attendeeIDs.isEmpty ? "Everyone" : attendees.map(\.name).formatted(.list(type: .and)),
            location: event.location,
            start: occurrence.start,
            end: occurrence.end,
            color: event.attendeeIDs.isEmpty ? accent : (attendees.first?.color.hex ?? accent)
        )

        // An item counts as packed when every kid going has ticked it in Kid View.
        let kidsGoing = (event.attendeeIDs.isEmpty ? members : attendees).filter(\.isKid).map(\.id)
        let day = calendar.startOfDay(for: occurrence.start)
        let eventID: UUID? = event.id
        let packings = ((try? context.fetch(FetchDescriptor<EventPacking>(predicate: #Predicate { $0.eventID == eventID }))) ?? [])
            .filter { calendar.isDate($0.day, inSameDayAs: day) }
        let bring = event.bring.map { item in
            let packed = !kidsGoing.isEmpty && kidsGoing.allSatisfy { kid in
                packings.contains { $0.memberID == kid && $0.packed.contains(item) }
            }
            return DrivingAttributes.ContentState.Item(name: item, packed: packed)
        }
        return (attributes, DrivingAttributes.ContentState(bring: bring))
    }
}
