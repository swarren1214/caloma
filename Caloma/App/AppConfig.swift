import Foundation

/// App-wide settings.
enum AppConfig {
    /// The family's data syncs through the private CloudKit database. Needs the iCloud
    /// (CloudKit), Push Notifications and Background Modes › Remote notifications capabilities.
    /// When false, everything stays on this device.
    ///
    /// The private database belongs to one Apple Account. Two parents on two Apple Accounts
    /// need CloudKit sharing (see README › Sharing with your partner).
    static let cloudSyncEnabled = false
    static let cloudKitContainerID = "iCloud.com.stephenwarren.caloma"

    static let appName = "Caloma"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
