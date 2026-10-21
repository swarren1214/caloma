import HomeKit
import SwiftData
import SwiftUI

extension HomeBridge {
    /// The rooms in the family's Apple Home (the one Control and the Family Board use), in the
    /// Home app's order. Leaves out the "Default Room" HomeKit keeps for unassigned accessories.
    var homeRoomNames: [String] {
        _ = revision
        guard let home else { return [] }
        let catchAll = home.roomForEntireHome().uniqueIdentifier
        return home.rooms.filter { $0.uniqueIdentifier != catchAll }.map(\.name)
    }
}

/// Brings the family's Apple Home rooms into Caloma's rooms, so New Chore can say where a
/// chore happens without anyone typing "Kitchen" twice. Two ways in:
/// - `run(in:)`, on its own: each Apple Home room is added once. A room the family already has
///   (by name) is left alone, and one they deleted never comes back. Only runs once this device
///   has let Caloma see Apple Home, so a chore editor never asks for Home access by itself.
/// - `importNow`, from Profile › Rooms › Import from Apple Home: someone asked, so every Apple
///   Home room the family doesn't have right now is added, deleted ones included.
/// Each new room gets an icon from its name, changeable like any room's.
enum HomeRoomImport {
    /// Waits for Apple Home's rooms (a few seconds at most), then adds the new ones.
    static func run(in context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.homeKitAllowed) else { return }
        let bridge = HomeBridge.shared
        bridge.start()
        for _ in 0..<20 where bridge.home == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let names = bridge.homeRoomNames
        guard !names.isEmpty else { return }

        let rooms = (try? context.fetch(FetchDescriptor<Room>())) ?? []
        let defaults = UserDefaults.standard
        let imported = Set(defaults.stringArray(forKey: SettingsKey.importedHomeRooms) ?? [])
        let adding = newRoomNames(home: names, existing: rooms.map(\.name), imported: imported)
        // Everything seen this time is remembered, added or not, so a room the family later
        // deletes stays deleted.
        defaults.set(Array(imported.union(names.map(key))), forKey: SettingsKey.importedHomeRooms)
        guard !adding.isEmpty else { return }
        insert(adding, into: context, after: rooms)
        try? context.save()
    }

    /// Import from Apple Home: adds the rooms the family doesn't have now (archived ones don't
    /// count), and returns how many.
    @discardableResult
    static func importNow(_ names: [String], into context: ModelContext, existing: [Room]) -> Int {
        let current = existing.filter { !$0.isArchived }.map(\.name)
        let adding = newRoomNames(home: names, existing: current, imported: [])
        insert(adding, into: context, after: existing)
        // Remembered, so the automatic import doesn't add them a second time.
        let defaults = UserDefaults.standard
        let imported = Set(defaults.stringArray(forKey: SettingsKey.importedHomeRooms) ?? [])
        defaults.set(Array(imported.union(names.map(key))), forKey: SettingsKey.importedHomeRooms)
        return adding.count
    }

    private static func insert(_ names: [String], into context: ModelContext, after existing: [Room]) {
        var order = (existing.map(\.sortOrder).max() ?? -1) + 1
        for name in names {
            context.insert(Room(name: name, symbol: symbol(for: name), sortOrder: order))
            order += 1
        }
    }

    /// The Apple Home rooms to add: not already a Caloma room (any case), not added before,
    /// each once.
    nonisolated static func newRoomNames(home: [String], existing: [String], imported: Set<String>) -> [String] {
        var taken = Set(existing.map(key)).union(imported)
        var result: [String] = []
        for name in home {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(trimmed)
            guard !trimmed.isEmpty, !taken.contains(k) else { continue }
            taken.insert(k)
            result.append(trimmed)
        }
        return result
    }

    nonisolated static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Icons

    /// An icon for a room from its name: "Master Bath" is a shower, "Ella's Room" a bed.
    /// Checked in order, so the more specific words win ("Guest Bath" is a bathroom, not a
    /// bedroom; "Family Room" is a living room).
    nonisolated static func symbol(for name: String) -> String {
        let name = name.lowercased()
        let words = name.split { !$0.isLetter }.map(String.init)
        for (keys, symbol) in iconMatches where keys.contains(where: { fits($0, name: name, words: words) }) {
            return symbol
        }
        return "door.left.hand.closed"
    }

    /// A phrase ("family room", "'s room") anywhere in the name; a single word at the start of
    /// one of its words, so "bath" finds "Bathroom" but "den" doesn't find "Garden".
    nonisolated private static func fits(_ key: String, name: String, words: [String]) -> Bool {
        if key.contains(where: { !$0.isLetter }) { return name.contains(key) }
        return words.contains { $0.hasPrefix(key) }
    }

    nonisolated private static let iconMatches: [(keys: [String], symbol: String)] = [
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
