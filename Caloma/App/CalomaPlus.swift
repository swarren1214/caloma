import SwiftUI

/// Caloma Plus, or Hearth+ (every Hearth app): what's paid in Caloma, and the gate in front of it.
/// See MONETIZATION.md in hearthkit and `HearthPurchases` / `HearthPaywall` (Services/Hearth).
///
/// Free, always: the family calendar with Apple Calendar, chores, rotations and approvals, lists,
/// meals, rewards, Kid View on phones, unlimited kids, iCloud sync.
/// Paid (Caloma Plus or Hearth+): the Family Board (Kiosk Mode) on iPad, Home Control, Home Care,
/// and Apple Pencil (the whiteboard, wall notes and handwritten events).
/// Hearth+ only (the apps working together): BigTable's planned meals and Hearken's daily reading
/// on Caloma's calendar and wall (gated in `HearthLink`).
enum CalomaPlus {
    /// The RevenueCat key until Steve fills in the real one; nothing is configured with it.
    static let placeholderKey = "REVENUECAT_PUBLIC_KEY"

    /// This app's paid tier (Caloma Plus or Hearth+).
    static var isUnlocked: Bool { HearthPurchases.shared.isUnlocked }
    /// Hearth+: the other Hearth apps' data in Caloma.
    static var hasHearthPlus: Bool { HearthPurchases.shared.hasHearthPlus }

    /// At launch, before anything reads a plan. Caloma has no Hearth API sign-in, so there's no
    /// access token; HearthPurchases still follows the shared Hearth sign-in on its own.
    static func configure() {
        let purchases = HearthPurchases.shared
        // Marketing screenshots show everything.
        if ScreenshotMode.isOn { purchases.previewUnlocked = true }
        guard AppConfig.revenueCatAPIKey != placeholderKey else { return }
        purchases.configure(
            app: .caloma,
            apiKey: AppConfig.revenueCatAPIKey,
            apiBaseURL: AppConfig.apiBaseURL,
            accessToken: nil,
            signInButton: nil
        )
    }

    // MARK: What's paid, as the locked card and the paywall name it

    static let familyBoard = HearthPaywallFeature(
        "The Family Board",
        detail: "Hang an iPad on the wall: the week for everyone, a tap on a face for their chores, the doorbell and notes.",
        symbol: "rectangle.inset.filled.and.person.filled"
    )
    static let homeControl = HearthPaywallFeature(
        "Home Control",
        detail: "Lights, locks, climate and cameras from Apple Home, next to the family's day.",
        symbol: "lightswitch.on"
    )
    static let homeCare = HearthPaywallFeature(
        "Home Care",
        detail: "Filters, smoke detectors and gutters on a schedule, with reminders before each is due.",
        symbol: "wrench.and.screwdriver"
    )
    static let whiteboard = HearthPaywallFeature(
        "The Pencil whiteboard",
        detail: "Draw, plan and leave handwritten notes for the family with Apple Pencil.",
        symbol: "applepencil.and.scribble"
    )
    static let handwriting = HearthPaywallFeature(
        "Handwritten events",
        detail: "Write an event with Apple Pencil and Caloma reads the title and time.",
        symbol: "applepencil.and.scribble"
    )
}

/// A paid screen (a tab, or a card under More): the screen when it's unlocked, otherwise the
/// locked card where it would be.
struct CalomaPlusGate<Content: View>: View {
    var feature: HearthPaywallFeature
    var title: String
    var content: Content

    init(_ feature: HearthPaywallFeature, title: String, @ViewBuilder content: () -> Content) {
        self.feature = feature
        self.title = title
        self.content = content()
    }

    var body: some View {
        if CalomaPlus.isUnlocked {
            content
        } else {
            ScrollView {
                HearthLockedCard(feature: feature)
                    .frame(maxWidth: 560)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
        }
    }
}

/// The wall iPad when the plan behind the Family Board has ended: the locked card, and the
/// usual parent-PIN way out. Waits a moment first, so a board that opens at launch doesn't flash
/// this before the plan has loaded.
struct KioskLockedView: View {
    @Environment(AppRouter.self) private var router
    @State private var ready = false
    @State private var leaving = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if ready {
                ScrollView {
                    VStack(spacing: 20) {
                        HearthLockedCard(feature: CalomaPlus.familyBoard)
                            .frame(maxWidth: 560)
                        Button("Leave the Family Board") { leaving = true }
                            .buttonStyle(.glass)
                            .tint(.primary)
                            .controlSize(.large)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.center)
                .transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .animation(.smooth, value: ready)
        .task {
            try? await Task.sleep(for: .seconds(2))
            ready = true
        }
        .sheet(isPresented: $leaving) {
            LeaveKioskSheet {
                leaving = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    router.kioskOpen = false
                }
            }
            .presentationDetents([.large])
        }
    }
}
