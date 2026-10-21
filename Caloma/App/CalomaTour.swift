import SwiftUI

/// Caloma's stops on the shared tour (HearthTour.swift): Home, Chores, Calendar, Rewards, then
/// More on iPhone (Control on iPad, where it's a tab of its own). It shows once after onboarding
/// and again from Profile › Take the Tour. Screens mark what each step points at with
/// `.hearthTourTarget(_:)`.
enum CalomaTour {
    static let home = "home"
    static let chores = "chores"
    static let calendar = "calendar"
    static let rewards = "rewards"
    static let more = "more"

    static func steps(regular: Bool) -> [HearthTourStep] {
        [
            HearthTourStep(home, title: "Home", message: "The family's day at a glance: each kid's chores, what's on the calendar, and dinner tonight from BigTable.", symbol: "house", color: .pink),
            HearthTourStep(chores, title: "Chores", message: "Give out chores once or on a schedule, and approve them when they're done. Kids check theirs off in Kid View.", symbol: "checklist", color: .green),
            HearthTourStep(calendar, title: "Calendar", message: "One calendar for the whole family, with everyone's color. Add events here or show your Apple calendars beside them.", symbol: "calendar", color: .blue),
            HearthTourStep(rewards, title: "Rewards", message: "What kids can spend their points on, and allowance on payday. Approve each one before it's theirs.", symbol: "gift", color: .orange),
            regular
                ? HearthTourStep(more, title: "Control", message: "Lights, locks, climate and cameras from Apple Home. Home Care and the Whiteboard are just below it.", symbol: "lightswitch.on", color: .teal)
                : HearthTourStep(more, title: "More", message: "Control your home, keep up with Home Care, draw on the Whiteboard, and find the family's lists.", symbol: "ellipsis", color: .teal),
        ]
    }

    static func tab(for step: HearthTourStep, regular: Bool) -> AppTab {
        switch step.id {
        case chores: .chores
        case calendar: .calendar
        case rewards: .rewards
        case more: regular ? .control : .more
        default: .home
        }
    }
}
