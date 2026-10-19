import CloudKit
import Foundation
import SwiftData
import SwiftUI

/// A set of chores that rotate together: "Kitchen" (dishes, counters, trash) passes from one
/// kid to the next each week. The group keeps the rotation; `Rotations.apply` copies it onto
/// each of its chores, so the board, the kiosk and the widgets only ever look at chores.
@Model
final class ChoreGroup {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "square.stack.3d.up"
    /// A palette id ("orange") or "#RRGGBB" (`HearthColorChoice`).
    var colorRaw: String = "orange"
    /// The room it was made from, if any (new chores in that room aren't added on their own).
    var roomID: UUID?
    /// The people in the rotation, in turn order, as comma-separated UUIDs.
    var memberIDsRaw: String = ""
    var modeRaw: String = RotationMode.turns.rawValue
    var periodRaw: String = RotationPeriod.week.rawValue
    /// The day a weekly rotation switches (1 Sunday … 7 Saturday), or 0 for the calendar's.
    var weekday: Int = 0
    /// Turn 0 is the one with this day in it: the first person in the order has it.
    var anchor: Date = Date.now
    /// Skipped, swapped and paused turns (`RotationAdjustments`).
    var adjustRaw: String = ""
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    init(name: String, symbol: String, colorRaw: String, sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.colorRaw = colorRaw
        self.sortOrder = sortOrder
    }

    var memberIDs: [UUID] {
        get { Chore.decode(memberIDsRaw) }
        set { memberIDsRaw = Chore.encode(newValue) }
    }

    var mode: RotationMode {
        get { RotationMode(rawValue: modeRaw) ?? .turns }
        set { modeRaw = newValue.rawValue }
    }

    var period: RotationPeriod {
        get { RotationPeriod(rawValue: periodRaw) ?? .week }
        set { periodRaw = newValue.rawValue }
    }

    var adjustments: RotationAdjustments {
        get { RotationAdjustments(raw: adjustRaw) }
        set { adjustRaw = newValue.raw }
    }

    var color: HearthColorChoice { HearthColorChoice(storage: colorRaw) }

    var rule: RotationRule {
        RotationRule(mode: mode, period: period, weekday: weekday, anchor: anchor, adjustments: adjustments)
    }
}

extension ChoreGroup: CloudRecord {
    static let recordType = "ChoreGroup"
    static func blank() -> ChoreGroup { ChoreGroup(name: "", symbol: "square.stack.3d.up", colorRaw: "orange") }

    func write(to record: CKRecord) {
        record["name"] = name
        record["symbol"] = symbol
        record["colorRaw"] = colorRaw
        record.setUUID(roomID, for: "roomID")
        record["memberIDsRaw"] = memberIDsRaw
        record["modeRaw"] = modeRaw
        record["periodRaw"] = periodRaw
        record["weekday"] = weekday
        record["anchor"] = anchor
        record["adjustRaw"] = adjustRaw
        record["sortOrder"] = sortOrder
        record["isArchived"] = isArchived
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        name = record.string("name") ?? name
        symbol = record.string("symbol") ?? symbol
        colorRaw = record.string("colorRaw") ?? colorRaw
        roomID = record.uuid("roomID")
        memberIDsRaw = record.string("memberIDsRaw") ?? memberIDsRaw
        modeRaw = record.string("modeRaw") ?? modeRaw
        periodRaw = record.string("periodRaw") ?? periodRaw
        weekday = record.int("weekday") ?? weekday
        anchor = record.date("anchor") ?? anchor
        adjustRaw = record.string("adjustRaw") ?? adjustRaw
        sortOrder = record.int("sortOrder") ?? sortOrder
        isArchived = record.bool("isArchived") ?? isArchived
        createdAt = record.date("createdAt") ?? createdAt
    }
}

// MARK: - One rotation, whichever kind

/// A rotation as the screens see it: a group, or a single chore that takes turns.
nonisolated struct RotationSummary: Identifiable, Hashable, Sendable {
    var id: UUID
    var isGroup: Bool
    var name: String
    var symbol: String
    /// The group's color; nil for a single chore (it shows in the family's accent).
    var colorHex: UInt32?
    var members: [UUID]
    var rule: RotationRule
    /// The chores in it, in slot order.
    var choreTitles: [String]

    /// Whose turn it is in a take-turns rotation (nil while paused, or when it's split up).
    func holder(ofPeriod index: Int) -> UUID? {
        guard rule.mode == .turns else { return nil }
        return RotationMath.person(ofPeriod: index, members: members, adjustments: rule.adjustments)
    }

    /// Who has each chore in a turn, in slot order.
    func assignments(ofPeriod index: Int) -> [[UUID]] {
        choreTitles.indices.map { slot in
            RotationMath.assignees(slot: slot, ofPeriod: index, members: members, rule: rule)
        }
    }

    /// The next turn (after `index`) that's this person's, within a year or so.
    func nextTurn(of member: UUID, after index: Int) -> Int? {
        guard rule.mode == .turns, members.contains(member) else { return nil }
        let limit = max(members.count * 3, 12)
        return (index + 1...index + limit).first { holder(ofPeriod: $0) == member }
    }
}

// MARK: - Keeping chores in step with their group

enum Rotations {
    /// Whether people skipping a turn make it up (they trade with the next person) or just miss it.
    static var makesUpSkips: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.rotationMakeUp) as? Bool ?? true
    }

    /// A slot past any group's end: chores joining a group get it, so they go last and the
    /// chores already in it keep who has them.
    static let joiningSlot = 100_000

    /// The chores in a group, in slot order.
    static func chores(in group: ChoreGroup, from all: [Chore]) -> [Chore] {
        all.filter { $0.groupID == group.id && !$0.isArchived }
            .sorted { ($0.rotationSlot, $0.createdAt) < ($1.rotationSlot, $1.createdAt) }
    }

    /// Puts a chore in a group, at the end.
    static func join(_ chore: Chore, to group: ChoreGroup) {
        guard chore.groupID != group.id else { return }
        chore.groupID = group.id
        chore.rotationSlot = joiningSlot
    }

    /// After a chore in a group is deleted: the rest close up, so nobody's left without one.
    static func choreLeft(_ chore: Chore, in context: ModelContext) {
        guard let groupID = chore.groupID else { return }
        var descriptor = FetchDescriptor<ChoreGroup>(predicate: #Predicate { $0.id == groupID })
        descriptor.fetchLimit = 1
        guard let group = try? context.fetch(descriptor).first else { return }
        let match: UUID? = groupID
        let all = (try? context.fetch(FetchDescriptor<Chore>(predicate: #Predicate { $0.groupID == match }))) ?? []
        apply(group, to: all)
    }

    /// Copies a group's rotation onto its chores.
    static func apply(_ group: ChoreGroup, to all: [Chore]) {
        let members = group.memberIDs
        for (slot, chore) in chores(in: group, from: all).enumerated() {
            if chore.assigneeIDs != members { chore.assigneeIDs = members }
            let rotates = group.mode != .everyone && members.count > 1
            if chore.rotates != rotates { chore.rotates = rotates }
            if chore.upForGrabs { chore.upForGrabs = false }
            if chore.rotationModeRaw != group.modeRaw { chore.rotationModeRaw = group.modeRaw }
            if chore.rotationPeriodRaw != group.periodRaw { chore.rotationPeriodRaw = group.periodRaw }
            if chore.rotationWeekday != group.weekday { chore.rotationWeekday = group.weekday }
            if chore.rotationAnchor != group.anchor { chore.rotationAnchor = group.anchor }
            if chore.rotationAdjustRaw != group.adjustRaw { chore.rotationAdjustRaw = group.adjustRaw }
            if chore.rotationSlot != slot { chore.rotationSlot = slot }
        }
    }

    /// Takes a group away. Its chores stay, rotating just as they were, each on its own.
    static func delete(_ group: ChoreGroup, chores all: [Chore]) {
        for chore in chores(in: group, from: all) { chore.groupID = nil }
        group.isArchived = true
    }

    /// Every rotation in the family: groups first, then single chores that take turns.
    static func summaries(groups: [ChoreGroup], chores all: [Chore]) -> [RotationSummary] {
        let live = groups.filter { !$0.isArchived }.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        let fromGroups = live.map { group in
            RotationSummary(
                id: group.id, isGroup: true, name: group.name, symbol: group.symbol, colorHex: group.color.hex,
                members: group.memberIDs, rule: group.rule, choreTitles: chores(in: group, from: all).map(\.title)
            )
        }
        let groupIDs = Set(live.map(\.id))
        let singles = all
            .filter { !$0.isArchived && $0.rotates && !$0.upForGrabs && $0.assigneeIDs.count > 1 && !($0.groupID.map(groupIDs.contains) ?? false) }
            .sorted { ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title) }
            .map { chore in
                RotationSummary(
                    id: chore.id, isGroup: false, name: chore.title, symbol: chore.symbol, colorHex: nil,
                    members: chore.assigneeIDs, rule: chore.record.rotationRule, choreTitles: [chore.title]
                )
            }
        return fromGroups + singles
    }

    /// Changes the skips, swaps and pauses of a rotation, group or single chore.
    static func setAdjustments(_ adjustments: RotationAdjustments, for summary: RotationSummary, groups: [ChoreGroup], chores all: [Chore]) {
        if summary.isGroup, let group = groups.first(where: { $0.id == summary.id }) {
            group.adjustments = adjustments
            apply(group, to: all)
        } else if let chore = all.first(where: { $0.id == summary.id }) {
            chore.rotationAdjustments = adjustments
        }
    }

    /// The anchor for a rotation that starts now: the first person in the order has this turn.
    static func freshAnchor(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }
}

extension RotationSummary {
    /// The color it shows in, given the family's accent for single chores.
    func tint(accent: Color) -> Color {
        colorHex.map(hearthPickerColor) ?? accent
    }
}
