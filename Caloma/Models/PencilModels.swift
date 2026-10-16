import Foundation
import SwiftData

/// A whiteboard: one drawing the family keeps going ("Fridge note", "Doodles"). Drawn with the
/// Apple Pencil on the wall iPad or any iPad. The drawing is PencilKit's own data.
@Model
final class Whiteboard {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    @Attribute(.externalStorage) var drawing: Data = Data()
    var sortOrder: Int = 0
    var updatedAt: Date = Date.now
    var createdAt: Date = Date.now

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }
}

/// How long a wall note keeps showing.
enum WallNoteKeep: String, CaseIterable, Identifiable {
    /// The next time they walk up, then it's done.
    case once
    /// Every time they walk up today.
    case today
    /// Every time they walk up, until someone erases it.
    case untilErased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: "Once"
        case .today: "Today"
        case .untilErased: "Until Erased"
        }
    }

    var detail: String {
        switch self {
        case .once: "The next time they walk up"
        case .today: "Every time they walk up today"
        case .untilErased: "Every time, until it's erased"
        }
    }
}

/// A note drawn on a whiteboard for someone, shown on the wall when they walk up (their face is
/// recognized or they tap their picture). It keeps its own copy of the drawing, so erasing the
/// board doesn't change a note nobody has seen yet.
@Model
final class WallNote {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    @Attribute(.externalStorage) var drawing: Data = Data()
    var fromMemberID: UUID?
    /// Who it's for, as comma-separated member UUIDs.
    var audienceIDsRaw: String = ""
    var keepRaw: String = WallNoteKeep.once.rawValue
    /// Also stays in the whiteboard's list of notes on the wall.
    var pinnedToWall: Bool = false
    /// Who has tapped Got it, as comma-separated member UUIDs.
    var seenByRaw: String = ""
    var createdAt: Date = Date.now
    /// End of the day it was sent, for Today notes.
    var expiresAt: Date?
    /// "Draw back": the note this answers.
    var replyToID: UUID?

    init(drawing: Data, from: UUID?, audience: [UUID], keep: WallNoteKeep, pinned: Bool = false, replyTo: UUID? = nil, now: Date = .now) {
        self.drawing = drawing
        self.fromMemberID = from
        self.audienceIDsRaw = Chore.encode(audience)
        self.keepRaw = keep.rawValue
        self.pinnedToWall = pinned
        self.replyToID = replyTo
        self.createdAt = now
        if keep == .today {
            let calendar = Calendar.current
            expiresAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        }
    }

    var audienceIDs: [UUID] {
        get { Chore.decode(audienceIDsRaw) }
        set { audienceIDsRaw = Chore.encode(newValue) }
    }

    var seenBy: [UUID] {
        get { Chore.decode(seenByRaw) }
        set { seenByRaw = Chore.encode(newValue) }
    }

    var keep: WallNoteKeep {
        get { WallNoteKeep(rawValue: keepRaw) ?? .once }
        set { keepRaw = newValue.rawValue }
    }
}

/// Which wall notes show for whom, and which are finished.
enum WallNoteQueue {
    /// Notes waiting for this person, newest first.
    static func pending(for memberID: UUID, in notes: [WallNote], now: Date = .now) -> [WallNote] {
        notes
            .filter { isPending($0, for: memberID, now: now) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func isPending(_ note: WallNote, for memberID: UUID, now: Date = .now) -> Bool {
        guard note.audienceIDs.contains(memberID) else { return false }
        if let expires = note.expiresAt, expires <= now { return false }
        switch note.keep {
        case .once: return !note.seenBy.contains(memberID)
        case .today, .untilErased: return true
        }
    }

    /// Nobody will see it again: every Once reader has seen it, or a Today note's day is over.
    static func isFinished(_ note: WallNote, now: Date = .now) -> Bool {
        switch note.keep {
        case .once:
            let seen = Set(note.seenBy)
            return !note.audienceIDs.isEmpty && note.audienceIDs.allSatisfy { seen.contains($0) } && !note.pinnedToWall
        case .today:
            return (note.expiresAt ?? .distantFuture) <= now && !note.pinnedToWall
        case .untilErased:
            return false
        }
    }

    /// Clears out finished notes, and anything over 30 days old that isn't kept until erased or
    /// pinned.
    static func sweep(_ notes: [WallNote], in context: ModelContext, now: Date = .now) {
        let old = now.addingTimeInterval(-30 * 24 * 3600)
        var removed = false
        for note in notes where isFinished(note, now: now) || (note.keep != .untilErased && !note.pinnedToWall && note.createdAt < old) {
            context.delete(note)
            removed = true
        }
        if removed { Persistence.save(context) }
    }
}
