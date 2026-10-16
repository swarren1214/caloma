import CloudKit
import Foundation
import SwiftData

/// A list for something coming up: packing for a trip, getting ready for a party. Each thing
/// on it goes to one or more people, or to everyone (each packs their own), and shows up on
/// their own screens (Kid View and the Family Board) until it's done or the list is over.
@Model
final class FamilyList {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var title: String = ""
    /// The list's icon, and the icon for anything on it without its own.
    var symbol: String = "checklist"
    /// When it all needs to be ready by, if anyone said.
    var dueAt: Date?
    /// The calendar event it's for ("Bear Lake weekend"), if any.
    var eventID: UUID?
    /// When the list is over: the event's end, or the end of the day it's due.
    var endsAt: Date?
    /// Off everyone's screens once it's over.
    var clearsWhenOver: Bool = true
    /// Finished or cleared: off everyone's screens, and offered as a starting point next time.
    var isArchived: Bool = false
    var archivedAt: Date?
    var createdAt: Date = Date.now

    init(title: String, symbol: String = "checklist") {
        self.title = title
        self.symbol = symbol
    }
}

/// One thing on a list.
@Model
final class FamilyListItem {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var listID: UUID?
    var title: String = ""
    /// Its own icon, picked from its name. Empty: the list's.
    var symbol: String = ""
    /// Everyone brings their own (toothbrush, pajamas).
    var everyone: Bool = false
    /// Who's bringing it, as comma-separated member UUIDs. With more than one, either can.
    var assigneeIDsRaw: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(listID: UUID, title: String, everyone: Bool, assignees: [UUID], sortOrder: Int) {
        self.listID = listID
        self.title = title
        self.everyone = everyone
        self.assigneeIDsRaw = Chore.encode(assignees)
        self.sortOrder = sortOrder
    }

    var assigneeIDs: [UUID] {
        get { Chore.decode(assigneeIDsRaw) }
        set { assigneeIDsRaw = Chore.encode(newValue) }
    }

}

/// One person checking off one thing. A record each, rather than a field on the item, so two
/// kids ticking "Toothbrush" on different iPads at once both count when they sync.
@Model
final class FamilyListCheck {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var itemID: UUID?
    var memberID: UUID?
    var createdAt: Date = Date.now

    init(itemID: UUID, memberID: UUID) {
        self.itemID = itemID
        self.memberID = memberID
    }
}

// MARK: - Sync

extension FamilyList: CloudRecord {
    static let recordType = "FamilyList"
    static func blank() -> FamilyList { FamilyList(title: "") }

    func write(to record: CKRecord) {
        record["title"] = title
        record["symbol"] = symbol
        record.setObject(dueAt.map { $0 as NSDate }, forKey: "dueAt")
        record.setUUID(eventID, for: "eventID")
        record.setObject(endsAt.map { $0 as NSDate }, forKey: "endsAt")
        record["clearsWhenOver"] = clearsWhenOver
        record["isArchived"] = isArchived
        record.setObject(archivedAt.map { $0 as NSDate }, forKey: "archivedAt")
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        title = record.string("title") ?? title
        symbol = record.string("symbol") ?? symbol
        dueAt = record.date("dueAt")
        eventID = record.uuid("eventID")
        endsAt = record.date("endsAt")
        clearsWhenOver = record.bool("clearsWhenOver") ?? clearsWhenOver
        isArchived = record.bool("isArchived") ?? isArchived
        archivedAt = record.date("archivedAt")
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension FamilyListItem: CloudRecord {
    static let recordType = "FamilyListItem"
    static func blank() -> FamilyListItem { FamilyListItem(listID: UUID(), title: "", everyone: false, assignees: [], sortOrder: 0) }

    func write(to record: CKRecord) {
        record.setUUID(listID, for: "listID")
        record["title"] = title
        record["symbol"] = symbol
        record["everyone"] = everyone
        record["assigneeIDsRaw"] = assigneeIDsRaw
        record["sortOrder"] = sortOrder
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        listID = record.uuid("listID")
        title = record.string("title") ?? title
        symbol = record.string("symbol") ?? symbol
        everyone = record.bool("everyone") ?? everyone
        assigneeIDsRaw = record.string("assigneeIDsRaw") ?? assigneeIDsRaw
        sortOrder = record.int("sortOrder") ?? sortOrder
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension FamilyListCheck: CloudRecord {
    static let recordType = "FamilyListCheck"
    static func blank() -> FamilyListCheck { FamilyListCheck(itemID: UUID(), memberID: UUID()) }

    func write(to record: CKRecord) {
        record.setUUID(itemID, for: "itemID")
        record.setUUID(memberID, for: "memberID")
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        itemID = record.uuid("itemID")
        memberID = record.uuid("memberID")
        createdAt = record.date("createdAt") ?? createdAt
    }
}
