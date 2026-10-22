import Foundation
import SwiftData

/// Keeps Caloma's family (`Member`) in step with the Hearth household (`HearthHouseholdStore`).
/// Caloma always has a household (a household of one is fine), and people are only added or
/// edited there (`HearthPersonEditor`, `HearthHouseholdView`). The household is the source of
/// truth for names, roles, colors and photos; Caloma keeps everything that's only Caloma's
/// (points, chores, Kid View) on its own `Member`, linked through the household's
/// `appIDs["caloma"]` (or, when this phone's Caloma isn't the family's shared one, a link kept
/// on this device; see `linkHere`).
@MainActor
enum CalomaHousehold {
    /// The photo each member was last given from the household, so unchanged photos aren't
    /// copied again.
    private static let photoNamesKey = "hearth.household.calomaPhotos"
    /// The household Caloma's own members were brought into, once.
    private static let importedKey = "hearth.household.calomaImported"

    /// The household person for a Caloma member.
    static func person(for member: Member) -> HearthMember? {
        HearthHouseholdStore.shared.member(app: .caloma, appID: member.id.uuidString)
    }

    /// Brings Caloma's members in line with the household: everyone in the household gets a
    /// Caloma member. Call at launch, when the household changes, and after Caloma's own sync.
    static func sync(in context: ModelContext) {
        let store = HearthHouseholdStore.shared
        guard store.exists, !ScreenshotMode.isOn else { return }
        let members = Persistence.fetchAll(Member.self, in: context)
        let byID = Dictionary(members.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var photoNames = UserDefaults.standard.dictionary(forKey: photoNamesKey) as? [String: String] ?? [:]
        var changed = false

        let ids = Set(byID.keys)
        var claimed = Set(store.snapshot.members.compactMap { store.localID(of: $0, app: .caloma, among: ids) })
        for person in store.snapshot.members {
            let target: Member
            if let id = store.localID(of: person, app: .caloma, among: ids), let linked = byID[id] {
                target = linked
            } else {
                // Only someone who can edit everyone adds people, so two phones don't both make
                // one, and only once this device has the family's own Caloma data.
                guard !person.isArchived, store.canEditEveryone, CloudSync.shared.canAddPeople else { continue }
                if let linkedID = person.appID(.caloma) {
                    // Linked to a Caloma member this device doesn't have. It may just not have
                    // come down yet, so wait until iCloud has answered; after that it's missing
                    // (never uploaded, or erased) and Home would show no kids. It's made again
                    // under the same id, which is the same record everywhere, so the original
                    // arriving later is one member, not two (and everything on it comes from
                    // the household anyway). Chores and points keep pointing at it.
                    guard store.cloudLoaded, let id = UUID(uuidString: linkedID), !ids.contains(linkedID) else { continue }
                    target = Member(name: person.trimmedName, role: person.role == .kid ? .kid : .parent, color: kidColor(person.colorHex), sortOrder: person.sortOrder)
                    target.id = id
                    context.insert(target)
                    changed = true
                } else if let match = members.first(where: { !claimed.contains($0.id.uuidString) && !$0.isArchived && HearthNames.normalized($0.name) == HearthNames.normalized(person.name) }) {
                    target = match
                } else {
                    target = Member(name: person.trimmedName, role: person.role == .kid ? .kid : .parent, color: kidColor(person.colorHex), sortOrder: person.sortOrder)
                    context.insert(target)
                    changed = true
                }
                claimed.insert(target.id.uuidString)
                store.linkHere(person, app: .caloma, localID: target.id.uuidString)
            }
            if apply(person, to: target, photoNames: &photoNames) { changed = true }
        }

        // Once, when the household is new here: anyone Caloma had before the household who isn't
        // in it yet joins it. After that, people are only added in the household.
        let householdID = store.info?.id
        let imports = householdID != nil && UserDefaults.standard.string(forKey: importedKey) != householdID
            && !store.isMember && store.canEditEveryone && CloudSync.shared.canAddPeople
        if imports { UserDefaults.standard.set(householdID, forKey: importedKey) }
        for member in members where imports && !member.isArchived && !claimed.contains(member.id.uuidString) {
            // Someone the household already has by name: link them if they're free here, and
            // otherwise leave it (two phones may each have made one before seeing the other's).
            if let sameName = store.people.first(where: { HearthNames.normalized($0.name) == HearthNames.normalized(member.name) }) {
                if store.localID(of: sameName, app: .caloma, among: ids) == nil {
                    store.linkHere(sameName, app: .caloma, localID: member.id.uuidString)
                    claimed.insert(member.id.uuidString)
                }
                continue
            }
            let id = UUID().uuidString
            store.save(HearthMember(
                id: id,
                name: member.name,
                role: member.role == .kid ? .kid : .parent,
                colorHex: member.color.hex,
                photo: member.photoData.flatMap { HearthHouseholdPhotos.save($0, memberID: id) },
                appIDs: [HearthApp.caloma.rawValue: member.id.uuidString]
            ))
        }

        // Left over from a person the household folded into one (`mergeDuplicates`): a member
        // here with the same name as someone already linked to another member. Archive it, so
        // Caloma shows them once; its chores and points history stays.
        if store.canEditEveryone && CloudSync.shared.canAddPeople {
            for member in members where !member.isArchived && !claimed.contains(member.id.uuidString) {
                let key = HearthNames.normalized(member.name)
                let taken = store.people.contains { person in
                    HearthNames.normalized(person.name) == key
                        && store.localID(of: person, app: .caloma, among: ids).map { $0 != member.id.uuidString } == true
                }
                if taken {
                    member.isArchived = true
                    changed = true
                }
            }
        }

        UserDefaults.standard.set(photoNames, forKey: photoNamesKey)
        if changed { Persistence.save(context) }
        rememberMe(among: Persistence.fetchAll(Member.self, in: context))
    }

    /// Who's using this device in Caloma follows the household's "me" when Caloma doesn't know.
    private static func rememberMe(among members: [Member]) {
        let store = HearthHouseholdStore.shared
        let current = UserDefaults.standard.string(forKey: SettingsKey.currentMember) ?? ""
        guard !members.contains(where: { $0.id.uuidString == current }), let me = store.me,
              let id = store.localID(of: me, app: .caloma, among: Set(members.map(\.id.uuidString))) else { return }
        UserDefaults.standard.set(id, forKey: SettingsKey.currentMember)
    }

    /// Copies the household's version of someone onto Caloma's member. Returns whether
    /// anything changed.
    private static func apply(_ person: HearthMember, to member: Member, photoNames: inout [String: String]) -> Bool {
        var changed = false
        let name = person.trimmedName
        if !name.isEmpty, member.name != name { member.name = name; changed = true }
        let role: MemberRole = person.role == .kid ? .kid : .parent
        if member.role != role { member.role = role; changed = true }
        if member.color.hex != person.colorHex { member.color = kidColor(person.colorHex); changed = true }
        if member.isArchived != person.isArchived { member.isArchived = person.isArchived; changed = true }
        if member.sortOrder != person.sortOrder { member.sortOrder = person.sortOrder; changed = true }
        let key = member.id.uuidString
        if photoNames[key] != person.photo {
            member.photoData = person.photo.flatMap(Hearth.photo(named:))
            photoNames[key] = person.photo
            changed = true
        }
        return changed
    }

    /// Caloma's preset for a color when it is one, otherwise the exact color.
    static func kidColor(_ hex: UInt32) -> KidColor {
        KidColor.swatches.first { $0.hex == hex } ?? KidColor(hex: hex)
    }
}
