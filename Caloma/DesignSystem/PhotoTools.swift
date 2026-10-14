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

/// An avatar you tap to pick a photo for. The photo opens in Move and Scale so it can be
/// cropped to the circle before it's used.
struct PhotoPickerAvatar: View {
    var name: String
    var color: Color
    @Binding var photo: Data?
    var size: CGFloat = 44

    @State private var item: PhotosPickerItem?
    @State private var cropping: CropRequest?

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
            guard newItem != nil else { return }
            Task {
                if let image = await PhotoTools.load(newItem) {
                    cropping = CropRequest(image: image)
                }
                // Clear it, so picking the same photo again still opens the crop.
                item = nil
            }
        }
        .fullScreenCover(item: $cropping) { request in
            AvatarCropView(image: request.image) { data in
                photo = data
                cropping = nil
            } onCancel: {
                cropping = nil
            }
        }
    }
}

/// A photo waiting to be cropped.
struct CropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Move and Scale: drag and pinch the photo inside a circle, like Contacts, then Choose.
/// Saves a 600 px square JPEG of what's inside the circle.
struct AvatarCropView: View {
    var image: UIImage
    var onChoose: (Data) -> Void
    var onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) - 48
            let base = baseScale(for: diameter)
            let shown = CGSize(width: image.size.width * base * scale, height: image.size.height * base * scale)
            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(offset)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                // Dim everything outside the circle.
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .reverseMask {
                        Circle()
                            .frame(width: diameter, height: diameter)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                    .allowsHitTesting(false)
                Circle()
                    .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .allowsHitTesting(false)

                VStack {
                    Text("Move and Scale")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.top, 12)
                    Spacer()
                    HStack(spacing: 14) {
                        Button {
                            onCancel()
                        } label: {
                            Text("Cancel").frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.glass)
                        Button {
                            if let data = crop(diameter: diameter, base: base) { onChoose(data) }
                        } label: {
                            Text("Choose").frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = clamped(CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height), diameter: diameter, base: base, scale: scale)
                        }
                        .onEnded { _ in lastOffset = offset },
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value.magnification, 1), maxScale)
                            offset = clamped(offset, diameter: diameter, base: base, scale: scale)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            lastOffset = offset
                        }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.35)) {
                    scale = scale > 1.01 ? 1 : 2
                    lastScale = scale
                    offset = clamped(offset, diameter: diameter, base: base, scale: scale)
                    lastOffset = offset
                }
            }
        }
        .statusBarHidden()
        .accessibilityElement(children: .contain)
    }

    /// The scale at which the photo just fills the circle.
    private func baseScale(for diameter: CGFloat) -> CGFloat {
        diameter / max(min(image.size.width, image.size.height), 1)
    }

    /// Keeps the circle covered by the photo.
    private func clamped(_ proposed: CGSize, diameter: CGFloat, base: CGFloat, scale: CGFloat) -> CGSize {
        let width = image.size.width * base * scale
        let height = image.size.height * base * scale
        let maxX = max((width - diameter) / 2, 0)
        let maxY = max((height - diameter) / 2, 0)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }

    /// What's inside the circle, as a square JPEG.
    private func crop(diameter: CGFloat, base: CGFloat, side: CGFloat = 600) -> Data? {
        let total = base * scale
        // The circle's top-left corner in the photo's own coordinates.
        let cropSide = diameter / total
        let originX = (image.size.width - cropSide) / 2 - offset.width / total
        let originY = (image.size.height - cropSide) / 2 - offset.height / total
        let k = side / cropSide
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let result = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: -originX * k, y: -originY * k, width: image.size.width * k, height: image.size.height * k))
        }
        return result.jpegData(compressionQuality: 0.85)
    }
}

extension View {
    /// Cuts `mask` out of this view.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        let hole = mask()
        return self.mask {
            Rectangle()
                .overlay {
                    hole.blendMode(.destinationOut)
                }
                .compositingGroup()
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
