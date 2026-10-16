import SwiftData
import SwiftUI

/// Brings the family's Apple Home rooms into Caloma's rooms, so New Chore can say where a
/// chore happens without anyone typing "Kitchen" twice. Each Apple Home room is added once:
/// a room the family already has (by name) is left alone, and one they deleted or archived
/// never comes back. Only runs once this device has let Caloma see Apple Home, so a chore
/// editor never asks for Home access by itself.
enum HomeRoomImport {
    /// Waits for Apple Home's rooms (a few seconds at most), then adds the new ones.
    static func run(in context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.homeKitAllowed) else { return }
        let bridge = HomeBridge.shared
        bridge.start()
        for _ in 0..<20 where bridge.home == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let home = bridge.home else { return }
        let names = home.rooms.map(\.name)
        guard !names.isEmpty else { return }

        let rooms = (try? context.fetch(FetchDescriptor<Room>())) ?? []
        let defaults = UserDefaults.standard
        let imported = Set(defaults.stringArray(forKey: SettingsKey.importedHomeRooms) ?? [])
        let adding = newRoomNames(home: names, existing: rooms.map(\.name), imported: imported)
        // Everything seen this time is remembered, added or not, so a room the family later
        // deletes stays deleted.
        defaults.set(Array(imported.union(names.map(key))), forKey: SettingsKey.importedHomeRooms)
        guard !adding.isEmpty else { return }

        var order = (rooms.map(\.sortOrder).max() ?? -1) + 1
        for name in adding {
            context.insert(Room(name: name, symbol: symbol(for: name), sortOrder: order))
            order += 1
        }
        try? context.save()
    }

    /// The Apple Home rooms to add: not already a Caloma room (any case, archived too), not
    /// added before, each once.
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

    /// An icon that fits the room's name, from the room symbols chores already use.
    nonisolated static func symbol(for name: String) -> String {
        let n = name.lowercased()
        let has = { (words: [String]) in words.contains { n.contains($0) } }
        if has(["kitchen", "pantry", "dining"]) { return "fork.knife" }
        if has(["nursery", "kid", "playroom", "play room", "toy"]) { return "teddybear" }
        if has(["bed", "primary", "master", "guest"]) { return "bed.double" }
        if has(["bath", "shower", "powder"]) { return "shower" }
        if has(["laundry", "utility", "mud"]) { return "washer" }
        if has(["garage"]) { return "door.garage.closed" }
        if has(["yard", "garden", "patio", "porch", "deck", "outside", "outdoor", "lawn", "back", "front"]) { return "leaf" }
        if has(["stair", "hall", "entry", "foyer"]) { return "stairs" }
        if has(["office", "study", "library", "den"]) { return "books.vertical" }
        if has(["living", "family", "great", "lounge", "basement", "media", "theater"]) { return "sofa" }
        return "door.left.hand.closed"
    }
}
