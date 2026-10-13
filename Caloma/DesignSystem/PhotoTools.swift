import PhotosUI
import SwiftUI
import UIKit

/// Photos kept small: profile pictures and chore proof are scaled down to a JPEG before they're
/// saved, so the store (and iCloud) stays light.
enum PhotoTools {
    /// Scales the longest side down to `maxSide` and encodes as JPEG.
    static func jpeg(from image: UIImage, maxSide: CGFloat = 1200, quality: CGFloat = 0.75) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// A square crop from the middle, for avatars.
    static func avatar(from image: UIImage, side: CGFloat = 400) -> Data? {
        let size = image.size
        let edge = min(size.width, size.height)
        let crop = CGRect(x: (size.width - edge) / 2, y: (size.height - edge) / 2, width: edge, height: edge)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: -crop.minX * side / edge, y: -crop.minY * side / edge, width: size.width * side / edge, height: size.height * side / edge))
        }
        return square.jpegData(compressionQuality: 0.8)
    }

    static func load(_ item: PhotosPickerItem?) async -> UIImage? {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return UIImage(data: data)
    }
}

/// An avatar you tap to pick a photo for.
struct PhotoPickerAvatar: View {
    var name: String
    var color: Color
    @Binding var photo: Data?
    var size: CGFloat = 44

    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            MemberAvatar(name: name.isEmpty ? "?" : name, color: color, photo: photo, size: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: size * 0.2))
                        .foregroundStyle(.white)
                        .padding(size * 0.08)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .opacity(photo == nil ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo == nil ? "Add a photo" : "Change photo")
        .onChange(of: item) { _, newItem in
            Task {
                if let image = await PhotoTools.load(newItem) {
                    photo = PhotoTools.avatar(from: image)
                }
            }
        }
    }
}

/// The camera, for chore photos. Falls back to the photo library where there's no camera
/// (the Simulator).
struct CameraPicker: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = Self.hasCamera ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
