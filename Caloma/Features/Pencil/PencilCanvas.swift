import PencilKit
import SwiftUI
import UIKit

/// What the Pencil draws with.
enum PencilTool: Equatable {
    case pen(Color, width: CGFloat)
    case eraser

    var pkTool: PKTool {
        switch self {
        case .pen(let color, let width):
            PKInkingTool(.pen, color: UIColor(color), width: width)
        case .eraser:
            PKEraserTool(.vector)
        }
    }
}

/// A PencilKit drawing surface. Always drawn on light paper, so ink looks the same in dark mode
/// and on the wall as it does in a note. With the iPad's "Only Draw with Apple Pencil" setting
/// on, fingers scroll and tap instead of drawing. A double-tap (or squeeze) on the Pencil calls
/// `onPencilTap`, usually to switch between pen and eraser.
struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var tool: PencilTool
    var onPencilTap: (() -> Void)?
    /// When the person starts or stops touching it, to pause things like the idle timer.
    var onDrawingChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .default
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.drawing = drawing
        canvas.tool = tool.pkTool
        canvas.delegate = context.coordinator
        canvas.addInteraction(UIPencilInteraction(delegate: context.coordinator))
        context.coordinator.lastTool = tool
        context.coordinator.lastSynced = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // The canvas owns the ink. Only push a drawing in when SwiftUI changed it on purpose
        // (another board, Clear, Undo, a sync) — never because the view redrew with a copy from
        // before the stroke that just finished, which would wipe that stroke.
        if drawing != coordinator.lastSynced {
            coordinator.lastSynced = drawing
            if canvas.drawing != drawing {
                coordinator.isApplying = true
                canvas.drawing = drawing
                coordinator.isApplying = false
            }
        }
        if context.coordinator.lastTool != tool {
            canvas.tool = tool.pkTool
            context.coordinator.lastTool = tool
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: PencilCanvas
        var lastTool: PencilTool?
        /// The drawing last passed between the canvas and SwiftUI.
        var lastSynced = PKDrawing()
        /// Set while SwiftUI pushes a drawing in, so it isn't echoed straight back.
        var isApplying = false

        init(_ parent: PencilCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplying else { return }
            let drawing = canvasView.drawing
            lastSynced = drawing
            if parent.drawing != drawing { parent.drawing = drawing }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            parent.onDrawingChange?(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            parent.onDrawingChange?(false)
        }

        // Follows the person's Apple Pencil settings: a double-tap set to "Ignore" does nothing,
        // and a squeeze only switches tools when it's set to.
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            guard UIPencilInteraction.preferredTapAction != .ignore else { return }
            parent.onPencilTap?()
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            let action = UIPencilInteraction.preferredSqueezeAction
            guard squeeze.phase == .ended, action == .switchEraser || action == .switchPrevious else { return }
            parent.onPencilTap?()
        }
    }
}

extension PKDrawing {
    /// From saved data; empty when there's none or it can't be read.
    init(savedData data: Data?) {
        if let data, !data.isEmpty, let drawing = try? PKDrawing(data: data) {
            self = drawing
        } else {
            self = PKDrawing()
        }
    }

    var hasInk: Bool { !strokes.isEmpty }

    /// The ink on white, in light colors, cropped to what's drawn with a margin. For showing a
    /// note and for reading handwriting.
    func paperImage(scale: CGFloat = 2, margin: CGFloat = 24, background: UIColor = .white) -> UIImage? {
        guard !strokes.isEmpty else { return nil }
        let rect = bounds.insetBy(dx: -margin, dy: -margin)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
    }

    /// The ink alone (transparent around it), in light colors, at the drawing's own size.
    func inkImage(in rect: CGRect? = nil, scale: CGFloat = 2) -> UIImage? {
        guard !strokes.isEmpty else { return nil }
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = image(from: rect ?? bounds.insetBy(dx: -8, dy: -8), scale: scale)
        }
        return ink
    }
}
