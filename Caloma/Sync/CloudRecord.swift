import CloudKit
import CryptoKit
import Foundation
import SwiftData

// How each model becomes a CloudKit record and back. Every record is named by the model's
// UUID and lives in the family's zone. Each field is written under its property name.
//
// Adding a stored property to a model? Add it to that model's write(to:) and read(from:) here
// too, or it won't sync.

@MainActor
protocol CloudRecord: PersistentModel {
    static var recordType: String { get }
    var id: UUID { get set }
    func write(to record: CKRecord)
    func read(from record: CKRecord)
    /// An empty model to read a new record into.
    static func blank() -> Self
}

/// Every synced model, in an order where things referred to come first.
enum SyncSchema {
    static let types: [any CloudRecord.Type] = [
        Member.self, Room.self, Chore.self, ChoreCompletion.self, Reward.self, Redemption.self,
        PointEntry.self, HomeTask.self, HomeTaskLog.self, FamilyEvent.self, EventPacking.self,
        FamilySetting.self, Whiteboard.self, WallNote.self, DeviceStyle.self,
    ]

    static func type(named name: String) -> (any CloudRecord.Type)? {
        types.first { $0.recordType == name }
    }
}

// MARK: - Reading and writing fields

extension CKRecord {
    func setUUID(_ value: UUID?, for key: String) {
        setObject(value.map { $0.uuidString as NSString }, forKey: key)
    }

    /// Photos go up as assets, from a temporary file.
    func setAsset(_ data: Data?, for key: String) {
        guard let data else {
            setObject(nil, forKey: key)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("caloma-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            setObject(CKAsset(fileURL: url), forKey: key)
        } catch {
            setObject(nil, forKey: key)
        }
    }

    func string(_ key: String) -> String? { object(forKey: key) as? String }
    func int(_ key: String) -> Int? { (object(forKey: key) as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool? { (object(forKey: key) as? NSNumber)?.boolValue }
    func date(_ key: String) -> Date? { object(forKey: key) as? Date }
    func uuid(_ key: String) -> UUID? { (object(forKey: key) as? String).flatMap(UUID.init(uuidString:)) }

    func asset(_ key: String) -> Data? {
        guard let url = (object(forKey: key) as? CKAsset)?.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Models

extension Member: CloudRecord {
    static let recordType = "Member"
    static func blank() -> Member { Member(name: "", role: .kid) }

    func write(to record: CKRecord) {
        record["name"] = name
        record["roleRaw"] = roleRaw
        record["colorRaw"] = colorRaw
        record.setAsset(photoData, for: "photo")
        record["sortOrder"] = sortOrder
        record["isArchived"] = isArchived
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        name = record.string("name") ?? name
        roleRaw = record.string("roleRaw") ?? roleRaw
        colorRaw = record.string("colorRaw") ?? colorRaw
        photoData = record.asset("photo")
        sortOrder = record.int("sortOrder") ?? sortOrder
        isArchived = record.bool("isArchived") ?? isArchived
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension Room: CloudRecord {
    static let recordType = "Room"
    static func blank() -> Room { Room(name: "", symbol: "door.left.hand.closed") }

    func write(to record: CKRecord) {
        record["name"] = name
        record["symbol"] = symbol
        record["sortOrder"] = sortOrder
        record["isArchived"] = isArchived
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        name = record.string("name") ?? name
        symbol = record.string("symbol") ?? symbol
        sortOrder = record.int("sortOrder") ?? sortOrder
        isArchived = record.bool("isArchived") ?? isArchived
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension Chore: CloudRecord {
    static let recordType = "Chore"
    static func blank() -> Chore { Chore(title: "", symbol: "checkmark.circle", points: 0) }

    func write(to record: CKRecord) {
        record["title"] = title
        record["symbol"] = symbol
        record["points"] = points
        record["assigneeIDsRaw"] = assigneeIDsRaw
        record["rotates"] = rotates
        record["upForGrabs"] = upForGrabs
        record["repeatRaw"] = repeatRaw
        record["weekdayMask"] = weekdayMask
        record["startDate"] = startDate
        record["dueMinutes"] = dueMinutes
        record["requiresPhoto"] = requiresPhoto
        record["requiresApproval"] = requiresApproval
        record.setUUID(homeTaskID, for: "homeTaskID")
        record.setUUID(roomID, for: "roomID")
        record.setUUID(eventID, for: "eventID")
        record["priorityRaw"] = priorityRaw
        record["isArchived"] = isArchived
        record["sortOrder"] = sortOrder
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        title = record.string("title") ?? title
        symbol = record.string("symbol") ?? symbol
        points = record.int("points") ?? points
        assigneeIDsRaw = record.string("assigneeIDsRaw") ?? assigneeIDsRaw
        rotates = record.bool("rotates") ?? rotates
        upForGrabs = record.bool("upForGrabs") ?? upForGrabs
        repeatRaw = record.string("repeatRaw") ?? repeatRaw
        weekdayMask = record.int("weekdayMask") ?? weekdayMask
        startDate = record.date("startDate") ?? startDate
        dueMinutes = record.int("dueMinutes") ?? dueMinutes
        requiresPhoto = record.bool("requiresPhoto") ?? requiresPhoto
        requiresApproval = record.bool("requiresApproval") ?? requiresApproval
        homeTaskID = record.uuid("homeTaskID")
        roomID = record.uuid("roomID")
        eventID = record.uuid("eventID")
        priorityRaw = record.int("priorityRaw") ?? priorityRaw
        isArchived = record.bool("isArchived") ?? isArchived
        sortOrder = record.int("sortOrder") ?? sortOrder
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension ChoreCompletion: CloudRecord {
    static let recordType = "ChoreCompletion"
    static func blank() -> ChoreCompletion { ChoreCompletion(choreID: UUID(), memberID: UUID(), day: .now, points: 0, status: .pending) }

    func write(to record: CKRecord) {
        record.setUUID(choreID, for: "choreID")
        record.setUUID(memberID, for: "memberID")
        record["day"] = day
        record["statusRaw"] = statusRaw
        record["points"] = points
        record["completedAt"] = completedAt
        record.setObject(reviewedAt.map { $0 as NSDate }, forKey: "reviewedAt")
        record.setAsset(photoData, for: "photo")
    }

    func read(from record: CKRecord) {
        choreID = record.uuid("choreID")
        memberID = record.uuid("memberID")
        day = record.date("day") ?? day
        statusRaw = record.string("statusRaw") ?? statusRaw
        points = record.int("points") ?? points
        completedAt = record.date("completedAt") ?? completedAt
        reviewedAt = record.date("reviewedAt")
        photoData = record.asset("photo")
    }
}

extension Reward: CloudRecord {
    static let recordType = "Reward"
    static func blank() -> Reward { Reward(name: "", symbol: "gift", kind: .privilege, cost: 0) }

    func write(to record: CKRecord) {
        record["name"] = name
        record["note"] = note
        record["symbol"] = symbol
        record["kindRaw"] = kindRaw
        record["cost"] = cost
        record["limitRaw"] = limitRaw
        record["eligibleIDsRaw"] = eligibleIDsRaw
        record["needsApproval"] = needsApproval
        record["isFamilyGoal"] = isFamilyGoal
        record["isArchived"] = isArchived
        record["sortOrder"] = sortOrder
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        name = record.string("name") ?? name
        note = record.string("note") ?? note
        symbol = record.string("symbol") ?? symbol
        kindRaw = record.string("kindRaw") ?? kindRaw
        cost = record.int("cost") ?? cost
        limitRaw = record.string("limitRaw") ?? limitRaw
        eligibleIDsRaw = record.string("eligibleIDsRaw") ?? eligibleIDsRaw
        needsApproval = record.bool("needsApproval") ?? needsApproval
        isFamilyGoal = record.bool("isFamilyGoal") ?? isFamilyGoal
        isArchived = record.bool("isArchived") ?? isArchived
        sortOrder = record.int("sortOrder") ?? sortOrder
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension Redemption: CloudRecord {
    static let recordType = "Redemption"
    static func blank() -> Redemption { Redemption(rewardID: UUID(), memberID: UUID(), cost: 0, status: .pending) }

    func write(to record: CKRecord) {
        record.setUUID(rewardID, for: "rewardID")
        record.setUUID(memberID, for: "memberID")
        record["cost"] = cost
        record["statusRaw"] = statusRaw
        record["requestedAt"] = requestedAt
        record.setObject(reviewedAt.map { $0 as NSDate }, forKey: "reviewedAt")
    }

    func read(from record: CKRecord) {
        rewardID = record.uuid("rewardID")
        memberID = record.uuid("memberID")
        cost = record.int("cost") ?? cost
        statusRaw = record.string("statusRaw") ?? statusRaw
        requestedAt = record.date("requestedAt") ?? requestedAt
        reviewedAt = record.date("reviewedAt")
    }
}

extension PointEntry: CloudRecord {
    static let recordType = "PointEntry"
    static func blank() -> PointEntry { PointEntry(memberID: UUID(), points: 0, kind: .adjustment) }

    func write(to record: CKRecord) {
        record.setUUID(memberID, for: "memberID")
        record["points"] = points
        record["kindRaw"] = kindRaw
        record.setUUID(refID, for: "refID")
        record["date"] = date
        record["note"] = note
    }

    func read(from record: CKRecord) {
        memberID = record.uuid("memberID")
        points = record.int("points") ?? points
        kindRaw = record.string("kindRaw") ?? kindRaw
        refID = record.uuid("refID")
        date = record.date("date") ?? date
        note = record.string("note") ?? note
    }
}

extension HomeTask: CloudRecord {
    static let recordType = "HomeTask"
    static func blank() -> HomeTask { HomeTask(name: "", symbol: "wrench.and.screwdriver", area: .other, intervalCount: 1, unit: .months, nextDue: .now) }

    func write(to record: CKRecord) {
        record["name"] = name
        record["symbol"] = symbol
        record["areaRaw"] = areaRaw
        record["intervalCount"] = intervalCount
        record["intervalUnitRaw"] = intervalUnitRaw
        record["nextDue"] = nextDue
        record["remindDaysBefore"] = remindDaysBefore
        record["location"] = location
        record["details"] = details
        record["notes"] = notes
        record["sourceKey"] = sourceKey
        record["isArchived"] = isArchived
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        name = record.string("name") ?? name
        symbol = record.string("symbol") ?? symbol
        areaRaw = record.string("areaRaw") ?? areaRaw
        intervalCount = record.int("intervalCount") ?? intervalCount
        intervalUnitRaw = record.string("intervalUnitRaw") ?? intervalUnitRaw
        nextDue = record.date("nextDue") ?? nextDue
        remindDaysBefore = record.int("remindDaysBefore") ?? remindDaysBefore
        location = record.string("location") ?? location
        details = record.string("details") ?? details
        notes = record.string("notes") ?? notes
        sourceKey = record.string("sourceKey") ?? sourceKey
        isArchived = record.bool("isArchived") ?? isArchived
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension HomeTaskLog: CloudRecord {
    static let recordType = "HomeTaskLog"
    static func blank() -> HomeTaskLog { HomeTaskLog(taskID: UUID(), memberID: nil, daysLate: 0) }

    func write(to record: CKRecord) {
        record.setUUID(taskID, for: "taskID")
        record.setUUID(memberID, for: "memberID")
        record["doneAt"] = doneAt
        record["daysLate"] = daysLate
        record.setObject(previousDue.map { $0 as NSDate }, forKey: "previousDue")
        record["note"] = note
    }

    func read(from record: CKRecord) {
        taskID = record.uuid("taskID")
        memberID = record.uuid("memberID")
        doneAt = record.date("doneAt") ?? doneAt
        daysLate = record.int("daysLate") ?? daysLate
        previousDue = record.date("previousDue")
        note = record.string("note") ?? note
    }
}

extension FamilyEvent: CloudRecord {
    static let recordType = "FamilyEvent"
    static func blank() -> FamilyEvent { FamilyEvent(title: "", start: .now, end: .now) }

    func write(to record: CKRecord) {
        record["title"] = title
        record["symbol"] = symbol
        record["location"] = location
        record["notes"] = notes
        record["start"] = start
        record["end"] = end
        record["isAllDay"] = isAllDay
        record["attendeeIDsRaw"] = attendeeIDsRaw
        record.setUUID(driverID, for: "driverID")
        record["repeatRaw"] = repeatRaw
        record["weekdayMask"] = weekdayMask
        record.setObject(repeatEnd.map { $0 as NSDate }, forKey: "repeatEnd")
        record["alertMinutes"] = alertMinutes
        record["bringRaw"] = bringRaw
        record["showInKidView"] = showInKidView
        record["countsDown"] = countsDown
        record.setUUID(getReadyChoreID, for: "getReadyChoreID")
        record["skippedDaysRaw"] = skippedDaysRaw
        record["isArchived"] = isArchived
        record["createdAt"] = createdAt
        record.setAsset(handwriting, for: "handwriting")
        record.setUUID(inkMemberID, for: "inkMemberID")
    }

    func read(from record: CKRecord) {
        handwriting = record.asset("handwriting")
        inkMemberID = record.uuid("inkMemberID")
        title = record.string("title") ?? title
        symbol = record.string("symbol") ?? symbol
        location = record.string("location") ?? location
        notes = record.string("notes") ?? notes
        start = record.date("start") ?? start
        end = record.date("end") ?? end
        isAllDay = record.bool("isAllDay") ?? isAllDay
        attendeeIDsRaw = record.string("attendeeIDsRaw") ?? attendeeIDsRaw
        driverID = record.uuid("driverID")
        repeatRaw = record.string("repeatRaw") ?? repeatRaw
        weekdayMask = record.int("weekdayMask") ?? weekdayMask
        repeatEnd = record.date("repeatEnd")
        alertMinutes = record.int("alertMinutes") ?? alertMinutes
        bringRaw = record.string("bringRaw") ?? bringRaw
        showInKidView = record.bool("showInKidView") ?? showInKidView
        countsDown = record.bool("countsDown") ?? countsDown
        getReadyChoreID = record.uuid("getReadyChoreID")
        skippedDaysRaw = record.string("skippedDaysRaw") ?? skippedDaysRaw
        isArchived = record.bool("isArchived") ?? isArchived
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension EventPacking: CloudRecord {
    static let recordType = "EventPacking"
    static func blank() -> EventPacking { EventPacking(eventID: UUID(), memberID: UUID(), day: .now) }

    func write(to record: CKRecord) {
        record.setUUID(eventID, for: "eventID")
        record.setUUID(memberID, for: "memberID")
        record["day"] = day
        record["packedRaw"] = packedRaw
    }

    func read(from record: CKRecord) {
        eventID = record.uuid("eventID")
        memberID = record.uuid("memberID")
        day = record.date("day") ?? day
        packedRaw = record.string("packedRaw") ?? packedRaw
    }
}

// MARK: - Family settings

/// One family-wide setting (what points are called, allowance, approvals), so both parents'
/// phones agree. Named by a UUID made from its key, so two phones never make two of the same.
@Model
final class FamilySetting {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var key: String = ""
    /// "b:1", "i:500", "s:stars".
    var value: String = ""
    var updatedAt: Date = Date.now

    init(key: String, value: String) {
        self.id = Self.id(for: key)
        self.key = key
        self.value = value
    }

    /// The same UUID for the same key on every device.
    nonisolated static func id(for key: String) -> UUID {
        let digest = Array(Insecure.MD5.hash(data: Data(("caloma.setting." + key).utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

extension FamilySetting: CloudRecord {
    static let recordType = "FamilySetting"
    static func blank() -> FamilySetting { FamilySetting(key: "", value: "") }

    func write(to record: CKRecord) {
        record["key"] = key
        record["value"] = value
        record["updatedAt"] = updatedAt
    }

    func read(from record: CKRecord) {
        key = record.string("key") ?? key
        value = record.string("value") ?? value
        updatedAt = record.date("updatedAt") ?? updatedAt
    }
}

// MARK: - Apple Pencil

extension Whiteboard: CloudRecord {
    static let recordType = "Whiteboard"
    static func blank() -> Whiteboard { Whiteboard(name: "") }

    func write(to record: CKRecord) {
        record["name"] = name
        // A cleared board goes up as no drawing at all.
        record.setAsset(drawing.isEmpty ? nil : drawing, for: "drawing")
        record["sortOrder"] = sortOrder
        record["updatedAt"] = updatedAt
        record["createdAt"] = createdAt
    }

    func read(from record: CKRecord) {
        name = record.string("name") ?? name
        drawing = record.asset("drawing") ?? Data()
        sortOrder = record.int("sortOrder") ?? sortOrder
        updatedAt = record.date("updatedAt") ?? updatedAt
        createdAt = record.date("createdAt") ?? createdAt
    }
}

extension WallNote: CloudRecord {
    static let recordType = "WallNote"
    static func blank() -> WallNote { WallNote(drawing: Data(), from: nil, audience: [], keep: .once) }

    func write(to record: CKRecord) {
        record.setAsset(drawing, for: "drawing")
        record.setUUID(fromMemberID, for: "fromMemberID")
        record["audienceIDsRaw"] = audienceIDsRaw
        record["keepRaw"] = keepRaw
        record["pinnedToWall"] = pinnedToWall
        record["seenByRaw"] = seenByRaw
        record["createdAt"] = createdAt
        record.setObject(expiresAt.map { $0 as NSDate }, forKey: "expiresAt")
        record.setUUID(replyToID, for: "replyToID")
    }

    func read(from record: CKRecord) {
        drawing = record.asset("drawing") ?? drawing
        fromMemberID = record.uuid("fromMemberID")
        audienceIDsRaw = record.string("audienceIDsRaw") ?? audienceIDsRaw
        keepRaw = record.string("keepRaw") ?? keepRaw
        pinnedToWall = record.bool("pinnedToWall") ?? pinnedToWall
        seenByRaw = record.string("seenByRaw") ?? seenByRaw
        createdAt = record.date("createdAt") ?? createdAt
        expiresAt = record.date("expiresAt")
        replyToID = record.uuid("replyToID")
    }
}

extension DeviceStyle: CloudRecord {
    static let recordType = "DeviceStyle"
    static func blank() -> DeviceStyle { DeviceStyle(homeID: "", serviceID: "", matchKey: "") }

    func write(to record: CKRecord) {
        record["homeID"] = homeID
        record["serviceID"] = serviceID
        record["matchKey"] = matchKey
        record["symbol"] = symbol
        record["colorHex"] = colorHex
        record["tileStyleRaw"] = tileStyleRaw
        record.setAsset(photoData, for: "photo")
        record["hidden"] = hidden
        record["kidsAllowed"] = kidsAllowed
        record["pinnedToHome"] = pinnedToHome
        record["sortOrder"] = sortOrder
        record["updatedAt"] = updatedAt
    }

    func read(from record: CKRecord) {
        homeID = record.string("homeID") ?? homeID
        serviceID = record.string("serviceID") ?? serviceID
        matchKey = record.string("matchKey") ?? matchKey
        symbol = record.string("symbol") ?? symbol
        colorHex = record.string("colorHex") ?? colorHex
        tileStyleRaw = record.string("tileStyleRaw") ?? tileStyleRaw
        photoData = record.asset("photo")
        hidden = record.bool("hidden") ?? hidden
        kidsAllowed = record.bool("kidsAllowed") ?? kidsAllowed
        pinnedToHome = record.bool("pinnedToHome") ?? pinnedToHome
        sortOrder = record.int("sortOrder") ?? sortOrder
        updatedAt = record.date("updatedAt") ?? updatedAt
    }
}
