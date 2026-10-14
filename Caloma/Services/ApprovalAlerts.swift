import Foundation
import OSLog
import SwiftData
import UIKit
import UserNotifications

/// "Max finished Clean the bathroom sink" on the parents' phones, with Approve and Send Back
/// right in the notification (and Approve or Decline for a reward a kid asked for).
///
/// Caloma has no server, so these are posted by each parent's phone when sync brings in a new
/// chore or reward waiting for an OK: CloudKit wakes the app with a push, sync fetches the
/// change, and this posts the notification. When one parent handles it, the other parent's
/// notification goes away the next time their phone syncs.
enum ApprovalAlerts {
    nonisolated static let choreCategory = "approval.chore"
    nonisolated static let rewardCategory = "approval.reward"
    nonisolated static let approveAction = "approve"
    nonisolated static let sendBackAction = "sendBack"
    nonisolated static let declineAction = "decline"
    nonisolated private static let prefix = "approval."
    private static let log = Logger(subsystem: "com.stephenwarren.caloma", category: "approvals")

    /// On unless turned off in Family › Reminders.
    static var isOn: Bool { UserDefaults.standard.object(forKey: SettingsKey.approvalAlerts) as? Bool ?? true }

    /// The Approve / Send Back buttons. Both need the phone unlocked, so a kid can't approve
    /// their own chore from the lock screen.
    static func registerCategories() {
        let approve = UNNotificationAction(identifier: approveAction, title: "Approve", options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let sendBack = UNNotificationAction(identifier: sendBackAction, title: "Send Back", options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "arrow.uturn.backward"))
        let decline = UNNotificationAction(identifier: declineAction, title: "Decline", options: [.authenticationRequired, .destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let chore = UNNotificationCategory(identifier: choreCategory, actions: [approve, sendBack], intentIdentifiers: [], options: [])
        let reward = UNNotificationCategory(identifier: rewardCategory, actions: [approve, decline], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([chore, reward])
    }

    /// Posts a notification for each newly arrived chore or reward request, and takes down the
    /// ones that were handled. Skipped while Kid View is open on this device.
    static func update(newCompletions: [ChoreCompletion], newRedemptions: [Redemption], handled: [UUID], in context: ModelContext) {
        clear(handled)
        // A phone joining the family brings in old requests too; only announce fresh ones.
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        let newCompletions = newCompletions.filter { $0.status == .pending && $0.completedAt > cutoff }
        let newRedemptions = newRedemptions.filter { $0.status == .pending && $0.requestedAt > cutoff }
        guard isOn, !UserDefaults.standard.bool(forKey: SettingsKey.kidViewOpen) else { return }
        guard !newCompletions.isEmpty || !newRedemptions.isEmpty else { return }
        let members = Persistence.fetchAll(Member.self, in: context)
        let words = PointWords.current()
        var requests: [Request] = []
        for completion in newCompletions {
            let kid = members.first { $0.id == completion.memberID }?.name ?? "A kid"
            let chore = Family.chore(completion.choreID, in: context)
            requests.append(Request(
                id: completion.id,
                category: choreCategory,
                title: "\(kid) finished a chore",
                body: "\(chore?.title ?? "A chore") · +\(words.count(completion.points))",
                photo: completion.photoData
            ))
        }
        for redemption in newRedemptions {
            let kid = members.first { $0.id == redemption.memberID }?.name ?? "A kid"
            let reward = Family.reward(redemption.rewardID, in: context)
            requests.append(Request(
                id: redemption.id,
                category: rewardCategory,
                title: "\(kid) wants a reward",
                body: "\(reward?.name ?? "A reward") · \(words.count(redemption.cost))",
                photo: nil
            ))
        }
        let previous = posting
        posting = Task {
            await previous?.value
            await post(requests)
        }
    }

    private static var posting: Task<Void, Never>?

    /// Waits for notifications still being posted, so a background wake-up doesn't end first.
    static func finishPosting() async {
        await posting?.value
    }

    /// Takes down the notifications for requests that were approved, sent back or declined.
    static func clear(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let identifiers = ids.map { prefix + $0.uuidString }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private struct Request: Sendable {
        var id: UUID
        var category: String
        var title: String
        var body: String
        var photo: Data?
    }

    private static func post(_ requests: [Request]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        for request in requests {
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default
            content.categoryIdentifier = request.category
            content.threadIdentifier = "approvals"
            content.userInfo = ["url": "caloma://approvals", "id": request.id.uuidString]
            if let photo = request.photo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("caloma-alert-\(request.id.uuidString).jpg")
                // Whatever the camera saved (HEIC, PNG), as a JPEG notifications can show.
                if let jpeg = UIImage(data: photo)?.jpegData(compressionQuality: 0.8),
                   (try? jpeg.write(to: url)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "photo", url: url) {
                    content.attachments = [attachment]
                }
            }
            do {
                try await center.add(UNNotificationRequest(identifier: prefix + request.id.uuidString, content: content, trigger: nil))
            } catch {
                log.error("Couldn't post an approval alert: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Approve, Send Back or Decline from the notification.
    static func respond(action: String, id: UUID, container: ModelContainer) {
        // Not from a device that's in Kid View, even if the notification came in earlier.
        guard !AppRouter.shared.kidViewOpen else { return }
        let context = container.mainContext
        let target: UUID? = id
        var completions = FetchDescriptor<ChoreCompletion>(predicate: #Predicate { $0.id == target })
        completions.fetchLimit = 1
        if let completion = try? context.fetch(completions).first {
            switch action {
            case approveAction: Family.approve(completion, in: context)
            case sendBackAction: Family.sendBack(completion, in: context)
            default: break
            }
            return
        }
        var redemptions = FetchDescriptor<Redemption>(predicate: #Predicate { $0.id == target })
        redemptions.fetchLimit = 1
        if let redemption = try? context.fetch(redemptions).first {
            switch action {
            case approveAction: Family.approve(redemption, in: context)
            case declineAction: Family.decline(redemption, in: context)
            default: break
            }
        }
    }
}

/// Handles taps on notifications: the Approve / Send Back buttons, and opening the app to the
/// right place.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationResponder()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let idString = info["id"] as? String
        let url = info["url"] as? String
        await MainActor.run {
            if let idString, let id = UUID(uuidString: idString),
               [ApprovalAlerts.approveAction, ApprovalAlerts.sendBackAction, ApprovalAlerts.declineAction].contains(action),
               let container = AppRouter.shared.container {
                ApprovalAlerts.respond(action: action, id: id, container: container)
                return
            }
            if action == UNNotificationDefaultActionIdentifier, let url, let link = URL(string: url) {
                AppRouter.shared.open(link)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
