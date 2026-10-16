import ImageIO
import Photos
import SwiftUI
import UIKit

// The Family Board's screensaver: what it shows and how, kept on this iPad (each wall can be
// set up differently). Photos come from Caloma's own wallpapers, the family's albums in Photos,
// and photos picked one by one (copied into Caloma, so they keep working without full Photos
// access).

/// A card that takes its turn on the screensaver.
nonisolated enum ScreensaverWidget: String, CaseIterable, Identifiable {
    case upNext, dinner, countdown, stars, home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upNext: "Up Next"
        case .dinner: "Dinner Tonight"
        case .countdown: "Countdowns"
        case .stars: "\(PointWords.current().title) This Week"
        case .home: "Home Status"
        }
    }

    var symbol: String {
        switch self {
        case .upNext: "calendar"
        case .dinner: "fork.knife"
        case .countdown: "hourglass"
        case .stars: PointWords.current().symbol
        case .home: "house.fill"
        }
    }

    var tint: Color {
        switch self {
        case .upNext: Color(hex: 0xAF52DE)
        case .dinner: Color(hex: 0xFF9F0A)
        case .countdown: Color(hex: 0xE0457B)
        case .stars: Color(hex: 0xFFD60A)
        case .home: Color(hex: 0x30D158)
        }
    }

    /// "upNext,dinner,-countdown": the order, with a minus for the ones turned off.
    static let defaultOrder = allCases.map(\.rawValue).joined(separator: ",")

    static func decode(_ raw: String) -> [ScreensaverWidgetSetting] {
        var seen = Set<ScreensaverWidget>()
        var list: [ScreensaverWidgetSetting] = []
        for part in raw.split(separator: ",") {
            let off = part.hasPrefix("-")
            guard let widget = ScreensaverWidget(rawValue: String(off ? part.dropFirst() : part)), !seen.contains(widget) else { continue }
            seen.insert(widget)
            list.append(ScreensaverWidgetSetting(widget: widget, isOn: !off))
        }
        // Anything new since this was saved goes on the end, on.
        for widget in allCases where !seen.contains(widget) {
            list.append(ScreensaverWidgetSetting(widget: widget, isOn: true))
        }
        return list
    }

    static func encode(_ list: [ScreensaverWidgetSetting]) -> String {
        list.map { ($0.isOn ? "" : "-") + $0.widget.rawValue }.joined(separator: ",")
    }
}

/// A card and whether it's on.
nonisolated struct ScreensaverWidgetSetting: Identifiable {
    var widget: ScreensaverWidget
    var isOn: Bool
    var id: ScreensaverWidget { widget }
}

/// Where the cards sit.
nonisolated enum ScreensaverStyle: String, CaseIterable, Identifiable {
    case corner, panel
    var id: String { rawValue }
    var title: String { self == .corner ? "Corner Card" : "Side Panel" }
}

/// What a person waking the screensaver sees.
nonisolated enum ScreensaverWakeTo: String, CaseIterable, Identifiable {
    case person, calendar
    var id: String { rawValue }
    var title: String { self == .person ? "Their Screen" : "Family Calendar" }
}

/// One of Caloma's own screensaver pictures, in the asset catalog.
nonisolated struct Wallpaper: Identifiable, Hashable {
    let id: String
    let title: String
    var thumbnail: String { id + "-thumb" }

    static let all: [Wallpaper] = [
        Wallpaper(id: "wallpaper-dusk-lake", title: "Dusk Lake"),
        Wallpaper(id: "wallpaper-alpine-morning", title: "Alpine Morning"),
        Wallpaper(id: "wallpaper-red-rock", title: "Red Rock"),
        Wallpaper(id: "wallpaper-northern-lights", title: "Northern Lights"),
        Wallpaper(id: "wallpaper-ocean-calm", title: "Ocean Calm"),
        Wallpaper(id: "wallpaper-autumn-hills", title: "Autumn Hills"),
        Wallpaper(id: "wallpaper-hearth-glow", title: "Hearth Glow"),
        Wallpaper(id: "wallpaper-milky-way", title: "Milky Way"),
    ]

    static let defaultSelection = all.map(\.id).joined(separator: ",")
}

/// The screensaver's settings, read where @AppStorage isn't handy.
nonisolated enum ScreensaverPrefs {
    private static var defaults: UserDefaults { .standard }

    static var isOn: Bool { defaults.object(forKey: SettingsKey.kioskScreensaver) as? Bool ?? true }
    static var startMinutes: Int {
        let value = defaults.integer(forKey: SettingsKey.kioskScreensaverMinutes)
        return value > 0 ? value : 5
    }
    static var photoSeconds: Int {
        let value = defaults.integer(forKey: SettingsKey.kioskScreensaverPhotoSeconds)
        return value > 0 ? value : 15
    }
    static var shuffle: Bool { defaults.object(forKey: SettingsKey.kioskScreensaverShuffle) as? Bool ?? true }
    static var slowZoom: Bool { defaults.object(forKey: SettingsKey.kioskScreensaverZoom) as? Bool ?? true }
    static var wakesOnWalkUp: Bool { defaults.object(forKey: SettingsKey.kioskScreensaverWakeOnMotion) as? Bool ?? true }
    static var wakeTo: ScreensaverWakeTo {
        ScreensaverWakeTo(rawValue: defaults.string(forKey: SettingsKey.kioskScreensaverWakeTo) ?? "") ?? .person
    }
    static var nightClock: Bool { defaults.object(forKey: SettingsKey.kioskScreensaverNight) as? Bool ?? true }
    static var skipScreenshots: Bool { defaults.object(forKey: SettingsKey.kioskScreensaverSkipScreenshots) as? Bool ?? true }

    static func list(_ key: String, default value: String = "") -> [String] {
        (defaults.string(forKey: key) ?? value).split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// 10 PM to 6 AM.
    static func isNight(_ date: Date = .now) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 22 || hour < 6
    }
}

/// One picture in the slideshow.
nonisolated enum ScreensaverSlide: Hashable, Sendable {
    case wallpaper(String)
    case asset(String)
    case file(String)
}

/// The family's photos for the screensaver: their albums in Photos (with permission) and the
/// photos picked one by one, which are copied into Caloma.
@MainActor
@Observable
final class ScreensaverLibrary {
    static let shared = ScreensaverLibrary()

    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
        let count: Int
        let coverID: String?
    }

    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var albums: [Album] = []

    var canReadAlbums: Bool { status == .authorized || status == .limited }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        loadAlbums()
    }

    /// Favorites first, then the family's own albums and shared albums, largest first.
    func loadAlbums() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canReadAlbums else {
            albums = []
            return
        }
        var found: [Album] = []
        let images = PHFetchOptions()
        images.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        images.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let add = { (collection: PHAssetCollection) in
            let assets = PHAsset.fetchAssets(in: collection, options: images)
            guard assets.count > 0 else { return }
            found.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album", count: assets.count, coverID: assets.firstObject?.localIdentifier))
        }
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil).enumerateObjects { collection, _, _ in add(collection) }
        let before = found.count
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in add(collection) }
        let own = Array(found[before...]).sorted { $0.count > $1.count }
        albums = Array(found[..<before]) + own
    }

    /// Every photo in these albums, without screenshots when asked. PhotoKit is fine off the
    /// main thread, and a big album takes a moment.
    nonisolated static func assetIDs(inAlbums ids: [String], skipScreenshots: Bool) -> [String] {
        guard !ids.isEmpty else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
        let images = PHFetchOptions()
        images.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: images).enumerateObjects { asset, _, _ in
                if skipScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return }
                if seen.insert(asset.localIdentifier).inserted { result.append(asset.localIdentifier) }
            }
        }
        return result
    }

    /// Everything the slideshow should show right now, in order (shuffled when asked).
    func slides() async -> [ScreensaverSlide] {
        var slides: [ScreensaverSlide] = []
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if canReadAlbums {
            let albums = ScreensaverPrefs.list(SettingsKey.kioskScreensaverAlbums)
            let skip = ScreensaverPrefs.skipScreenshots
            let ids = await Task.detached(priority: .utility) { Self.assetIDs(inAlbums: albums, skipScreenshots: skip) }.value
            slides += ids.map { .asset($0) }
        }
        slides += ScreensaverPrefs.list(SettingsKey.kioskScreensaverPhotos).filter { FileManager.default.fileExists(atPath: Self.fileURL($0).path) }.map { .file($0) }
        let walls = ScreensaverPrefs.list(SettingsKey.kioskScreensaverWallpapers, default: Wallpaper.defaultSelection)
        slides += Wallpaper.all.filter { walls.contains($0.id) }.map { .wallpaper($0.id) }
        if slides.isEmpty {
            // Nothing picked: Caloma's own pictures.
            slides = Wallpaper.all.map { .wallpaper($0.id) }
        }
        return ScreensaverPrefs.shuffle ? slides.shuffled() : slides
    }

    // MARK: Images

    /// A photo sized to fill `size` points at the screen's `scale`.
    func image(for slide: ScreensaverSlide, size: CGSize, scale: CGFloat) async -> UIImage? {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        switch slide {
        case .wallpaper(let name):
            return await Task.detached(priority: .userInitiated) {
                UIImage(named: name)?.preparingForDisplay()
            }.value
        case .file(let name):
            let url = Self.fileURL(name)
            return await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)?.preparingForDisplay()
            }.value
        case .asset(let id):
            return await assetImage(id, pixels: pixels, contentMode: .aspectFill)
        }
    }

    func thumbnail(assetID: String, side: CGFloat, scale: CGFloat) async -> UIImage? {
        return await assetImage(assetID, pixels: CGSize(width: side * scale, height: side * scale), contentMode: .aspectFill)
    }

    private func assetImage(_ id: String, pixels: CGSize, contentMode: PHImageContentMode) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: pixels, contentMode: contentMode, options: options) { @Sendable image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: Photos picked one by one

    /// Caloma's own copies of picked photos, in Application Support.
    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Screensaver", isDirectory: true)
    }

    nonisolated static func fileURL(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// Saves a picked photo, scaled to the largest iPad screen, and returns its file name. It's
    /// read at that size straight from the file, so a 48-megapixel photo never fills memory.
    nonisolated static func savePicked(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2732,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: scaled).jpegData(compressionQuality: 0.88) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".jpg"
            try jpeg.write(to: fileURL(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            return nil
        }
    }

    nonisolated static func removePicked(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
    }

    /// Erase All: every picked photo.
    nonisolated static func eraseAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}
