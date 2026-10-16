import CloudKit
import Foundation
import SwiftUI
import Testing
@testable import Caloma

/// Control's logic that doesn't need a real home: finding a device's style, keeping filter
/// tasks single, the climate dial's geometry, warmth presets and fan speeds.
@MainActor
struct ControlTests {
    let container = Persistence.makeContainer(inMemory: true)

    /// A style in an in-memory store, as the app makes them.
    func makeStyle(_ serviceID: String, _ matchKey: String) -> DeviceStyle {
        let style = DeviceStyle(homeID: "h", serviceID: serviceID, matchKey: matchKey)
        container.mainContext.insert(style)
        return style
    }
    // MARK: Styles

    @Test func matchKeyIgnoresCaseAndSpaces() {
        #expect(DeviceMatch.key(name: " Front Door ", room: "Entry", kind: "lock") == "front door|entry|lock")
        #expect(DeviceMatch.key(name: "Front Door", room: "entry", kind: "lock") == DeviceMatch.key(name: "front door", room: "Entry ", kind: "lock"))
    }

    @Test func styleFoundByServiceBeforeMatchKey() {
        let byKey = makeStyle("other-phone-id", "lamp|den|light")
        byKey.symbol = "lamp.floor.fill"
        let byService = makeStyle("this-phone-id", "old name|den|light")
        byService.symbol = "chandelier.fill"
        let book = StyleBook([byKey, byService])
        #expect(book.style(serviceID: "this-phone-id", matchKey: "lamp|den|light")?.symbol == "chandelier.fill")
    }

    @Test func styleFallsBackToMatchKeyWhenIDsDiffer() {
        let style = makeStyle("mom-phone-id", "christmas tree|living room|light")
        style.colorHex = "#30C46B"
        let book = StyleBook([style])
        #expect(book.style(serviceID: "dad-phone-id", matchKey: "christmas tree|living room|light")?.colorHex == "#30C46B")
        #expect(book.style(serviceID: "dad-phone-id", matchKey: "porch|outside|light") == nil)
    }

    @Test func newestStyleWins() {
        let older = makeStyle("s", "k")
        older.symbol = "star.fill"
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newer = makeStyle("s", "k")
        newer.symbol = "moon.fill"
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        #expect(StyleBook([newer, older]).style(serviceID: "s", matchKey: "k")?.symbol == "moon.fill")
    }

    @Test func deviceStyleRoundTripsThroughCloudKit() {
        let style = DeviceStyle(homeID: "home", serviceID: "service", matchKey: "tree|living room|light")
        container.mainContext.insert(style)
        style.symbol = "tree.fill"
        style.colorHex = "#30C46B"
        style.tileStyle = .glow
        style.photoData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        style.kidsAllowed = true
        style.pinnedToHome = true
        let record = CKRecord(recordType: DeviceStyle.recordType)
        style.write(to: record)

        let copy = DeviceStyle.blank()
        container.mainContext.insert(copy)
        copy.read(from: record)
        #expect(copy.homeID == "home")
        #expect(copy.serviceID == "service")
        #expect(copy.matchKey == "tree|living room|light")
        #expect(copy.symbol == "tree.fill")
        #expect(copy.colorHex == "#30C46B")
        #expect(copy.tileStyle == .glow)
        #expect(copy.photoData == Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(copy.kidsAllowed)
        #expect(copy.pinnedToHome)
        #expect(!copy.hidden)
    }

    @Test func emptyDraftNeedsNoStyle() {
        var draft = DeviceDraft()
        #expect(draft.isEmpty)
        draft.pinnedToHome = true
        #expect(!draft.isEmpty)
    }

    // MARK: Filters

    @Test func filterTaskAtTwentyPercentOrWhenAsked() {
        #expect(FilterTasks.needsTask(level: 20, needsChange: false))
        #expect(FilterTasks.needsTask(level: 12, needsChange: false))
        #expect(!FilterTasks.needsTask(level: 21, needsChange: false))
        #expect(FilterTasks.needsTask(level: 80, needsChange: true))
        #expect(!FilterTasks.needsTask(level: nil, needsChange: false))
    }

    @Test func filterTaskKeySameOnEveryPhone() {
        #expect(FilterTasks.sourceKey(accessoryName: "Air Purifier", roomName: "Nursery")
            == FilterTasks.sourceKey(accessoryName: "air purifier", roomName: "Nursery "))
        #expect(FilterTasks.sourceKey(accessoryName: "Air Purifier", roomName: "Nursery").hasPrefix("filter:"))
    }

    // MARK: Climate dial

    @Test func dialFractionClampsToRange() {
        #expect(DialMath.fraction(10, in: 10...30) == 0)
        #expect(DialMath.fraction(20, in: 10...30) == 0.5)
        #expect(DialMath.fraction(40, in: 10...30) == 1)
        #expect(DialMath.fraction(5, in: 10...30) == 0)
    }

    @Test func dialStartsLowerLeftAndEndsLowerRight() {
        let center = CGPoint(x: 100, y: 100)
        let start = DialMath.point(fraction: 0, radius: 50, center: center)
        let middle = DialMath.point(fraction: 0.5, radius: 50, center: center)
        let end = DialMath.point(fraction: 1, radius: 50, center: center)
        #expect(start.x < center.x && start.y > center.y)
        #expect(abs(middle.x - center.x) < 0.001 && middle.y < center.y)
        #expect(end.x > center.x && end.y > center.y)
    }

    // MARK: Warmth and fans

    @Test func miredsAndKelvin() {
        #expect(Warmth.mireds(kelvin: 2500) == 400)
        #expect(Warmth.kelvin(mireds: 250) == 4000)
    }

    @Test func nearestWarmth() {
        #expect(Warmth.nearest(toMireds: nil).name == "Warm")
        #expect(Warmth.nearest(toMireds: 454).name == "Candle")
        #expect(Warmth.nearest(toMireds: 200).name == "Daylight")
    }

    @Test func fanSpeedBuckets() {
        #expect(FanSpeed.nearest(to: 0) == .off)
        #expect(FanSpeed.nearest(to: 25) == .low)
        #expect(FanSpeed.nearest(to: 50) == .medium)
        #expect(FanSpeed.nearest(to: 90) == .high)
    }

    @Test func securityLabels() {
        #expect(SecurityMode.stateLabel(0) == "Armed · Home")
        #expect(SecurityMode.stateLabel(3) == "Disarmed")
        #expect(SecurityMode.stateLabel(4) == "Alarm going off")
    }
}
