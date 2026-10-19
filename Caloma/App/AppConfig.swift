import Foundation

/// App-wide settings.
enum AppConfig {
    /// The family's data syncs through CloudKit (see `CloudSync`): the "Caloma" zone in the
    /// Hearth container, shared with the Hearth household. Needs the iCloud (CloudKit), Push
    /// Notifications and Background Modes › Remote notifications capabilities. When false,
    /// everything stays on this device.
    static let cloudSyncEnabled = true

    static let appName = "Caloma"

    /// RevenueCat's public Apple key for the "Hearth" project (one project for all five apps).
    /// Debug builds use the same key. While it's the placeholder, purchases aren't set up and
    /// everything paid stays locked (see `CalomaPlus.configure`).
    nonisolated static let revenueCatAPIKey = "appl_nusgAFYCQIJXWISlrqUdpjKoubN"

    /// The Hearth API (hearth-api), for a household organizer's plan.
    nonisolated static let apiBaseURL = URL(string: "https://api.hearthapps.com")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
