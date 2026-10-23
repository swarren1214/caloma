import CloudKit
import SwiftUI
import UIKit
import UserNotifications

// Sharing the family: there's no Caloma invitation any more. The family's zone ("Caloma", in the
// Hearth container) is shared with everyone in the Hearth household automatically
// (`CloudSync.updateSharing`, through `HearthAppSharing`), so one household invitation covers
// every Hearth app. Household invitations tapped in Messages or Mail land here.

/// Registers for the pushes CloudKit sends when the family changes, and hands household
/// invitations (tapped while the app is running or to launch it) to `HearthHouseholdStore`.
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
        // What changed, not a full download (the household store catches up on what the engine
        // didn't hear about).
        await CloudSync.shared.syncNow(full: false)
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
        if let metadata = connectionOptions.cloudKitShareMetadata, HearthHouseholdStore.handles(metadata) {
            HearthHouseholdStore.shared.receive(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        if HearthHouseholdStore.handles(cloudKitShareMetadata) {
            HearthHouseholdStore.shared.receive(cloudKitShareMetadata)
        }
    }
}
