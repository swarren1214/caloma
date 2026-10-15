import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

/// Caloma's side of sharing with the other Hearth apps on this device (see `HearthShared.swift`):
/// it shares the family, and shows BigTable's planned meals on Home and the calendar.
@MainActor
@Observable
final class HearthLink {
    static let shared = HearthLink()

    /// BigTable's plan, when BigTable is on this device and has shared one recently.
    private(set) var mealPlan: HearthMealPlan?

    /// BigTable's red, for its meals on the calendar.
    static let bigTableColor = Color(hex: 0xD9472B)

    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    /// Reads what's shared now and follows changes while Caloma is open.
    func start() {
        guard changeObserver == nil, !ScreenshotMode.isOn else { return }
        Hearth.startObservingChanges()
        changeObserver = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in HearthLink.shared.reload() }
        }
        reload()
    }

    /// Picks up BigTable's latest plan. A plan BigTable hasn't refreshed in two weeks (the app
    /// was deleted, or signed out without cleaning up) isn't shown.
    func reload() {
        guard !ScreenshotMode.isOn else { return }
        // Another app may have a new photo of someone.
        HearthPhotos.shared.reset()
        let plan = Hearth.read(HearthMealPlan.self, from: .bigtable, maxAge: 14 * 24 * 60 * 60)?.value
        guard plan != mealPlan else { return }
        mealPlan = plan
        // Tonight's dinner is on the widgets and the watch.
        WatchBridge.shared.setNeedsUpdate()
    }

    func dinner(on day: Date) -> HearthMealPlan.Meal? {
        mealPlan?.meal("dinner", on: day)
    }

    /// Tonight's dinner for the widgets and watch (`WatchBridge.snapshot(in:)`). When Caloma was
    /// woken in the background (a tap on the watch) before `start()`, the plan is read first so
    /// the snapshot doesn't drop it.
    func dinnerForSnapshot(on day: Date) -> HearthMealPlan.Meal? {
        if changeObserver == nil { reload() }
        return dinner(on: day)
    }

    // MARK: Sharing the family

    /// A photo already saved to the shared folder, and a cheap fingerprint of the one it came
    /// from, so publishing again (after every save) doesn't re-encode photos that haven't changed.
    private struct SharedPhotoFile {
        var fingerprint: PhotoFingerprint
        var file: String
    }

    private struct PhotoFingerprint: Equatable {
        var count: Int
        var hash: Int

        init(_ data: Data) {
            count = data.count
            hash = data.hashValue
        }
    }

    private static var sharedPhotoFiles: [UUID: SharedPhotoFile] = [:]
    /// The photo files kept last time, so old ones are cleaned up only when something changed.
    private static var keptPhotoFiles: Set<String>?

    /// Shares the family (names, parent or kid, their colors and photos, and who this device
    /// belongs to). Unchanged families aren't rewritten.
    static func publishFamily(in context: ModelContext) {
        guard !ScreenshotMode.isOn else { return }
        let members = Persistence.fetchAll(Member.self, in: context)
            .filter { !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
        var photoChanged = false
        let shared = members.map { member in
            let (photo, changed) = sharedPhoto(for: member)
            if changed { photoChanged = true }
            return HearthFamily.Member(
                id: member.id.uuidString,
                name: member.name,
                role: member.role.rawValue,
                colorHex: member.color.hex,
                birthday: nil,
                likes: nil,
                dislikes: nil,
                photo: photo
            )
        }
        let current = UserDefaults.standard.string(forKey: SettingsKey.currentMember)
        let me = shared.first(where: { $0.id == current })?.id
        let published = Hearth.publish(HearthFamily(name: nil, members: shared, dietaryRestrictions: nil, me: me), from: .caloma)
        // A new photo under the same file name doesn't change the family file, so say so.
        if photoChanged && !published { Hearth.postChange() }

        let keep = Set(shared.compactMap(\.photo))
        if keep != keptPhotoFiles {
            Hearth.removePhotos(from: .caloma, except: keep)
            keptPhotoFiles = keep
        }
        let ids = Set(members.map(\.id))
        sharedPhotoFiles = sharedPhotoFiles.filter { ids.contains($0.key) }
    }

    /// The member's photo in the shared folder (a JPEG of at most 512 px), and whether it was
    /// written just now.
    private static func sharedPhoto(for member: Member) -> (file: String?, changed: Bool) {
        guard let data = member.photoData else {
            sharedPhotoFiles[member.id] = nil
            return (nil, false)
        }
        let fingerprint = PhotoFingerprint(data)
        if let saved = sharedPhotoFiles[member.id], saved.fingerprint == fingerprint,
           let url = Hearth.photosDirectory?.appending(path: saved.file, directoryHint: .notDirectory),
           FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return (saved.file, false)
        }
        guard let image = UIImage(data: data),
              let jpeg = PhotoTools.jpeg(from: image, maxSide: 512, quality: 0.8),
              let file = Hearth.savePhoto(jpeg, memberID: member.id.uuidString, from: .caloma) else {
            sharedPhotoFiles[member.id] = nil
            return (nil, false)
        }
        sharedPhotoFiles[member.id] = SharedPhotoFile(fingerprint: fingerprint, file: file)
        return (file, true)
    }
}

/// Photos the other Hearth apps have of people who don't have one in Caloma (BigTable's photo
/// of Grandma, Hearken's of the person who signed in), by name. Each name is read from the
/// shared folder once and kept until another app shares something (`HearthLink.reload()`), so
/// drawing an avatar never touches the disk.
@MainActor
@Observable
final class HearthPhotos {
    static let shared = HearthPhotos()

    /// Bumped when the cache is cleared, so avatars that showed a shared photo redraw.
    private var generation = 0
    /// By normalized name; a nil image means there's no shared photo for that name.
    @ObservationIgnored private var images: [String: UIImage?] = [:]

    func image(forName name: String) -> UIImage? {
        _ = generation
        guard !ScreenshotMode.isOn else { return nil }
        let key = HearthNames.normalized(name)
        guard !key.isEmpty else { return nil }
        if let cached = images[key] { return cached }
        let image = Hearth.sharedPhoto(forName: name, excluding: .caloma).flatMap { UIImage(data: $0) }
        images.updateValue(image, forKey: key)
        return image
    }

    func reset() {
        guard !images.isEmpty else { return }
        images = [:]
        generation += 1
    }
}

extension HearthMealPlan.Meal {
    /// "Not eating: Sam, Ava", or nil when everyone is.
    var notEatingLabel: String? {
        guard let names = notEating, !names.isEmpty else { return nil }
        return "Not eating: " + names.formatted(.list(type: .and))
    }

    var symbol: String { kind == "dineOut" ? "takeoutbag.and.cup.and.straw" : "fork.knife" }

    var openURL: URL? { link.flatMap(URL.init(string:)) }
}

/// Tonight's dinner from BigTable, on Home. Shows nothing when there's no plan for tonight.
struct DinnerTonightCard: View {
    @Environment(\.openURL) private var openURL
    private var link: HearthLink { HearthLink.shared }

    var body: some View {
        if let dinner = link.dinner(on: .now) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Dinner Tonight")
                CardList(items: [dinner], inset: 58) { meal in
                    Button {
                        if let url = meal.openURL { openURL(url) }
                    } label: {
                        row(meal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens in BigTable")
                }
            }
        }
    }

    private func row(_ meal: HearthMealPlan.Meal) -> some View {
        HStack(spacing: 12) {
            Image(systemName: meal.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(HearthLink.bigTableColor)
                .frame(width: 34, height: 34)
                .background(HearthLink.bigTableColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.title)
                    .lineLimit(2)
                Text(meal.notEatingLabel ?? "From BigTable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}
