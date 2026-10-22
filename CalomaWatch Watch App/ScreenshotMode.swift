import Foundation

/// Screenshot mode, for marketing screenshots of the watch (the shared screenshots script).
///
/// Launched with `-Screenshots`, the watch shows the demo family from the iPhone app's
/// screenshot mode (the Parkers, as Laura sees them) from memory. It leaves the iPhone
/// connection, notifications and widgets alone and never reads or saves the snapshot, so this
/// simulator's own family is never touched. Adding `-Screen <name>` opens one page (see
/// `Screen`). Debug builds only: Release ignores the arguments, so none of this can be reached
/// in the App Store build.
enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The pages the script captures, in order, by the name passed after `-Screen`.
    enum Screen: String, CaseIterable {
        case approvals, comingup, kids, chores, homecare

        var page: WatchPage {
            switch self {
            case .approvals: .approvals
            case .comingup: .comingUp
            case .kids: .kids
            case .chores: .myChores
            case .homecare: .homeCare
            }
        }
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// The page to open at launch, or nil to open as usual.
    static var page: WatchPage? { screen?.page }

    /// Ella, as on the iPhone's demo family.
    private static let demoKidID = UUID(uuidString: "3E1A2C4B-0D5F-4A6E-9B7C-1E2F3A4B5C6D")!
    /// Replace HVAC filter, as on the iPhone's demo family.
    private static let demoHomeTaskID = UUID(uuidString: "A4C3B2D1-9E8F-4A7B-8C6D-5E4F3A2B1C0D")!

    /// The Parkers on Laura's watch: four things waiting for an OK, Theo's piano lesson coming
    /// up with Laura driving, the kids' day part done, Laura's own chores and the HVAC filter
    /// running late. Dates are relative to `now`, so it always looks current.
    static func snapshot(now: Date = .now, calendar: Calendar = .current) -> WatchSnapshot {
        let today = calendar.startOfDay(for: now)
        // The next five-minute mark, so event times read like real ones (3:45, not 3:43).
        let soon = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 300).rounded(.up) * 300)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        func at(_ date: Date, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        func ago(_ minutes: Int) -> Date { now.addingTimeInterval(-Double(minutes) * 60) }

        let accent = WatchSnapshot().accent
        let ella: UInt32 = 0xAF52DE, theo: UInt32 = 0x0A84FF, june: UInt32 = 0xFF9F0A
        let theoID = UUID(), juneID = UUID()

        var snapshot = WatchSnapshot(made: now, accent: accent, pointWord: "stars")

        snapshot.approvals = [
            .init(id: UUID(), kind: .chore, kidID: demoKidID, kidName: "Ella", kidColor: ella, title: "Unload the dishwasher", points: 10, photo: nil, at: ago(140)),
            .init(id: UUID(), kind: .chore, kidID: theoID, kidName: "Theo", kidColor: theo, title: "Practice piano 20 min", points: 15, photo: nil, at: ago(104)),
            .init(id: UUID(), kind: .chore, kidID: juneID, kidName: "June", kidColor: june, title: "Set the table", points: 5, photo: nil, at: ago(68)),
            .init(id: UUID(), kind: .reward, kidID: juneID, kidName: "June", kidColor: june, title: "Pick Friday Dinner", points: 60, photo: nil, at: ago(31)),
        ]

        func event(_ title: String, start: Date, minutes: Int, who: String, color: UInt32, location: String, driver: String? = nil, bring: [String] = []) -> WatchSnapshot.Event {
            WatchSnapshot.Event(
                id: "\(title)@\(start.timeIntervalSinceReferenceDate)", title: title, start: start,
                end: start.addingTimeInterval(Double(minutes) * 60), isAllDay: false, who: who, color: color,
                location: location, driver: driver, youDrive: driver == "Laura", bring: bring
            )
        }
        let piano = soon.addingTimeInterval(20 * 60)
        snapshot.events = [
            event("Piano lesson", start: piano, minutes: 45, who: "Theo", color: theo, location: "Harmony Music Studio", driver: "Laura", bring: ["Piano books"]),
            event("Soccer practice", start: piano.addingTimeInterval(90 * 60), minutes: 75, who: "Ella", color: ella, location: "Riverside Park · Field 3", driver: "Dan", bring: ["Cleats", "Shin guards", "Water bottle"]),
            event("Dentist checkup", start: at(day(1), 16), minutes: 45, who: "June", color: june, location: "Bright Smiles Dental", driver: "Dan"),
            event("Movie night", start: at(day(2), 19), minutes: 120, who: "Everyone", color: accent, location: "Living room", bring: ["Blankets", "Pillows"]),
        ].sorted { $0.start < $1.start }

        snapshot.dinner = WatchSnapshot.Dinner(day: today, title: "Sheet-Pan Fajitas + Rice", symbol: "fork.knife")

        snapshot.kids = [
            .init(id: demoKidID, name: "Ella", color: ella, done: 2, total: 5, balance: 145),
            .init(id: theoID, name: "Theo", color: theo, done: 2, total: 4, balance: 85),
            .init(id: juneID, name: "June", color: june, done: 3, total: 3, balance: 120),
        ]

        snapshot.myChores = [
            .init(choreID: UUID(), title: "Pack school lunches", symbol: "takeoutbag.and.cup.and.straw", done: true),
            .init(choreID: UUID(), title: "Start a load of laundry", symbol: "washer", done: true),
            .init(choreID: UUID(), title: "Sign Ella's field trip form", symbol: "signature", done: false),
            .init(choreID: UUID(), title: "Water the garden", symbol: "leaf", done: false),
        ]

        snapshot.homeCare = [
            .init(id: demoHomeTaskID, name: "Replace HVAC filter", symbol: "fan", due: day(-3), location: "Upstairs hallway", details: "16×25×1 MERV 11"),
            .init(id: UUID(), name: "Test smoke detectors", symbol: "light.beacon.max", due: day(2), location: "Every floor"),
        ]
        return snapshot
    }
}
