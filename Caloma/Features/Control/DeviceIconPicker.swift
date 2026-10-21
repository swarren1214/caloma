import PhotosUI
import SwiftUI
import UIKit

/// A device's icon, color, tile style and photo: anything from hundreds of symbols, any color,
/// three styles, or a photo of the real thing as the tile's background.
struct DeviceIconPicker: View {
    @Binding var draft: DeviceDraft
    var name: String
    var kind: HomeControl.Kind

    @Environment(\.accent) private var accent
    @State private var query = ""
    @State private var category = "All"
    @State private var photoItem: PhotosPickerItem?
    @State private var loadingPhoto = false

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 8)]

    var body: some View {
        let look = DeviceLook(kind: kind, draft: draft, accent: accent)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    DevicePreviewTile(name: name, detail: "", look: look, size: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STYLE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Picker("Style", selection: $draft.tileStyle) {
                            ForEach(TileStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if draft.photo != nil {
                            Text("Photos show in every style.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                colors(current: look.color)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search icons, like lamp, tree or fan", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.tertiaryLabel))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.primary.opacity(0.06), in: Capsule())

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(["All"] + DeviceIcons.sections.map(\.title), id: \.self) { title in
                                let on = title == category
                                Button {
                                    withAnimation(.snappy) { category = title }
                                } label: {
                                    Text(title)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 34)
                                        .foregroundStyle(on ? Color(.systemBackground) : Color.primary)
                                        .background(on ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -16)
                }

                let icons = DeviceIcons.icons(query: query, category: category)
                if icons.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(icons) { option in
                            let on = option.name == look.symbolOn
                            Button {
                                draft.symbol = option.name
                            } label: {
                                Image(systemName: option.name)
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundStyle(on ? (look.color.prefersDarkText ? Color.black : Color.white) : Color.primary.opacity(0.85))
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(on ? AnyShapeStyle(look.color) : AnyShapeStyle(Color.primary.opacity(0.06)), in: .rect(cornerRadius: 14, style: .continuous))
                                    .contentShape(.rect(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.accessibilityName)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }

                photoRow

                if !draft.symbol.isEmpty || !draft.colorHex.isEmpty || draft.tileStyle != .tinted || draft.photo != nil {
                    Button("Back to the Usual Look", role: .destructive) {
                        withAnimation(.snappy) {
                            draft.symbol = ""
                            draft.colorHex = ""
                            draft.tileStyle = .tinted
                            draft.photo = nil
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Icon & Color")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadingPhoto = true
            Task {
                if let image = await PhotoTools.load(item) {
                    draft.photo = PhotoTools.jpeg(from: image, maxSide: 600)
                }
                loadingPhoto = false
                photoItem = nil
            }
        }
    }

    private func colors(current: Color) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 10) {
            ForEach(ControlTheme.palette, id: \.hex) { swatch in
                let on = draft.colorHex == hexString(swatch.hex)
                Button {
                    draft.colorHex = hexString(swatch.hex)
                } label: {
                    Circle()
                        .fill(Color(hex: swatch.hex))
                        .frame(width: 32, height: 32)
                        .overlay { Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1) }
                        .padding(3)
                        .overlay { Circle().strokeBorder(on ? Color.primary : .clear, lineWidth: 2.5) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            ColorPicker(selection: Binding(get: { current }, set: { draft.colorHex = hexString($0.hexValue) }), supportsOpacity: false) {
                Text("Any color")
            }
            .labelsHidden()
            .frame(width: 38, height: 38)
            .accessibilityLabel("Any color")
        }
    }

    private var photoRow: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack(spacing: 12) {
                    Image(systemName: "camera")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(draft.photo == nil ? "Use a Photo" : "Change Photo")
                            .font(.body.weight(.semibold))
                        Text("The real thing, as the tile's background")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loadingPhoto { ProgressView() }
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            if draft.photo != nil {
                Button("Remove", role: .destructive) {
                    withAnimation(.snappy) { draft.photo = nil }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(12)
        .controlCard(cornerRadius: 20)
    }
}

/// Symbols for devices, grouped, with everyday search words. Names this iOS can't draw are
/// dropped when the library loads.
enum DeviceIcons {
    static let sections: [IconSection] = raw.compactMap { title, icons in
        let available = icons.filter { UIImage(systemName: $0.name) != nil }
        return available.isEmpty ? nil : IconSection(title: title, icons: available)
    }

    /// Icons in a category, or every icon matching all the words typed.
    static func icons(query: String, category: String) -> [IconOption] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<String>()
        if words.isEmpty {
            let pool = category == "All" ? sections : sections.filter { $0.title == category }
            return pool.flatMap(\.icons).filter { seen.insert($0.name).inserted }
        }
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
        ("Lighting", [
            i("lightbulb.fill", "bulb light"), i("lightbulb.led.fill", "led bulb"), i("lightbulb.2.fill", "bulbs"),
            i("lamp.table.fill", "table lamp bedside"), i("lamp.desk.fill", "desk lamp reading"), i("lamp.floor.fill", "floor lamp"),
            i("lamp.ceiling.fill", "pendant ceiling"), i("lamp.ceiling.inverse", "pendant"), i("chandelier.fill", "chandelier dining"),
            i("light.recessed.fill", "recessed can"), i("light.panel.fill", "panel"), i("light.strip.2.fill", "strip led tv backlight"),
            i("light.cylindrical.ceiling.fill", "ceiling"), i("light.beacon.max.fill", "porch outdoor"), i("lantern.fill", "lantern porch"),
            i("sparkles", "string lights twinkle fairy"), i("rays", "glow"), i("sun.max.fill", "bright"), i("moon.stars.fill", "nightlight night light"),
        ]),
        ("Comfort", [
            i("fan.fill", "fan"), i("fan.ceiling.fill", "ceiling fan"), i("fan.desk.fill", "desk fan"), i("fan.floor.fill", "floor fan"),
            i("heater.vertical.fill", "space heater radiator"), i("air.purifier.fill", "purifier air filter"), i("humidifier.fill", "humidifier"),
            i("dehumidifier.fill", "dehumidifier"), i("air.conditioner.horizontal.fill", "ac air conditioner mini split"), i("thermometer.medium", "temperature thermostat"),
            i("snowflake", "cool cold"), i("flame.fill", "fire fireplace heat"), i("fireplace.fill", "fireplace"), i("bed.double.fill", "bed electric blanket"),
            i("sofa.fill", "couch living"), i("blinds.horizontal.closed", "blinds shades"), i("curtains.closed", "curtains drapes"), i("window.vertical.closed", "window"),
        ]),
        ("Home", [
            i("powerplug.fill", "plug outlet"), i("poweroutlet.type.b.fill", "outlet socket"), i("lightswitch.on.fill", "switch"),
            i("cup.and.saucer.fill", "coffee tea"), i("mug.fill", "coffee mug kettle"), i("cooktop.fill", "stove cooktop"), i("oven.fill", "oven"),
            i("microwave.fill", "microwave"), i("refrigerator.fill", "fridge freezer"), i("dishwasher.fill", "dishwasher"), i("washer.fill", "washer laundry"),
            i("dryer.fill", "dryer laundry"), i("tv.fill", "tv television"), i("hifispeaker.fill", "speaker music"), i("homepod.fill", "homepod speaker"),
            i("music.note", "music"), i("desktopcomputer", "computer"), i("printer.fill", "printer"), i("wifi.router.fill", "router internet wifi"),
            i("frying.pan.fill", "cooking kitchen"), i("shower.fill", "shower bathroom"), i("bathtub.fill", "bath tub"), i("toilet.fill", "bathroom"),
        ]),
        ("Kids", [
            i("star.fill", "star"), i("moon.fill", "moon night"), i("heart.fill", "heart love"), i("teddybear.fill", "teddy bear toy"),
            i("gamecontroller.fill", "games video"), i("book.fill", "reading book"), i("backpack.fill", "school"), i("puzzlepiece.fill", "puzzle play"),
            i("crown.fill", "crown princess king"), i("balloon.2.fill", "balloons party"), i("party.popper.fill", "party"), i("rainbow", "rainbow"),
            i("figure.child", "kid child"), i("airplane", "plane"), i("car.side.fill", "car toy"), i("soccerball", "soccer sports"),
            i("paintpalette.fill", "art paint"), i("guitars.fill", "guitar music"), i("tent.fill", "fort tent camping"), i("graduationcap.fill", "homework study"),
        ]),
        ("Outside", [
            i("sprinkler.and.droplets.fill", "sprinkler irrigation lawn"), i("spigot.fill", "spigot hose faucet"), i("drop.fill", "water"),
            i("tree.fill", "tree yard garden"), i("leaf.fill", "garden plant"), i("camera.macro", "flower garden"), i("house.fill", "house"),
            i("door.garage.closed", "garage"), i("door.left.hand.closed", "door"), i("door.sliding.left.hand.closed", "patio slider"),
            i("car.fill", "car"), i("ev.charger.fill", "ev charger electric car"), i("bolt.car.fill", "charging car"),
            i("figure.pool.swim", "pool swim"), i("water.waves", "pool hot tub spa"), i("sun.horizon.fill", "sunset patio"), i("mailbox.fill", "mail mailbox"),
            i("lock.fill", "lock gate"), i("video.fill", "camera"), i("bell.fill", "doorbell"),
        ]),
        ("Seasonal", [
            i("tree.fill", "christmas tree holiday"), i("gift.fill", "gift present christmas"), i("snowflake", "winter snow christmas"),
            i("sparkles", "lights holiday twinkle"), i("star.fill", "star tree topper"), i("moon.stars.fill", "night"), i("birthday.cake.fill", "birthday cake"),
            i("party.popper.fill", "new year party"), i("balloon.fill", "balloon"), i("fireworks", "fireworks fourth july new year"),
            i("leaf.fill", "fall autumn halloween pumpkin"), i("sun.max.fill", "summer"), i("heart.fill", "valentines"), i("hare.fill", "easter bunny"),
            i("flame.fill", "candle fire"), i("bell.fill", "bells"),
        ]),
        ("Pets", [
            i("pawprint.fill", "pet paw"), i("dog.fill", "dog"), i("cat.fill", "cat"), i("fish.fill", "fish tank aquarium"),
            i("bird.fill", "bird"), i("tortoise.fill", "turtle tortoise"), i("hare.fill", "rabbit bunny"), i("lizard.fill", "lizard reptile heat lamp"),
            i("ant.fill", "ant farm"), i("ladybug.fill", "bug"),
        ]),
        ("Safety", [
            i("lock.shield.fill", "security"), i("shield.lefthalf.filled", "alarm security"), i("smoke.fill", "smoke"), i("drop.triangle.fill", "leak water"),
            i("exclamationmark.triangle.fill", "warning"), i("bell.badge.fill", "alert"), i("key.fill", "key"), i("sensor.fill", "sensor"),
            i("figure.walk.motion", "motion"), i("battery.75percent", "battery"), i("button.programmable", "button remote"),
        ]),
    ]
}
