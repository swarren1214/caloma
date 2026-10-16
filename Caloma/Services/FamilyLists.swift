import Foundation
import FoundationModels
import OSLog
import SwiftData

/// The rules for lists: who has what, what's done, and when a list is over. Views read lists,
/// items and check-offs through `@Query` and come here for everything else.
enum FamilyLists {
    // MARK: Who has what

    /// The people an item is for: everyone in the family for an "everyone" item, else whoever
    /// it was given to (still in the family).
    static func people(for item: FamilyListItem, members: [Member]) -> [Member] {
        let family = members.filter { !$0.isArchived }
        if item.everyone { return family }
        let ids = item.assigneeIDs
        return family.filter { ids.contains($0.id) }
    }

    /// Whether this person has the item on their list.
    static func isAssigned(_ item: FamilyListItem, to memberID: UUID) -> Bool {
        item.everyone || item.assigneeIDs.contains(memberID)
    }

    /// Who has checked the item off.
    static func doneBy(_ item: FamilyListItem, checks: [FamilyListCheck]) -> [UUID] {
        checks.filter { $0.itemID == item.id }.compactMap(\.memberID)
    }

    /// Done for this person: their own copy of an "everyone" item, or anyone's tick on a
    /// shared one (two people given the tent means either can bring it).
    static func isDone(_ item: FamilyListItem, for memberID: UUID, checks: [FamilyListCheck]) -> Bool {
        if item.everyone {
            return checks.contains { $0.itemID == item.id && $0.memberID == memberID }
        }
        return checks.contains { $0.itemID == item.id }
    }

    /// Everything on a list, in order.
    static func items(of list: FamilyList, in all: [FamilyListItem]) -> [FamilyListItem] {
        all.filter { $0.listID == list.id }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    /// One person's part of a list, in order.
    static func items(of list: FamilyList, for memberID: UUID, in all: [FamilyListItem]) -> [FamilyListItem] {
        items(of: list, in: all).filter { isAssigned($0, to: memberID) }
    }

    /// (done, total) for one person.
    static func progress(of list: FamilyList, for memberID: UUID, in all: [FamilyListItem], checks: [FamilyListCheck]) -> (done: Int, total: Int) {
        let mine = items(of: list, for: memberID, in: all)
        return (mine.filter { isDone($0, for: memberID, checks: checks) }.count, mine.count)
    }

    /// (done, total) for the whole family: an "everyone" item counts once per person. Things
    /// given only to someone who's left the family don't count.
    static func progress(of list: FamilyList, in all: [FamilyListItem], checks: [FamilyListCheck], members: [Member]) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for item in items(of: list, in: all) {
            let people = people(for: item, members: members)
            guard !people.isEmpty else { continue }
            if item.everyone {
                total += people.count
                done += people.filter { isDone(item, for: $0.id, checks: checks) }.count
            } else {
                total += 1
                if isDone(item, for: people[0].id, checks: checks) { done += 1 }
            }
        }
        return (done, total)
    }

    // MARK: Which lists are showing

    /// Lists still on everyone's screens, soonest first.
    static func active(_ lists: [FamilyList], now: Date = .now) -> [FamilyList] {
        lists.filter { isActive($0, now: now) }
            .sorted { ($0.dueAt ?? .distantFuture, $0.createdAt) < ($1.dueAt ?? .distantFuture, $1.createdAt) }
    }

    static func isActive(_ list: FamilyList, now: Date = .now) -> Bool {
        guard !list.isArchived else { return false }
        if list.clearsWhenOver, let end = list.endsAt, end <= now { return false }
        return true
    }

    /// One list with something on a person's screen, and how many of their things are left.
    struct PersonList: Identifiable {
        var list: FamilyList
        var left: Int
        var id: UUID { list.id }
    }

    /// The lists with something on this person's screen.
    static func lists(for memberID: UUID, lists: [FamilyList], items: [FamilyListItem], checks: [FamilyListCheck], now: Date = .now) -> [PersonList] {
        active(lists, now: now).compactMap { list in
            let progress = progress(of: list, for: memberID, in: items, checks: checks)
            return progress.total == 0 ? nil : PersonList(list: list, left: progress.total - progress.done)
        }
    }

    /// When a list is over: the event's end, else the start of the day after it's due.
    static func end(dueAt: Date?, eventEnd: Date?, calendar: Calendar = .current) -> Date? {
        if let eventEnd { return eventEnd }
        guard let dueAt else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dueAt))
    }

    // MARK: Changes

    /// Checks it off for this person, or un-checks it.
    static func toggle(_ item: FamilyListItem, for memberID: UUID, in context: ModelContext) {
        let itemID: UUID? = item.id
        let checks = (try? context.fetch(FetchDescriptor<FamilyListCheck>(predicate: #Predicate { $0.itemID == itemID }))) ?? []
        if item.everyone {
            let mine = checks.filter { $0.memberID == memberID }
            if mine.isEmpty {
                context.insert(FamilyListCheck(itemID: item.id, memberID: memberID))
            } else {
                mine.forEach(context.delete)
            }
        } else if checks.isEmpty {
            context.insert(FamilyListCheck(itemID: item.id, memberID: memberID))
        } else {
            // Shared: one tap undoes it, whoever ticked it.
            checks.forEach(context.delete)
        }
        Persistence.save(context)
    }

    /// After an item is given to different people: check-offs by anyone it's no longer for go.
    /// Doesn't save.
    static func dropChecks(on item: FamilyListItem, keeping people: [UUID], in context: ModelContext) {
        let itemID: UUID? = item.id
        let checks = (try? context.fetch(FetchDescriptor<FamilyListCheck>(predicate: #Predicate { $0.itemID == itemID }))) ?? []
        for check in checks {
            guard let member = check.memberID, people.contains(member) else {
                context.delete(check)
                continue
            }
        }
    }

    /// Lists that are over move to the finished pile. Runs when the app opens.
    static func clearFinished(in context: ModelContext, now: Date = .now) {
        let lists = Persistence.fetchAll(FamilyList.self, in: context).filter { !$0.isArchived && $0.clearsWhenOver }
        var changed = false
        for list in lists {
            if let end = list.endsAt, end <= now {
                list.isArchived = true
                list.archivedAt = now
                changed = true
            }
        }
        if changed { Persistence.save(context) }
    }

    /// Done with it now: off everyone's screens, kept as a starting point.
    static func finish(_ list: FamilyList, in context: ModelContext, now: Date = .now) {
        list.isArchived = true
        list.archivedAt = now
        Persistence.save(context)
    }

    /// Deletes a list, everything on it, and every check-off.
    static func delete(_ list: FamilyList, in context: ModelContext) {
        let listID: UUID? = list.id
        let items = (try? context.fetch(FetchDescriptor<FamilyListItem>(predicate: #Predicate { $0.listID == listID }))) ?? []
        for item in items { delete(item, in: context) }
        context.delete(list)
        Persistence.save(context)
    }

    /// Deletes one thing and its check-offs. Doesn't save.
    static func delete(_ item: FamilyListItem, in context: ModelContext) {
        let itemID: UUID? = item.id
        let checks = (try? context.fetch(FetchDescriptor<FamilyListCheck>(predicate: #Predicate { $0.itemID == itemID }))) ?? []
        checks.forEach(context.delete)
        context.delete(item)
    }

    /// Finished lists, most recent first, one per name: "start from a list you've used".
    static func reusable(_ lists: [FamilyList], now: Date = .now) -> [FamilyList] {
        var seen = Set<String>()
        return lists.filter { !isActive($0, now: now) }
            .sorted { ($0.archivedAt ?? $0.endsAt ?? $0.createdAt) > ($1.archivedAt ?? $1.endsAt ?? $1.createdAt) }
            .filter { seen.insert($0.title.lowercased().trimmingCharacters(in: .whitespaces)).inserted }
    }
}

// MARK: - Icons

/// Picks an icon for a list item from its name, so nobody has to choose one for "Toothbrush".
/// First the icon library's own search words, whole words only; then, where Apple Intelligence
/// is on, the on-device model picks from the same library. Nothing fits: the list's icon.
enum ListItemIcon {
    private static let log = Logger(subsystem: "com.stephenwarren.caloma", category: "lists")
    /// A library icon with a search word that's one of the name's words, or nil.
    static func keywordMatch(for title: String) -> String? {
        IconLibrary.suggestions(for: title).first
    }

    /// The on-device model's pick from the icon library, or nil when it's off or unsure.
    static func modelMatch(for title: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let names = IconLibrary.all.map(\.name)
        let session = LanguageModelSession(instructions: """
            You pick an SF Symbol name for an item on a family's packing or to-do list. Answer \
            with exactly one name from this list and nothing else, or NONE if nothing fits: \
            \(names.joined(separator: ", "))
            """)
        do {
            let response = try await session.respond(to: "Item: \(title)")
            let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'")))
            return names.contains(answer) ? answer : nil
        } catch {
            log.info("No icon from the on-device model: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Fills in an item's icon. Leaves it empty (the list's icon) when nothing fits.
    static func assign(to item: FamilyListItem, in context: ModelContext) {
        guard item.symbol.isEmpty else { return }
        if let match = keywordMatch(for: item.title) {
            item.symbol = match
            Persistence.save(context)
            return
        }
        let title = item.title
        Task { @MainActor in
            guard let match = await modelMatch(for: title), item.modelContext != nil, item.symbol.isEmpty, item.title == title else { return }
            item.symbol = match
            Persistence.save(context)
        }
    }
}
