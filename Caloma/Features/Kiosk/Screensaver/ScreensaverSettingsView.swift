import Photos
import PhotosUI
import SwiftUI

/// Family › Family Board › Screensaver: when it starts, the photos, the cards that take turns,
/// what waking it does, and the dim clock at night.
struct ScreensaverSettingsView: View {
    @AppStorage(SettingsKey.kioskScreensaver) private var isOn = true
    @AppStorage(SettingsKey.kioskScreensaverMinutes) private var minutes = 5
    @AppStorage(SettingsKey.kioskScreensaverPhotoSeconds) private var photoSeconds = 15
    @AppStorage(SettingsKey.kioskScreensaverShuffle) private var shuffle = true
    @AppStorage(SettingsKey.kioskScreensaverZoom) private var slowZoom = true
    @AppStorage(SettingsKey.kioskScreensaverStyle) private var styleRaw = ScreensaverStyle.corner.rawValue
    @AppStorage(SettingsKey.kioskScreensaverWakeOnMotion) private var wakesOnWalkUp = true
    @AppStorage(SettingsKey.kioskScreensaverWakeTo) private var wakeToRaw = ScreensaverWakeTo.person.rawValue
    @AppStorage(SettingsKey.kioskScreensaverNight) private var nightClock = true
    @AppStorage(SettingsKey.kioskScreensaverWidgets) private var widgetsRaw = ScreensaverWidget.defaultOrder
    @AppStorage(SettingsKey.kioskScreensaverWallpapers) private var wallpapersRaw = Wallpaper.defaultSelection
    @AppStorage(SettingsKey.kioskScreensaverAlbums) private var albumsRaw = ""
    @AppStorage(SettingsKey.kioskScreensaverPhotos) private var photosRaw = ""
    @AppStorage(SettingsKey.kioskDims) private var dims = true
    @AppStorage(SettingsKey.kioskDimMinutes) private var dimMinutes = 5
    @AppStorage(SettingsKey.kioskFaces) private var facesOn = false

    @State private var previewing = false

    var body: some View {
        Form {
            Section {
                Toggle("Screensaver", isOn: $isOn)
                if isOn {
                    Picker("Start When No One's Around For", selection: $minutes) {
                        ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    .tint(.primary)
                }
            } footer: {
                if isOn && dims {
                    Text("The screen dims \(dimMinutes) minutes after the screensaver starts. Change that in Dim After.")
                }
            }

            if isOn {
                Section("Photos") {
                    NavigationLink {
                        ScreensaverPhotosView()
                    } label: {
                        LabeledContent("Photos", value: photoSummary)
                    }
                    Picker("Each Photo Shows For", selection: $photoSeconds) {
                        ForEach([8, 15, 30, 60], id: \.self) { Text($0 < 60 ? "\($0) seconds" : "1 minute").tag($0) }
                    }
                    .tint(.primary)
                    Toggle("Shuffle", isOn: $shuffle)
                    Toggle(isOn: $slowZoom) {
                        settingLabel("Slow Zoom", "A gentle drift across each photo")
                    }
                }

                Section {
                    NavigationLink {
                        ScreensaverWidgetsView()
                    } label: {
                        LabeledContent("Cards", value: cardSummary)
                    }
                    Picker("Card Style", selection: $styleRaw) {
                        ForEach(ScreensaverStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .tint(.primary)
                } header: {
                    Text("Cards")
                } footer: {
                    Text("The clock is always there. The cards take turns every 8 seconds, and a card with nothing to say skips its turn.")
                }

                Section {
                    Toggle(isOn: $wakesOnWalkUp) {
                        settingLabel("Wake When Someone Walks Up", "The front camera notices movement; nothing is recorded")
                    }
                    LabeledContent("Wake When the Screen Is Tapped", value: "Always")
                    Picker("Then Show", selection: $wakeToRaw) {
                        ForEach(ScreensaverWakeTo.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .tint(.primary)
                } header: {
                    Text("Waking Up")
                } footer: {
                    Text(facesOn
                         ? "With Their Screen, a recognized face opens that person's screen, with any wall notes waiting for them."
                         : "Their Screen needs Faces turned on. Until then the Family Board wakes to the calendar.")
                }

                Section {
                    Toggle(isOn: $nightClock) {
                        settingLabel("Just a Dim Clock at Night", "10:00 PM to 6:00 AM, no photos")
                    }
                }

                Section {
                    Button {
                        previewing = true
                    } label: {
                        Label("Preview Screensaver", systemImage: "play.rectangle")
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("Screensaver")
        .fullScreenCover(isPresented: $previewing) {
            KioskScreensaverView { previewing = false }
        }
    }

    private var photoSummary: String {
        var parts: [String] = []
        let albums = albumsRaw.split(separator: ",").count
        let picked = photosRaw.split(separator: ",").count
        let walls = wallpapersRaw.split(separator: ",").count
        if albums > 0 { parts.append(albums == 1 ? "1 album" : "\(albums) albums") }
        if picked > 0 { parts.append(picked == 1 ? "1 photo" : "\(picked) photos") }
        if walls > 0 { parts.append(walls == 1 ? "1 wallpaper" : "\(walls) wallpapers") }
        return parts.isEmpty ? "Caloma wallpapers" : parts.joined(separator: ", ")
    }

    private var cardSummary: String {
        let on = ScreensaverWidget.decode(widgetsRaw).filter(\.isOn).count
        return on == 0 ? "Clock only" : "\(on) on"
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The cards: on or off, and their order.
struct ScreensaverWidgetsView: View {
    @AppStorage(SettingsKey.kioskScreensaverWidgets) private var widgetsRaw = ScreensaverWidget.defaultOrder

    var body: some View {
        let list = ScreensaverWidget.decode(widgetsRaw)
        List {
            Section {
                Label {
                    LabeledContent("Clock and Date", value: "Always")
                } icon: {
                    icon("clock", Color(hex: 0x8E8E93))
                }
            }
            Section {
                ForEach(list) { item in
                    Toggle(isOn: Binding(
                        get: { item.isOn },
                        set: { on in
                            var updated = ScreensaverWidget.decode(widgetsRaw)
                            if let index = updated.firstIndex(where: { $0.widget == item.widget }) { updated[index].isOn = on }
                            widgetsRaw = ScreensaverWidget.encode(updated)
                        }
                    )) {
                        Label {
                            Text(item.widget.title)
                        } icon: {
                            icon(item.widget.symbol, item.widget.tint)
                        }
                    }
                }
                .onMove { from, to in
                    var updated = ScreensaverWidget.decode(widgetsRaw)
                    updated.move(fromOffsets: from, toOffset: to)
                    widgetsRaw = ScreensaverWidget.encode(updated)
                }
            } footer: {
                Text("Drag to change the order they take turns in.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Cards")
    }

    private func icon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: .rect(cornerRadius: 7))
    }
}

/// The pictures: Caloma's wallpapers, the family's albums in Photos, and photos picked one by
/// one.
struct ScreensaverPhotosView: View {
    @AppStorage(SettingsKey.kioskScreensaverWallpapers) private var wallpapersRaw = Wallpaper.defaultSelection
    @AppStorage(SettingsKey.kioskScreensaverAlbums) private var albumsRaw = ""
    @AppStorage(SettingsKey.kioskScreensaverPhotos) private var photosRaw = ""
    @AppStorage(SettingsKey.kioskScreensaverSkipScreenshots) private var skipScreenshots = true
    @Environment(\.displayScale) private var displayScale

    @State private var library = ScreensaverLibrary.shared
    @State private var picking: [PhotosPickerItem] = []
    @State private var importing = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var wallpapers: Set<String> { Set(wallpapersRaw.split(separator: ",").map(String.init)) }
    private var albums: Set<String> { Set(albumsRaw.split(separator: ",").map(String.init)) }
    private var picked: [String] { photosRaw.split(separator: ",").map(String.init) }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Wallpaper.all) { wallpaper in
                        let on = wallpapers.contains(wallpaper.id)
                        Button {
                            wallpapersRaw = toggled(wallpaper.id, in: wallpapersRaw)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(wallpaper.thumbnail)
                                    .resizable()
                                    .aspectRatio(4 / 3, contentMode: .fill)
                                    .clipShape(.rect(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 3))
                                    .overlay(alignment: .topTrailing) { check(on) }
                                Text(wallpaper.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(wallpaper.title)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Caloma Wallpapers")
            } footer: {
                Text("Used whenever nothing else is picked.")
            }

            Section {
                if library.canReadAlbums {
                    if library.albums.isEmpty {
                        Text("No albums with photos yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.albums) { album in
                        let on = albums.contains(album.id)
                        Button {
                            albumsRaw = toggled(album.id, in: albumsRaw)
                        } label: {
                            HStack(spacing: 12) {
                                AlbumCover(assetID: album.coverID, scale: displayScale)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .foregroundStyle(Color.primary)
                                    Text("\(album.count.formatted()) photos")
                                        .font(.footnote)
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                            }
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    if library.status == .limited {
                        Text("Caloma can see only the photos you've shared with it. Change that in Settings › Apps › Caloma › Photos.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if library.status == .notDetermined {
                    Button("Show My Albums") {
                        Task { await library.requestAccess() }
                    }
                    .tint(.primary)
                } else {
                    Text("Caloma doesn't have access to Photos. Turn it on in Settings › Apps › Caloma › Photos, or pick photos below instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Skip Screenshots", isOn: $skipScreenshots)
            } header: {
                Text("Your Albums")
            } footer: {
                Text("New photos added to these albums join the slideshow on their own.")
            }

            Section {
                if !picked.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(picked, id: \.self) { name in
                            PickedThumb(name: name)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        remove(name)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(4)
                                    .accessibilityLabel("Remove photo")
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                PhotosPicker(selection: $picking, maxSelectionCount: 50, matching: .images) {
                    if importing {
                        HStack {
                            ProgressView()
                            Text("Adding Photos…")
                        }
                    } else {
                        Label("Add Photos", systemImage: "plus")
                    }
                }
                .tint(.primary)
                .disabled(importing)
            } header: {
                Text("Photos You Pick")
            } footer: {
                Text("Photos stay on this iPad. Caloma keeps its own copy of the ones you pick, so they show even without access to your library, and never uploads them.")
            }
        }
        .navigationTitle("Photos")
        .onAppear { library.loadAlbums() }
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                var added: [String] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let name = await Task.detached(operation: { ScreensaverLibrary.savePicked(data) }).value {
                        added.append(name)
                    }
                }
                // Read the list again now, in case a photo was removed while these loaded.
                photosRaw = (picked + added).joined(separator: ",")
                picking = []
                importing = false
            }
        }
    }

    private func check(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, on ? Color.accentColor : Color.black.opacity(0.3))
            .padding(6)
    }

    private func toggled(_ id: String, in raw: String) -> String {
        var list = raw.split(separator: ",").map(String.init)
        if let index = list.firstIndex(of: id) { list.remove(at: index) } else { list.append(id) }
        return list.joined(separator: ",")
    }

    private func remove(_ name: String) {
        photosRaw = picked.filter { $0 != name }.joined(separator: ",")
        ScreensaverLibrary.removePicked(name)
    }
}

/// An album's newest photo, small.
private struct AlbumCover: View {
    var assetID: String?
    var scale: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(.rect(cornerRadius: 8))
        .task(id: assetID) {
            guard let assetID else { return }
            image = await ScreensaverLibrary.shared.thumbnail(assetID: assetID, side: 52, scale: scale)
        }
    }
}

/// A picked photo, from Caloma's own copy.
private struct PickedThumb: View {
    var name: String
    @State private var image: UIImage?

    var body: some View {
        // A square that stays square once the photo loads.
        Color(.tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: 10))
        .task(id: name) {
            let url = ScreensaverLibrary.fileURL(name)
            image = await Task.detached {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 300, height: 300))
            }.value
        }
    }
}
