import HomeKit
import SwiftData

extension HomeBridge {
    /// The rooms in the family's Apple Home (the one Control and the Family Board use), in the
    /// Home app's order. Leaves out the "Default Room" HomeKit keeps for unassigned accessories.
    var homeRoomNames: [String] {
        _ = revision
        guard let home else { return [] }
        let catchAll = home.roomForEntireHome().uniqueIdentifier
        return home.rooms
            .filter { $0.uniqueIdentifier != catchAll }
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Family › Rooms › Import from Apple Home: the home's rooms become Caloma rooms, each with an
/// icon picked from its name (changeable like any room's).
nonisolated enum HomeRoomImport {
    /// Adds the rooms the family doesn't have yet (by name), after the ones they do. Returns how
    /// many were added.
    @discardableResult
    static func insert(_ names: [String], into context: ModelContext, existing: [Room]) -> Int {
        var taken = Set(existing.filter { !$0.isArchived }.map { $0.name.lowercased() })
        var order = (existing.map(\.sortOrder).max() ?? -1) + 1
        var added = 0
        for name in names where !taken.contains(name.lowercased()) {
            context.insert(Room(name: name, symbol: symbol(for: name), sortOrder: order))
            taken.insert(name.lowercased())
            order += 1
            added += 1
        }
        return added
    }

    /// An icon for a room from its name: "Master Bath" is a shower, "Ella's Room" a bed.
    /// Checked in order, so the more specific words win ("Guest Bath" is a bathroom, not a
    /// bedroom; "Family Room" is a living room).
    static func symbol(for name: String) -> String {
        let name = name.lowercased()
        let words = name.split { !$0.isLetter }.map(String.init)
        for (keys, symbol) in matches where keys.contains(where: { fits($0, name: name, words: words) }) {
            return symbol
        }
        return fallback
    }

    /// A phrase ("family room", "'s room") anywhere in the name; a single word at the start of
    /// one of its words, so "bath" finds "Bathroom" but "den" doesn't find "Garden".
    private static func fits(_ key: String, name: String, words: [String]) -> Bool {
        if key.contains(where: { !$0.isLetter }) { return name.contains(key) }
        return words.contains { $0.hasPrefix(key) }
    }

    static let fallback = "door.left.hand.closed"

    private static let matches: [(words: [String], symbol: String)] = [
        (["garage", "carport"], "door.garage.closed"),
        (["laundry", "utility"], "washer"),
        (["bath", "powder", "restroom", "shower", "toilet", "lavatory", "washroom"], "shower"),
        (["pantry"], "cabinet"),
        (["kitchen", "kitchenette"], "fork.knife"),
        (["dining", "breakfast nook"], "chair"),
        (["nursery", "baby"], "stroller"),
        (["play", "toy", "rec room", "game room"], "teddybear"),
        (["office", "study", "desk", "homework"], "desktopcomputer"),
        (["media", "theater", "theatre", "tv"], "tv"),
        (["living", "family room", "great room", "den", "lounge", "sitting", "parlor", "front room"], "sofa"),
        (["bed", "primary", "master", "guest", "suite", "kids", "'s room", "’s room", "s' room"], "bed.double"),
        (["gym", "workout", "exercise", "fitness"], "dumbbell"),
        (["closet", "wardrobe"], "hanger"),
        (["storage", "attic", "storeroom"], "shippingbox"),
        (["basement", "cellar", "downstairs", "upstairs", "stair", "loft"], "stairs"),
        (["mudroom", "mud room", "entry", "foyer", "hall", "vestibule"], "door.left.hand.open"),
        (["library", "reading"], "books.vertical"),
        (["craft", "art", "studio"], "paintpalette"),
        (["music"], "music.note"),
        (["workshop", "shed", "shop", "tool"], "hammer"),
        (["pool", "hot tub"], "figure.pool.swim"),
        (["patio", "deck", "porch", "balcony", "terrace", "sunroom", "veranda"], "chair.lounge"),
        (["driveway", "parking"], "car"),
        (["yard", "garden", "lawn", "outside", "outdoor", "exterior", "back", "front"], "leaf"),
    ]
}
