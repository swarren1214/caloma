import Foundation
import SwiftData
import Testing
@testable import Caloma

/// Lists: who has what, what counts as done, and when a list comes off everyone's screens.
@MainActor
struct FamilyListsTests {
    private func family(in context: ModelContext) -> (mom: Member, ella: Member, max: Member) {
        let mom = Member(name: "Mom", role: .parent, color: .pink, sortOrder: 0)
        let ella = Member(name: "Ella", role: .kid, color: .purple, sortOrder: 1)
        let max = Member(name: "Max", role: .kid, color: .blue, sortOrder: 2)
        [mom, ella, max].forEach(context.insert)
        return (mom, ella, max)
    }

    @Test func everyoneItemsAreEachPersonsOwn() {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let (mom, ella, max) = family(in: context)
        let list = FamilyList(title: "Bear Lake Trip")
        context.insert(list)
        let toothbrush = FamilyListItem(listID: list.id, title: "Toothbrush", everyone: true, assignees: [], sortOrder: 0)
        context.insert(toothbrush)

        FamilyLists.toggle(toothbrush, for: ella.id, in: context)
        let checks = Persistence.fetchAll(FamilyListCheck.self, in: context)
        #expect(FamilyLists.isDone(toothbrush, for: ella.id, checks: checks))
        #expect(!FamilyLists.isDone(toothbrush, for: max.id, checks: checks))

        let progress = FamilyLists.progress(of: list, in: [toothbrush], checks: checks, members: [mom, ella, max])
        #expect(progress.done == 1)
        #expect(progress.total == 3)
    }

    @Test func itemsForSeveralPeopleAreCheckedOffOneByOne() {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let (mom, ella, max) = family(in: context)
        let list = FamilyList(title: "Party")
        context.insert(list)
        let swimsuit = FamilyListItem(listID: list.id, title: "Swimsuit", everyone: false, assignees: [ella.id, max.id], sortOrder: 0)
        context.insert(swimsuit)

        #expect(FamilyLists.isAssigned(swimsuit, to: ella.id))
        #expect(!FamilyLists.isAssigned(swimsuit, to: mom.id))
        // A parent checks it off for Ella: Max still needs his.
        FamilyLists.toggle(swimsuit, for: ella.id, in: context)
        var checks = Persistence.fetchAll(FamilyListCheck.self, in: context)
        #expect(FamilyLists.isDone(swimsuit, for: ella.id, checks: checks))
        #expect(!FamilyLists.isDone(swimsuit, for: max.id, checks: checks))
        let progress = FamilyLists.progress(of: list, in: [swimsuit], checks: checks, members: [mom, ella, max])
        #expect(progress.done == 1)
        #expect(progress.total == 2)
        // Un-checking is just as personal.
        FamilyLists.toggle(swimsuit, for: max.id, in: context)
        FamilyLists.toggle(swimsuit, for: ella.id, in: context)
        checks = Persistence.fetchAll(FamilyListCheck.self, in: context)
        #expect(!FamilyLists.isDone(swimsuit, for: ella.id, checks: checks))
        #expect(FamilyLists.isDone(swimsuit, for: max.id, checks: checks))
    }

    @Test func kidsOnlySeeListsWithSomethingOfTheirs() {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let (mom, ella, _) = family(in: context)
        let list = FamilyList(title: "Groceries")
        context.insert(list)
        let item = FamilyListItem(listID: list.id, title: "Milk", everyone: false, assignees: [mom.id], sortOrder: 0)
        context.insert(item)

        #expect(FamilyLists.lists(for: ella.id, lists: [list], items: [item], checks: []).isEmpty)
        #expect(FamilyLists.lists(for: mom.id, lists: [list], items: [item], checks: []).first?.left == 1)
    }

    @Test func listsClearWhenTheyreOver() {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let over = FamilyList(title: "Last weekend")
        over.endsAt = now.addingTimeInterval(-60)
        let kept = FamilyList(title: "Keeps going")
        kept.endsAt = now.addingTimeInterval(-60)
        kept.clearsWhenOver = false
        let soon = FamilyList(title: "Next weekend")
        soon.endsAt = now.addingTimeInterval(86_400)
        [over, kept, soon].forEach(context.insert)

        #expect(FamilyLists.active([over, kept, soon], now: now).map(\.title).sorted() == ["Keeps going", "Next weekend"])
        FamilyLists.clearFinished(in: context, now: now)
        #expect(over.isArchived)
        #expect(!kept.isArchived)
        #expect(FamilyLists.reusable([over, kept, soon], now: now).map(\.title) == ["Last weekend"])
    }

    @Test func endIsTheEventsEndOrTheDayAfterItsDue() {
        let calendar = Calendar.current
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 17))!
        let eventEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 18))!
        #expect(FamilyLists.end(dueAt: due, eventEnd: eventEnd) == eventEnd)
        #expect(FamilyLists.end(dueAt: due, eventEnd: nil) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 24)))
        #expect(FamilyLists.end(dueAt: nil, eventEnd: nil) == nil)
    }

    @Test func iconsComeFromWholeWords() {
        #expect(ListItemIcon.keywordMatch(for: "") == nil)
        #expect(ListItemIcon.keywordMatch(for: "the for") == nil)
        // "Hat" isn't "chat".
        if let hat = ListItemIcon.keywordMatch(for: "Hat") {
            #expect(!hat.contains("bubble"))
        }
    }

    @Test func reassigningDropsOtherPeoplesTicks() {
        let container = Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let (_, ella, max) = family(in: context)
        let list = FamilyList(title: "Trip")
        context.insert(list)
        let item = FamilyListItem(listID: list.id, title: "Toothbrush", everyone: true, assignees: [], sortOrder: 0)
        context.insert(item)
        FamilyLists.toggle(item, for: ella.id, in: context)

        item.everyone = false
        item.assigneeIDs = [max.id]
        FamilyLists.dropChecks(on: item, keeping: [max.id], in: context)
        Persistence.save(context)
        #expect(!FamilyLists.isDone(item, for: max.id, checks: Persistence.fetchAll(FamilyListCheck.self, in: context)))
    }
}
