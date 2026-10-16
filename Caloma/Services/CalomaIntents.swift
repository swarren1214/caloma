import AppIntents
import Foundation
import SwiftData
import SwiftUI

// Siri and Shortcuts, hands-free in the car (and from the watch or a HomePod):
// "Check what needs my OK in Caloma", "What's coming up in Caloma", "Start driving in Caloma".

/// Goes through what's waiting for a parent's OK, oldest first, hands-free (in the car, on
/// the watch, on a HomePod): "Max finished Clean the bathroom sink, for 15 stars." Approve,
/// Send Back (or Decline, for a reward), or Later, which leaves the rest in Needs Your OK.
struct ReviewApprovalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check What Needs My OK"
    static let description = IntentDescription("Hear each chore or reward waiting for your OK, and approve it, send it back, or leave it for later.")
    static let openAppWhenRun = false

    /// One request at a time.
    private enum Waiting {
        case chore(ChoreCompletion)
        case reward(Redemption)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try CalomaIntentError.context()
        let words = PointWords.current()
        let completions = Persistence.fetchAll(ChoreCompletion.self, in: context).filter { $0.status == .pending }
        let redemptions = Persistence.fetchAll(Redemption.self, in: context).filter { $0.status == .pending }
        // Oldest first, chores and rewards together.
        let waiting: [(at: Date, item: Waiting)] = (completions.map { (at: $0.completedAt, item: Waiting.chore($0)) } + redemptions.map { (at: $0.requestedAt, item: Waiting.reward($0)) })
            .sorted { $0.at < $1.at }
        guard !waiting.isEmpty else { return .result(dialog: "Nothing needs your OK right now.") }

        let approve = IntentChoiceOption(title: "Approve", style: .default)
        let later = IntentChoiceOption(title: "Later", style: .default)
        var approved = 0
        var sentBack = 0
        var handled = 0
        for (index, entry) in waiting.enumerated() {
            let kid: String
            let question: String
            let card: ApprovalCard
            let refuse: IntentChoiceOption
            switch entry.item {
            case .chore(let completion):
                kid = Family.member(completion.memberID, in: context)?.name ?? "A kid"
                let chore = Family.chore(completion.choreID, in: context)?.title ?? "a chore"
                question = "\(kid) finished \(chore), for \(words.count(completion.points))."
                card = ApprovalCard(kid: kid, title: chore, detail: "+\(words.count(completion.points))", hasPhoto: completion.photoData != nil)
                refuse = IntentChoiceOption(title: "Send Back", style: .destructive)
            case .reward(let redemption):
                kid = Family.member(redemption.memberID, in: context)?.name ?? "A kid"
                let reward = Family.reward(redemption.rewardID, in: context)?.name ?? "a reward"
                question = "\(kid) wants \(reward), for \(words.count(redemption.cost))."
                card = ApprovalCard(kid: kid, title: reward, detail: words.count(redemption.cost), hasPhoto: false)
                refuse = IntentChoiceOption(title: "Decline", style: .destructive)
            }
            let lead = index == 0 ? (waiting.count == 1 ? "" : "\(waiting.count) need your OK. ") : "Next: "
            let choice = try await requestChoice(between: [approve, refuse, later], dialog: IntentDialog(stringLiteral: lead + question), view: card)
            if choice == later { break }
            handled += 1
            switch entry.item {
            case .chore(let completion):
                if choice == approve { Family.approve(completion, in: context); approved += 1 } else { Family.sendBack(completion, in: context); sentBack += 1 }
            case .reward(let redemption):
                if choice == approve { Family.approve(redemption, in: context); approved += 1 } else { Family.decline(redemption, in: context); sentBack += 1 }
            }
        }

        var parts: [String] = []
        if approved > 0 { parts.append(approved == 1 ? "Approved one" : "Approved \(approved)") }
        if sentBack > 0 { parts.append(sentBack == 1 ? "sent one back" : "sent \(sentBack) back") }
        let left = waiting.count - handled
        var summary = parts.isEmpty ? "OK." : parts.joined(separator: ", ") + "."
        summary = summary.prefix(1).uppercased() + summary.dropFirst()
        if left > 0 { summary += " \(left) \(left == 1 ? "is" : "are") still in Needs Your OK on your iPhone." } else { summary += " That's everything." }
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

/// What Siri shows beside the question, on CarPlay and the iPhone: who, what, and what it's worth.
private struct ApprovalCard: View {
    var kid: String
    var title: String
    var detail: String
    var hasPhoto: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(String(kid.prefix(1)))
                .font(.title2.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("NEEDS YOUR OK")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(kid) · \(detail)\(hasPhoto ? " · photo on your iPhone" : "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding()
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
