import Foundation
import OSLog
import SwiftData
import UIKit
import WatchConnectivity
import WidgetKit

/// Keeps a parent's Apple Watch up to date, and carries out what they tap on it. The same
/// snapshot feeds the iPhone's widgets (on the Home Screen and the CarPlay dashboard), and each
/// update refreshes the "You're driving" Live Activity (`DrivingLiveActivity`).
///
/// Whenever the family's data changes on this phone (a save here, or sync bringing in a kid's
/// finished chore), a `WatchSnapshot` goes to the watch as its application context: only the
/// latest one is kept, so a watch that was away catches up in one go. Approve, Send Back,
/// Decline and Mark Done come back as `WatchAction`s; a tap on the watch wakes this app in the
/// background if it isn't running.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "watch")
    private var container: ModelContainer?
    private var session: WCSession?
    private var sendTask: Task<Void, Never>?
    private var lastSent: Data?
    /// What the widgets last got, so they're only reloaded when something changed.
    private var lastSaved: Data?
    private var saveObserver: NSObjectProtocol?

    /// Starts keeping the widgets and Live Activity current, and the watch connection if this
    /// device can have a watch (an iPad can't).
    func start(with container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
        }
        // Any save, in any context, means the watch may be out of date.
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in WatchBridge.shared.setNeedsUpdate() }
        }
    }

    /// Sends a fresh snapshot shortly, folding a burst of changes into one.
    func setNeedsUpdate() {
        guard container != nil else { return }
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            send()
        }
    }

    private func send() {
        guard let container else { return }
        let snapshot = Self.snapshot(in: container.mainContext)
        // `made` changes every time; compare the rest so an unchanged family isn't re-sent.
        var unstamped = snapshot
        unstamped.made = .distantPast
        let fingerprint = unstamped.encoded()

        // The iPhone's widgets read the snapshot from the shared app group.
        if fingerprint != lastSaved {
            snapshot.save()
            lastSaved = fingerprint
            WidgetCenter.shared.reloadAllTimelines()
        }
        Task { await DrivingLiveActivity.refresh(in: container.mainContext) }
        // The other Hearth apps on this device see the family too.
        HearthLink.publishFamily(in: container.mainContext)

        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = snapshot.encoded(), fingerprint != lastSent else { return }
        do {
            try session.updateApplicationContext([WatchSnapshot.contextKey: data])
            lastSent = fingerprint
        } catch {
            log.error("Couldn't update the watch: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Building the snapshot

    static func snapshot(in context: ModelContext, now: Date = .now) -> WatchSnapshot {
        let calendar = Calendar.current
        let defaults = UserDefaults.standard
        let members = Persistence.fetchAll(Member.self, in: context).filter { !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }
        let family = FamilySnapshot(
            members: members,
            chores: Persistence.fetchAll(Chore.self, in: context),
            completions: Persistence.fetchAll(ChoreCompletion.self, in: context),
            points: Persistence.fetchAll(PointEntry.self, in: context),
            redemptions: Persistence.fetchAll(Redemption.self, in: context)
        )
        let me = defaults.string(forKey: SettingsKey.currentMember).flatMap(UUID.init(uuidString:))
        let accentHex = defaults.string(forKey: SettingsKey.accentHex).flatMap { UInt32($0.dropFirst(), radix: 16) } ?? Brand.defaultAccentHex
        func member(_ id: UUID?) -> Member? { members.first { $0.id == id } }

        var snapshot = WatchSnapshot(made: now, accent: accentHex, pointWord: PointWords.current().plural)

        // Needs your OK, oldest first, as on the phone.
        let completions = Persistence.fetchAll(ChoreCompletion.self, in: context).filter { $0.status == .pending }
        let redemptions = Persistence.fetchAll(Redemption.self, in: context).filter { $0.status == .pending }
        var approvals: [WatchSnapshot.Approval] = completions.map { completion in
            let kid = member(completion.memberID)
            return WatchSnapshot.Approval(
                id: completion.id, kind: .chore, kidID: completion.memberID,
                kidName: kid?.name ?? "A kid", kidColor: kid?.color.hex ?? 0x8E8E93,
                title: Family.chore(completion.choreID, in: context)?.title ?? "A chore",
                points: completion.points, photo: nil, at: completion.completedAt
            )
        }
        approvals += redemptions.map { redemption in
            let kid = member(redemption.memberID)
            return WatchSnapshot.Approval(
                id: redemption.id, kind: .reward, kidID: redemption.memberID,
                kidName: kid?.name ?? "A kid", kidColor: kid?.color.hex ?? 0x8E8E93,
                title: Family.reward(redemption.rewardID, in: context)?.name ?? "A reward",
                points: redemption.cost, photo: nil, at: redemption.requestedAt
            )
        }
        approvals.sort { $0.at < $1.at }
        approvals = Array(approvals.prefix(12))
        // Photos are kept tiny, and only for the first few, so the update stays small.
        for index in approvals.indices.prefix(4) where approvals[index].kind == .chore {
            if let photo = completions.first(where: { $0.id == approvals[index].id })?.photoData {
                approvals[index].photo = thumbnail(photo)
            }
        }
        snapshot.approvals = approvals

        // Coming up: today, tomorrow and the day after.
        let events = Persistence.fetchAll(FamilyEvent.self, in: context).filter { !$0.isArchived }
        let today = calendar.startOfDay(for: now)
        let through = calendar.date(byAdding: .day, value: 2, to: today) ?? today
        let occurrences = CalendarMath.occurrences(of: events.map(\.record), from: today, through: through)
            .filter { $0.end > now || $0.event.isAllDay }
        var seen = Set<String>()
        snapshot.events = occurrences.compactMap { occurrence -> WatchSnapshot.Event? in
            // Multi-day events are listed on each day; the watch needs them once.
            guard seen.insert(occurrence.id).inserted else { return nil }
            let event = occurrence.event
            let attendees = event.attendeeIDs.compactMap(member)
            let driver = member(event.driverID)
            return WatchSnapshot.Event(
                id: occurrence.id,
                title: event.title,
                start: occurrence.start,
                end: occurrence.end,
                isAllDay: event.isAllDay,
                who: event.isEveryone ? "Everyone" : attendees.map(\.name).formatted(.list(type: .and)),
                color: event.isEveryone ? accentHex : (attendees.first?.color.hex ?? accentHex),
                location: event.location,
                driver: driver?.name,
                youDrive: driver != nil && driver?.id == me,
                bring: event.bring
            )
        }
        .prefix(10)
        .map { $0 }

        // Tonight's dinner, from BigTable's plan (see `HearthLink`).
        if let meal = HearthLink.shared.dinnerForSnapshot(on: now) {
            snapshot.dinner = WatchSnapshot.Dinner(
                day: today,
                title: meal.title,
                symbol: meal.symbol,
                notEating: meal.notEating?.isEmpty == false ? meal.notEating : nil
            )
        }

        // The kids' day.
        snapshot.kids = family.kids.map { kid in
            let progress = family.progress(for: kid, on: now)
            return WatchSnapshot.Kid(id: kid.id, name: kid.name, color: kid.color.hex, done: progress.done, total: progress.total, balance: family.balance(of: kid))
        }

        // Home care that's late or due within three days.
        let soon = calendar.date(byAdding: .day, value: 3, to: today) ?? today
        snapshot.homeCare = Persistence.fetchAll(HomeTask.self, in: context)
            .filter { !$0.isArchived && calendar.startOfDay(for: $0.nextDue) <= soon }
            .sorted { $0.nextDue < $1.nextDue }
            .prefix(6)
            .map { WatchSnapshot.HomeCareItem(id: $0.id, name: $0.name, symbol: $0.symbol, due: $0.nextDue, location: $0.location, details: $0.details.isEmpty ? nil : $0.details) }
        return snapshot
    }

    /// About 160 points across, as a small JPEG.
    private static func thumbnail(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = 160 / max(image.size.width, image.size.height, 1)
        let size = CGSize(width: image.size.width * min(scale, 1), height: image.size.height * min(scale, 1))
        let small = image.preparingThumbnail(of: size) ?? image
        return small.jpegData(compressionQuality: 0.5)
    }

    // MARK: Taps from the watch

    private func perform(_ action: WatchAction) {
        guard let container else { return }
        let context = container.mainContext
        switch action {
        case .approve(let id):
            if let completion = Self.completion(id, in: context) {
                Family.approve(completion, in: context)
            } else if let redemption = Self.redemption(id, in: context) {
                Family.approve(redemption, in: context)
            }
        case .sendBack(let id):
            if let completion = Self.completion(id, in: context), completion.status == .pending {
                Family.sendBack(completion, in: context)
            }
        case .decline(let id):
            if let redemption = Self.redemption(id, in: context), redemption.status == .pending {
                Family.decline(redemption, in: context)
            }
        case .homeTaskDone(let id):
            if let task = Family.homeTask(id, in: context) {
                let me = UserDefaults.standard.string(forKey: SettingsKey.currentMember).flatMap(UUID.init(uuidString:))
                Family.markHomeTaskDone(task, by: me, in: context)
            }
        }
        // Answer right away rather than after the debounce, even if nothing changed (another
        // parent got there first), so the watch matches the phone.
        sendTask?.cancel()
        lastSent = nil
        send()
    }

    private static func completion(_ id: UUID, in context: ModelContext) -> ChoreCompletion? {
        let target = id
        var descriptor = FetchDescriptor<ChoreCompletion>(predicate: #Predicate { $0.id == target })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func redemption(_ id: UUID, in context: ModelContext) -> Redemption? {
        let target = id
        var descriptor = FetchDescriptor<Redemption>(predicate: #Predicate { $0.id == target })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in WatchBridge.shared.setNeedsUpdate() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        // The Watch app was just installed, or a different watch was picked.
        Task { @MainActor in
            WatchBridge.shared.lastSent = nil
            WatchBridge.shared.setNeedsUpdate()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another watch: start again with the new one.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let action = WatchAction(message: message)
        Task { @MainActor in
            if let action { WatchBridge.shared.perform(action) }
            replyHandler(["ok": action != nil])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = WatchAction(message: message) else { return }
        Task { @MainActor in WatchBridge.shared.perform(action) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let action = WatchAction(message: userInfo) else { return }
        Task { @MainActor in WatchBridge.shared.perform(action) }
    }
}
