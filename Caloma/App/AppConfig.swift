import Foundation

/// App-wide settings.
enum AppConfig {
    /// The family's data syncs through CloudKit (see `CloudSync`): the "Caloma" zone in the
    /// Hearth container, shared with the Hearth household. Needs the iCloud (CloudKit), Push
    /// Notifications and Background Modes › Remote notifications capabilities. When false,
    /// everything stays on this device.
    static let cloudSyncEnabled = true

    static let appName = "Caloma"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
