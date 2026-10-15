import Foundation
import Observation
import OSLog
import UserNotifications
import WatchConnectivity
import WidgetKit

/// The watch's side of the connection to the parent's iPhone: the latest `WatchSnapshot`
/// (kept on the watch, so it shows something when the phone is away) and the taps sent back.
@MainActor
@Observable
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    /// What the watch shows. Empty until the phone has sent something.
    private(set) var snapshot: WatchSnapshot
    /// The phone has sent at least one snapshot, ever.
    private(set) var hasData: Bool
    /// A page to show, from tapping a notification.
    var requestedPage: WatchPage?

    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.caloma.watch", category: "phone")
    /// Taps made before the connection was ready, sent once it is.
    @ObservationIgnored private var unsent: [WatchAction] = []
    /// What was tapped lately, so a snapshot the phone sent before hearing about it doesn't
    /// bring it back for a moment.
    @ObservationIgnored private var recentlyHandled: [UUID: Date] = [:]
    /// My chores ticked or unticked lately, and when.
    @ObservationIgnored private var recentChoreTicks: [UUID: (done: Bool, at: Date)] = [:]

    override init() {
        let saved = WatchSnapshot.load()
        snapshot = saved ?? WatchSnapshot()
        hasData = saved != nil
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.approvalCategories)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Carries out a tap: shows it on the watch right away, and sends it to the phone (now if
    /// the phone is reachable, or as soon as it is).
    func perform(_ action: WatchAction) {
        var updated = snapshot
        switch action {
        case .approve(let id), .sendBack(let id), .decline(let id):
            if case .approve = action, let approval = updated.approvals.first(where: { $0.id == id }),
               let index = updated.kids.firstIndex(where: { $0.id == approval.kidID }) {
                // A chore earns its points; a reward spends them.
                updated.kids[index].balance += approval.kind == .chore ? approval.points : -approval.points
            }
            updated.approvals.removeAll { $0.id == id }
            recentlyHandled[id] = .now
        case .homeTaskDone(let id):
            updated.homeCare.removeAll { $0.id == id }
            recentlyHandled[id] = .now
        case .choreDone(let id), .choreUndone(let id):
            var done = false
            if case .choreDone = action { done = true }
            if let index = updated.myChores?.firstIndex(where: { $0.choreID == id }) {
                updated.myChores?[index].done = done
            }
            recentChoreTicks[id] = (done, .now)
        }
        // Newer than anything the phone sent before this tap.
        updated.made = .now
        use(updated)
        send(action)
    }

    private func send(_ action: WatchAction) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            unsent.append(action)
            return
        }
        if session.isReachable {
            session.sendMessage(action.message, replyHandler: { _ in }) { [log] error in
                // Didn't get through: queue it for when the phone's back.
                log.error("Message failed, queuing: \(error.localizedDescription, privacy: .public)")
                WCSession.default.transferUserInfo(action.message)
            }
        } else {
            session.transferUserInfo(action.message)
        }
    }

    private func didActivate(with saved: Data?) {
        let waiting = unsent
        unsent = []
        for action in waiting { send(action) }
        // The last thing the phone sent, if it's newer than what's on the watch.
        if let saved, let incoming = WatchSnapshot.decode(saved), incoming.made > snapshot.made || !hasData {
            receive(incoming)
        }
    }

    private func receive(_ incoming: WatchSnapshot) {
        var incoming = incoming
        let cutoff = Date.now.addingTimeInterval(-120)
        recentlyHandled = recentlyHandled.filter { $0.value > cutoff }
        var handled = Set(recentlyHandled.keys)
        for transfer in WCSession.default.outstandingUserInfoTransfers {
            switch WatchAction(message: transfer.userInfo) {
            case .approve(let id), .sendBack(let id), .decline(let id), .homeTaskDone(let id): handled.insert(id)
            case .choreDone, .choreUndone, nil: break
            }
        }
        incoming.approvals.removeAll { handled.contains($0.id) }
        incoming.homeCare.removeAll { handled.contains($0.id) }
        // A chore ticked a moment ago stays as ticked until the phone has caught up.
        recentChoreTicks = recentChoreTicks.filter { $0.value.at > cutoff }
        if var chores = incoming.myChores {
            for index in chores.indices {
                if let tick = recentChoreTicks[chores[index].choreID] { chores[index].done = tick.done }
            }
            incoming.myChores = chores
        }
        use(incoming)
    }

    private func use(_ snapshot: WatchSnapshot) {
        self.snapshot = snapshot
        hasData = true
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Notifications

    // The "Needs your OK" notifications come from the iPhone (`ApprovalAlerts`). With this app
    // installed, their buttons are answered here, so the same categories are registered.
    nonisolated private static let approveAction = "approve"
    nonisolated private static let sendBackAction = "sendBack"
    nonisolated private static let declineAction = "decline"

    private static var approvalCategories: Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: approveAction, title: "Approve", options: [])
        let sendBack = UNNotificationAction(identifier: sendBackAction, title: "Send Back", options: [])
        let decline = UNNotificationAction(identifier: declineAction, title: "Decline", options: [.destructive])
        return [
            UNNotificationCategory(identifier: "approval.chore", actions: [approve, sendBack], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "approval.reward", actions: [approve, decline], intentIdentifiers: [], options: []),
        ]
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let saved = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data
        Task { @MainActor in PhoneLink.shared.didActivate(with: saved) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshot.contextKey] as? Data, let snapshot = WatchSnapshot.decode(data) else { return }
        Task { @MainActor in PhoneLink.shared.receive(snapshot) }
    }
}

extension PhoneLink: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo["id"] as? String).flatMap(UUID.init(uuidString:))
        let isApproval = response.notification.request.content.categoryIdentifier.hasPrefix("approval.")
        await MainActor.run {
            switch (action, id) {
            case (Self.approveAction, let id?): PhoneLink.shared.perform(.approve(id))
            case (Self.sendBackAction, let id?): PhoneLink.shared.perform(.sendBack(id))
            case (Self.declineAction, let id?): PhoneLink.shared.perform(.decline(id))
            case (UNNotificationDefaultActionIdentifier, _):
                if isApproval { PhoneLink.shared.requestedPage = .approvals }
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
