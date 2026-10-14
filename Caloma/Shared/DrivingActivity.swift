import ActivityKit
import Foundation

// Shared by the iPhone app and the CalomaWidgets extension (tick both under Target Membership).

/// "You're driving": a Live Activity on the Lock Screen, in the Dynamic Island and on the
/// CarPlay dashboard for an event this phone's parent is driving to. It counts down to the
/// start and shows the bring list with what the kids have packed.
nonisolated struct DrivingAttributes: ActivityAttributes, Sendable {
    /// The occurrence: "<event>@<start>".
    var occurrenceID: String
    var title: String
    /// "Max", "Ella and June", "Everyone".
    var who: String
    var location: String
    var start: Date
    var end: Date
    /// The event's color, 0xRRGGBB.
    var color: UInt32

    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var bring: [Item]

        nonisolated struct Item: Codable, Hashable, Sendable, Identifiable {
            var name: String
            /// Every kid going has packed it.
            var packed: Bool
            var id: String { name }
        }

        var packedCount: Int { bring.filter(\.packed).count }
        var missing: [Item] { bring.filter { !$0.packed } }
    }

    /// The Directions button. A tap in a Live Activity opens Caloma, which hands the address
    /// to Maps (`AppRouter.open`): caloma://directions?to=<address>.
    var directionsURL: URL? {
        guard !location.isEmpty else { return nil }
        var components = URLComponents(string: "caloma://directions")
        components?.queryItems = [URLQueryItem(name: "to", value: location)]
        return components?.url
    }

    /// Driving directions in Apple Maps.
    static func mapsURL(to address: String) -> URL? {
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "daddr", value: address), URLQueryItem(name: "dirflg", value: "d")]
        return components?.url
    }
}
