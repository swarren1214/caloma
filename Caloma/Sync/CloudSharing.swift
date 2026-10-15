import CloudKit
import OSLog
import SwiftUI
import UIKit
import UserNotifications

// Sharing the family: the owner invites with Apple's sharing sheet (Messages, Mail, a link),
// the other parent taps the invitation, says Join, and their phone switches to the family.

extension CloudSync {
    private var shareRecordID: CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
    }

    /// The family's share, if there is one.
    func fetchShare() async -> CKShare? {
        guard AppConfig.cloudSyncEnabled else { return nil }
        do {
            return try await database.record(for: shareRecordID) as? CKShare
        } catch {
            return nil
        }
    }

    /// The share to invite with: the existing one, or a new share of the whole family zone,
    /// saved to iCloud. Throws if iCloud won't save it: a share that was never saved has no
    /// link, and the invitation would sit in Messages loading forever.
    func makeShare(familyName: String) async throws -> CKShare {
        if let existing = await fetchShare(), existing.url != nil {
            if existing[CKShare.SystemFieldKey.title] as? String != familyName {
                existing[CKShare.SystemFieldKey.title] = familyName
                _ = try? await ckContainer.privateCloudDatabase.modifyRecords(saving: [existing], deleting: [], savePolicy: .changedKeys)
            }
            return existing
        }
        let database = ckContainer.privateCloudDatabase
        // The zone has to exist before it can be shared.
        let (zones, _) = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        if case .failure(let error)? = zones[zoneID] {
            sharingLog.error("Couldn't save the family zone: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = familyName
        share.publicPermission = .none
        let (results, _) = try await database.modifyRecords(saving: [share], deleting: [])
        switch results[share.recordID] {
        case .success(let saved as CKShare)? where saved.url != nil:
            becameOwner()
            return saved
        case .failure(let error)?:
            sharingLog.error("Couldn't save the family share: \(error.localizedDescription, privacy: .public)")
            throw error
        default:
            sharingLog.error("iCloud saved the share without a link")
            throw SharingError.noLink
        }
    }

    /// Invite: the share sheet, with the family attached as a collaboration, so Messages sends
    /// a proper invitation (and Mail, AirDrop or Copy Link work too).
    func presentInvite(familyName: String) async throws {
        let share = try await makeShare(familyName: familyName)
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: ckContainer, allowedSharingOptions: CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite, allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        configuration.metadataProvider = { key in
            switch key {
            case .title: familyName
            default: nil
            }
        }
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        guard let presenter = UIApplication.shared.topViewController else { return }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    /// Opens Apple's sharing screen: see who's joined, remove someone, stop sharing.
    func presentSharing(familyName: String) async throws {
        let share = try await makeShare(familyName: familyName)
        let controller = UICloudSharingController(share: share, container: ckContainer)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = SharingDelegate.shared
        SharingDelegate.shared.familyName = familyName
        guard let presenter = UIApplication.shared.topViewController else { return }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    /// Someone tapped an invitation. Asks them to confirm before anything changes.
    func received(_ metadata: CKShare.Metadata) {
        guard metadata.participantRole != .owner else { return }
        pendingInvite = metadata
    }

    /// Joins the family in the invitation.
    func acceptInvite() async {
        guard let metadata = pendingInvite else { return }
        pendingInvite = nil
        do {
            _ = try await ckContainer.accept(metadata)
            await join(zoneID: metadata.share.recordID.zoneID)
        } catch {
            notice = "Couldn't join the family: \(error.localizedDescription)"
        }
    }

    /// Leaves the family this phone joined. The family's data comes off this phone.
    func leaveFamily() async {
        guard role == .participant else { return }
        do {
            try await ckContainer.sharedCloudDatabase.deleteRecord(withID: shareRecordID)
        } catch {
            // Leave locally anyway; the share is gone or unreachable.
        }
        await leaveLocally(message: "You left the family. Caloma is starting fresh on this iPhone.")
    }
}

private let sharingLog = Logger(subsystem: "com.stephenwarren.caloma", category: "sharing")

enum SharingError: LocalizedError {
    case noLink

    var errorDescription: String? {
        "iCloud didn't make an invitation link. Check that you're signed in to iCloud, then try again."
    }
}

/// Answers the sharing sheet.
final class SharingDelegate: NSObject, UICloudSharingControllerDelegate {
    static let shared = SharingDelegate()
    var familyName = "Our Family"
    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "sharing")

    func itemTitle(for csc: UICloudSharingController) -> String? { familyName }

    func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        UIImage(named: "CalomaMark")?.pngData()
    }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        log.error("Sharing failed: \(error.localizedDescription, privacy: .public)")
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        CloudSync.shared.becameOwner()
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        CloudSync.shared.stoppedSharing()
    }
}

extension UIApplication {
    /// The view controller on top, to present the sharing sheet from.
    var topViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Registers for the pushes CloudKit sends when the family changes, and hands invitations
/// (tapped while the app is running or to launch it) to `CloudSync`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationResponder.shared
        ApprovalAlerts.registerCategories()
        if AppConfig.cloudSyncEnabled && !ScreenshotMode.isOn { application.registerForRemoteNotifications() }
        return true
    }

    /// CloudKit's silent push when the family changes (a kid finished a chore on the iPad, say).
    /// Fetching right away is what lets the "Needs your OK" notification show up while the app
    /// is in the background.
    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard await MainActor.run(body: { AppConfig.cloudSyncEnabled }) else { return .noData }
        await CloudSync.shared.syncNow()
        await ApprovalAlerts.finishPosting()
        return .newData
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            CloudSync.shared.received(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        CloudSync.shared.received(cloudKitShareMetadata)
    }
}
