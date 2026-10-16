import AppIntents
import Foundation
import SwiftData

// Siri and Shortcuts, hands-free in the car (and from the watch or a HomePod):
// "Check what needs my OK in Caloma", "What's coming up in Caloma", "Start driving in Caloma".

/// Reads the oldest request waiting for a parent's OK and asks "Approve it?".
struct ReviewApprovalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check What Needs My OK"
    static let description = IntentDescription("Hear the next chore or reward waiting for your OK, and approve it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try CalomaIntentError.context()
        let words = PointWords.current()
        let completions = Persistence.fetchAll(ChoreCompletion.self, in: context).filter { $0.status == .pending }.sorted { $0.completedAt < $1.completedAt }
        let redemptions = Persistence.fetchAll(Redemption.self, in: context).filter { $0.status == .pending }.sorted { $0.requestedAt < $1.requestedAt }
        let total = completions.count + redemptions.count
        guard total > 0 else { return .result(dialog: "Nothing needs your OK right now.") }
        let more = total > 1 ? " \(total - 1) more \(total - 1 == 1 ? "is" : "are") waiting." : ""

        // Oldest first, chores or rewards.
        if let completion = completions.first, redemptions.first.map({ completion.completedAt <= $0.requestedAt }) ?? true {
            let kid = Family.member(completion.memberID, in: context)?.name ?? "A kid"
            let chore = Family.chore(completion.choreID, in: context)?.title ?? "a chore"
            try await requestConfirmation(dialog: "\(kid) finished \(chore), for \(words.count(completion.points)). Approve it?")
            Family.approve(completion, in: context)
            return .result(dialog: "Approved. \(words.count(completion.points)) to \(kid).\(more)")
        }
        guard let redemption = redemptions.first else { return .result(dialog: "Nothing needs your OK right now.") }
        let kid = Family.member(redemption.memberID, in: context)?.name ?? "A kid"
        let reward = Family.reward(redemption.rewardID, in: context)?.name ?? "a reward"
        try await requestConfirmation(dialog: "\(kid) wants \(reward), for \(words.count(redemption.cost)). Approve it?")
        Family.approve(redemption, in: context)
        return .result(dialog: "Approved. \(kid) gets \(reward).\(more)")
    }
}

/// "Next: Piano with Max at 3:30, you're driving. Then soccer with Ella at 4:30, Dad drives."
struct ComingUpIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Coming Up"
    static let description = IntentDescription("Hear the family's next few events and who's driving.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try CalomaIntentError.context()
        let snapshot = WatchBridge.snapshot(in: context)
        let events = snapshot.upcoming().filter { !$0.isAllDay }.prefix(3)
        guard !events.isEmpty else { return .result(dialog: "Nothing's on the family calendar today or tomorrow.") }
        let sentences = events.enumerated().map { index, event in
            var sentence = (index == 0 ? "Next: " : "Then ") + event.title
            if event.who != "Everyone" { sentence += " with \(event.who)" }
            sentence += Calendar.current.isDateInToday(event.start) ? " at " : (Calendar.current.isDateInTomorrow(event.start) ? " tomorrow at " : " ")
            sentence += event.start.formatted(date: .omitted, time: .shortened)
            if event.youDrive { sentence += ", you're driving" } else if let driver = event.driver { sentence += ", \(driver) drives" }
            return sentence + "."
        }
        return .result(dialog: "\(sentences.joined(separator: " "))")
    }
}

/// Starts the "You're driving" Live Activity for the next event you're driving to. Made for a
/// Shortcuts automation, "When CarPlay connects", since Live Activities can't start on their
/// own while Caloma is closed.
struct StartDrivingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Driving"
    static let description = IntentDescription("Show the next event you're driving to on the Lock Screen and CarPlay, with what's packed.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try CalomaIntentError.context()
        guard let next = DrivingLiveActivity.nextDrive(in: context) else {
            return .result(dialog: "You're not driving to anything in the next two hours.")
        }
        await DrivingLiveActivity.refresh(in: context, allowStart: true)
        let missing = next.state.missing.map(\.name)
        let packed = missing.isEmpty ? (next.state.bring.isEmpty ? "" : " Everything's packed.") : " Still not packed: \(missing.formatted(.list(type: .and)))."
        return .result(dialog: "\(next.attributes.title) with \(next.attributes.who) at \(next.attributes.start.formatted(date: .omitted, time: .shortened)).\(packed)")
    }
}

struct CalomaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReviewApprovalsIntent(),
            phrases: [
                "Check what needs my OK in \(.applicationName)",
                "Check \(.applicationName) approvals",
                "What needs my OK in \(.applicationName)",
            ],
            shortTitle: "Needs Your OK",
            systemImageName: "checkmark.seal"
        )
        AppShortcut(
            intent: ComingUpIntent(),
            phrases: [
                "What's coming up in \(.applicationName)",
                "What's on the \(.applicationName) calendar",
            ],
            shortTitle: "Coming Up",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: StartDrivingIntent(),
            phrases: [
                "Start driving in \(.applicationName)",
                "I'm leaving in \(.applicationName)",
            ],
            shortTitle: "Start Driving",
            systemImageName: "car.fill"
        )
    }
}

enum CalomaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "Open Caloma once, then try again."
    }

    /// The app's store. Siri runs these in Caloma's own process, which sets it up at launch.
    @MainActor
    static func context() throws -> ModelContext {
        guard let container = AppRouter.shared.container else { throw CalomaIntentError.notReady }
        return container.mainContext
    }
}
