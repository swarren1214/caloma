import SwiftUI
import UIKit

/// SF Symbols offered for chores, rewards and home care tasks, grouped by what families do,
/// each with everyday search words ("dishes", "vet", "lawn"). Names this iOS can't draw are
/// dropped when the library loads, so a newer symbol never shows up as a blank square.
nonisolated struct IconOption: Identifiable, Hashable, Sendable {
    let name: String
    /// Extra words people might search for.
    let keywords: String
    var id: String { name }

    var searchText: String {
        (name.replacingOccurrences(of: ".", with: " ") + " " + keywords).lowercased()
    }

    var accessibilityName: String { name.replacingOccurrences(of: ".", with: " ") }
}

nonisolated struct IconSection: Identifiable, Sendable {
    let title: String
    let icons: [IconOption]
    var id: String { title }
}

enum IconLibrary {
    /// The whole library, minus anything this iOS can't draw.
    static let sections: [IconSection] = raw.compactMap { title, icons in
        let available = icons.filter { UIImage(systemName: $0.name) != nil }
        return available.isEmpty ? nil : IconSection(title: title, icons: available)
    }

    /// Every icon once, in library order.
    static let all: [IconOption] = {
        var seen = Set<String>()
        return sections.flatMap(\.icons).filter { seen.insert($0.name).inserted }
    }()

    /// Icons whose name, keywords or section match every word typed.
    static func search(_ query: String) -> [IconOption] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return all }
        var seen = Set<String>()
        return sections.flatMap { section in
            section.icons.filter { option in
                let text = option.searchText + " " + section.title.lowercased()
                return words.allSatisfy { text.contains($0) }
            }
        }
        .filter { seen.insert($0.name).inserted }
    }

    private static func i(_ name: String, _ keywords: String = "") -> IconOption {
        IconOption(name: name, keywords: keywords)
    }

    private static let raw: [(String, [IconOption])] = [
        ("Rooms", [
            i("fork.knife", "kitchen"),
            i("refrigerator", "kitchen pantry"),
            i("sofa", "living room family room"),
            i("chair", "dining room"),
            i("chair.lounge", "den lounge patio"),
            i("tv", "family room tv room media"),
            i("bed.double", "bedroom master"),
            i("bed.double.fill", "bedroom"),
            i("teddybear", "playroom nursery kids room"),
            i("shower", "bathroom"),
            i("bathtub", "bathroom"),
            i("toilet", "bathroom powder room"),
            i("washer", "laundry room"),
            i("door.garage.closed", "garage"),
            i("car", "garage driveway"),
            i("leaf", "yard garden"),
            i("tree", "backyard"),
            i("stairs", "stairs hallway"),
            i("door.left.hand.closed", "entry hallway door"),
            i("books.vertical", "office study library"),
            i("desktopcomputer", "office"),
            i("dumbbell", "gym"),
            i("archivebox", "storage basement attic"),
            i("house", "whole house"),
        ]),
        ("Cleaning", [
            i("sparkles", "clean tidy shine dust"),
            i("bubbles.and.sparkles", "wash scrub soap clean"),
            i("spray.bottle", "spray clean wipe counters"),
            i("hands.and.sparkles", "wash hands clean"),
            i("trash", "garbage take out bins"),
            i("trash.circle", "garbage recycling"),
            i("arrow.3.trianglepath", "recycling recycle"),
            i("basket", "tidy pick up toys"),
            i("archivebox", "put away organize storage"),
            i("shippingbox", "boxes put away"),
            i("tray.full", "declutter organize"),
            i("wind", "vacuum dust air"),
            i("fan", "dust fan"),
            i("window.vertical.closed", "windows wipe"),
            i("door.left.hand.closed", "doors"),
            i("sofa", "living room couch tidy"),
            i("lamp.table", "dust room"),
            i("checkmark.circle", "done generic"),
            i("checklist", "list routine"),
        ]),
        ("Bedroom & Self-care", [
            i("bed.double", "make bed bedroom"),
            i("bed.double.fill", "make bed sleep"),
            i("moon.zzz", "bedtime sleep"),
            i("alarm", "wake up morning"),
            i("sun.horizon", "morning routine"),
            i("mouth", "brush teeth"),
            i("comb", "hair brush"),
            i("shower", "shower bath"),
            i("bathtub", "bath"),
            i("toilet", "bathroom potty"),
            i("hands.and.sparkles.fill", "wash hands"),
            i("figure.dress.line.vertical.figure", "get dressed clothes"),
            i("tshirt", "clothes dressed"),
            i("shoeprints.fill", "shoes"),
            i("eyeglasses", "glasses"),
            i("pills", "vitamins medicine"),
            i("drop", "water drink"),
            i("heart", "kindness love"),
        ]),
        ("Kitchen & Meals", [
            i("fork.knife", "set table dinner meal"),
            i("dishwasher", "dishes load unload"),
            i("sink", "dishes wash sink"),
            i("refrigerator", "fridge food"),
            i("oven", "cook bake"),
            i("microwave", "cook heat"),
            i("stove", "cook"),
            i("frying.pan", "cook breakfast"),
            i("cup.and.saucer", "breakfast cup"),
            i("mug", "drink"),
            i("wineglass", "glasses dishes"),
            i("takeoutbag.and.cup.and.straw", "lunch pack"),
            i("carrot", "vegetables eat"),
            i("leaf", "salad greens"),
            i("birthday.cake", "bake cake"),
            i("cart", "groceries shopping"),
            i("bag", "groceries put away"),
        ]),
        ("Laundry", [
            i("washer", "laundry wash clothes"),
            i("dryer", "laundry dry clothes"),
            i("tshirt.fill", "fold laundry"),
            i("hanger", "hang clothes closet"),
            i("basket.fill", "laundry basket"),
            i("bed.double.circle", "change sheets"),
            i("shoe", "shoes"),
            i("backpack", "backpack bag"),
        ]),
        ("Pets", [
            i("pawprint", "pet dog cat feed"),
            i("pawprint.fill", "pet"),
            i("dog", "dog walk feed"),
            i("cat", "cat litter feed"),
            i("bird", "bird cage"),
            i("fish", "fish tank aquarium"),
            i("tortoise", "turtle reptile"),
            i("hare", "rabbit bunny"),
            i("ant", "bugs"),
            i("ladybug", "bugs garden"),
            i("figure.walk", "walk dog"),
        ]),
        ("Yard & Outside", [
            i("leaf.fill", "rake leaves yard"),
            i("tree", "yard garden"),
            i("camera.macro", "plants flowers"),
            i("laurel.leading", "garden"),
            i("drop.fill", "water plants"),
            i("spigot", "hose water"),
            i("sprinkler.and.droplets", "sprinklers lawn"),
            i("snowflake", "shovel snow winter"),
            i("sun.max", "outside summer"),
            i("cloud.rain", "rain"),
            i("mailbox", "mail get"),
            i("car", "wash car"),
            i("bicycle", "bike"),
            i("figure.outdoor.cycle", "ride bike"),
            i("tent", "camping"),
            i("flag", "goal"),
        ]),
        ("School & Learning", [
            i("book", "read reading"),
            i("book.closed", "book"),
            i("books.vertical", "library homework"),
            i("pencil", "homework write"),
            i("pencil.and.ruler", "homework math"),
            i("doc.text", "worksheet homework"),
            i("graduationcap", "school study"),
            i("backpack.fill", "school bag pack"),
            i("brain.head.profile", "study learn think"),
            i("lightbulb", "ideas learn"),
            i("globe.americas", "geography"),
            i("function", "math"),
            i("textformat.abc", "spelling letters"),
            i("character.book.closed", "language"),
            i("laptopcomputer", "computer typing"),
            i("keyboard", "typing"),
        ]),
        ("Music & Activities", [
            i("music.note", "music practice"),
            i("pianokeys", "piano practice"),
            i("guitars", "guitar"),
            i("music.mic", "sing voice"),
            i("paintbrush", "art paint"),
            i("paintpalette", "art draw"),
            i("scissors", "crafts"),
            i("puzzlepiece", "puzzle games"),
            i("figure.run", "run exercise"),
            i("figure.soccer", "soccer sports"),
            i("figure.basketball", "basketball sports"),
            i("figure.swim", "swim"),
            i("figure.dance", "dance"),
            i("figure.gymnastics", "gymnastics"),
            i("figure.martial.arts", "karate"),
            i("figure.yoga", "yoga stretch"),
            i("sportscourt", "sports practice"),
            i("soccerball", "soccer"),
            i("basketball", "basketball"),
            i("baseball", "baseball"),
            i("football", "football"),
            i("tennisball", "tennis"),
            i("trophy", "win sports"),
            i("medal", "award"),
        ]),
        ("Rewards & Fun", [
            i("gift", "present reward"),
            i("star", "star favorite"),
            i("star.fill", "star"),
            i("tv", "screen time tv show"),
            i("gamecontroller", "video games screen time"),
            i("ipad", "tablet screen time"),
            i("iphone", "phone"),
            i("headphones", "music"),
            i("film", "movie night"),
            i("popcorn", "movie snacks"),
            i("ticket", "event tickets"),
            i("theatermasks", "show theater"),
            i("party.popper", "party celebrate"),
            i("balloon.2", "party birthday"),
            i("moon.stars", "stay up late"),
            i("figure.play", "play park"),
            i("figure.and.child.holdinghands", "date outing parent"),
            i("calendar", "outing day"),
            i("car.side", "drive trip"),
            i("airplane", "trip vacation"),
            i("beach.umbrella", "beach vacation"),
            i("mountain.2", "hike trip"),
            i("flag.checkered", "goal finish"),
            i("crown", "special king queen"),
            i("wand.and.stars", "magic special"),
        ]),
        ("Treats", [
            i("birthday.cake.fill", "dessert cake"),
            i("takeoutbag.and.cup.and.straw.fill", "fast food takeout"),
            i("fork.knife.circle", "restaurant dinner"),
            i("cup.and.heat.waves", "hot chocolate"),
            i("carrot.fill", "snack"),
            i("cart.fill", "store shopping"),
            i("storefront", "store"),
        ]),
        ("Money", [
            i("banknote", "cash money allowance"),
            i("dollarsign.circle", "money allowance"),
            i("centsign.circle", "money"),
            i("creditcard", "card"),
            i("wallet.bifold", "wallet"),
            i("building.columns", "bank save"),
            i("chart.line.uptrend.xyaxis", "save invest"),
            i("hand.raised", "give donate"),
            i("heart.circle", "give charity"),
        ]),
        ("Home Care", [
            i("fan.fill", "hvac filter air"),
            i("air.conditioner.horizontal", "ac air conditioner"),
            i("heater.vertical", "furnace heater"),
            i("thermometer.medium", "thermostat temperature"),
            i("light.beacon.max", "smoke detector alarm"),
            i("sensor", "detector sensor"),
            i("flame", "fire extinguisher gas"),
            i("fire.extinguisher", "fire extinguisher"),
            i("bolt", "electric breaker"),
            i("lightbulb.fill", "light bulb replace"),
            i("powerplug", "outlet electric"),
            i("battery.100", "batteries"),
            i("drop.triangle", "leak water"),
            i("shower.handheld", "plumbing"),
            i("water.waves", "water heater pool"),
            i("refrigerator.fill", "fridge filter"),
            i("dishwasher.fill", "dishwasher"),
            i("washer.fill", "washer"),
            i("dryer.fill", "dryer vent lint"),
            i("house", "house home roof gutters"),
            i("house.lodge", "cabin"),
            i("chimney", "chimney fireplace"),
            i("window.horizontal", "windows"),
            i("door.garage.closed", "garage door"),
            i("lock", "locks security"),
            i("key", "keys"),
            i("wifi.router", "router internet"),
            i("hammer", "repair fix"),
            i("wrench.and.screwdriver", "tools repair fix"),
            i("screwdriver", "tools"),
            i("paintbrush.pointed", "paint touch up"),
            i("ruler", "measure"),
            i("ladder", "ladder"),
            i("car.fill", "car oil service"),
            i("tirepressure", "tires"),
            i("fuelpump", "gas"),
        ]),
        ("Other", [
            i("bell", "reminder"),
            i("clock", "time"),
            i("calendar.badge.clock", "schedule"),
            i("person", "person"),
            i("person.2", "together family"),
            i("figure.2.and.child.holdinghands", "family"),
            i("phone", "call grandma"),
            i("envelope", "write letter"),
            i("camera", "photo"),
            i("map", "places"),
            i("bookmark", "saved"),
            i("questionmark.circle", "other"),
        ]),
    ]
}

/// Every icon in the library, grouped, with a search field that matches names and everyday
/// words. Picking one goes back.
struct IconLibraryView: View {
    @Binding var selection: String
    var color: Color
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 8)]

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(IconLibrary.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                            grid(section.icons)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 32)
            } else {
                let results = IconLibrary.search(query)
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else {
                    grid(results)
                        .padding(16)
                        .padding(.bottom, 32)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search icons, like dishes or dog")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    private func grid(_ icons: [IconOption]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(icons) { option in
                let on = option.name == selection
                Button {
                    selection = option.name
                    dismiss()
                } label: {
                    Image(systemName: option.name)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(on ? AnyShapeStyle(color) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: .rect(cornerRadius: 12))
                        .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityName)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The Icon section of an editor: a dozen quick picks (the current icon first when it isn't
/// one of them), then More Icons for the whole searchable library.
struct IconPicker: View {
    var quick: [String]
    @Binding var selection: String
    var color: Color

    var body: some View {
        let picks = quick.contains(selection) ? Array(quick.prefix(12)) : [selection] + Array(quick.prefix(11))
        SymbolGrid(symbols: picks, selection: $selection, color: color)
            .padding(.vertical, 4)
        NavigationLink {
            IconLibraryView(selection: $selection, color: color)
        } label: {
            Label("More Icons", systemImage: "magnifyingglass")
        }
    }
}
