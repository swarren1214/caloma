import Testing
@testable import Caloma

/// Which Apple Home rooms become Caloma rooms for chores.
struct HomeRoomImportTests {
    @Test func addsOnlyRoomsTheFamilyDoesNotHave() {
        let new = HomeRoomImport.newRoomNames(home: ["Kitchen", "Ella's Room", "Garage"], existing: ["kitchen", "Yard"], imported: [])
        #expect(new == ["Ella's Room", "Garage"])
    }

    @Test func neverBringsBackARoomAddedBefore() {
        let new = HomeRoomImport.newRoomNames(home: ["Garage", "Office"], existing: [], imported: ["garage"])
        #expect(new == ["Office"])
    }

    @Test func eachNameOnceAndTrimmed() {
        let new = HomeRoomImport.newRoomNames(home: [" Den ", "den", ""], existing: [], imported: [])
        #expect(new == ["Den"])
    }

    @Test func iconsFitTheName() {
        #expect(HomeRoomImport.symbol(for: "Kitchen") == "fork.knife")
        #expect(HomeRoomImport.symbol(for: "Primary Bedroom") == "bed.double")
        #expect(HomeRoomImport.symbol(for: "Kids' Bathroom") == "teddybear")
        #expect(HomeRoomImport.symbol(for: "Back Patio") == "leaf")
        #expect(HomeRoomImport.symbol(for: "Sunroom") == "door.left.hand.closed")
    }
}
