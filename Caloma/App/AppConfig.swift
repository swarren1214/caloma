import Foundation

/// App-wide settings.
enum AppConfig {
    /// The family's data syncs through CloudKit (see `CloudSync`), and can be shared with the
    /// other parent's Apple Account from Family › Family Sharing. Needs the iCloud (CloudKit),
    /// Push Notifications and Background Modes › Remote notifications capabilities. When false,
    /// everything stays on this device.
    static let cloudSyncEnabled = true
    static let cloudKitContainerID = "iCloud.com.stephenwarren.caloma"

    static let appName = "Caloma"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
