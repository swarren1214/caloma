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

/// Apple's own tool palette (pens, markers, widths, colors, eraser, lasso, ruler, undo) for a
/// canvas. It remembers the last tools used, and handles Pencil double-tap and squeeze the way
/// the person has set them up.
struct PencilToolPicker: Equatable {
    /// Hidden while a sheet or alert is up, so it doesn't sit over it.
    var isVisible = true
}

/// The paper Pencil writing sits on: near-white by day, near-black in dark mode so a late-night
/// whiteboard isn't blinding. Ink is always saved in its light colors; PencilKit shows black ink
/// as white (and lightens dark colors) on the dark paper.
enum PencilPaper {
    static let color = Color(light: 0xFEFEFC, dark: 0x1C1C1E)
    /// Dots and ruled lines.
    static let marks = Color.primary.opacity(0.09)
    static let border = Color.primary.opacity(0.08)
    /// "Draw anything", "What's happening?"
    static let hint = Color.primary.opacity(0.22)
}

/// A PencilKit drawing surface. It follows the appearance around it: dark paper and a dark tool
/// palette in dark mode (wrap it in a light color scheme to keep it light, as wall notes'
/// yellow paper does). With the iPad's "Only Draw with Apple Pencil" setting
/// on, fingers scroll and tap instead of drawing. A double-tap (or squeeze) on the Pencil calls
/// `onPencilTap`, usually to switch between pen and eraser.
struct PencilCanvas: View {
    @Binding var drawing: PKDrawing
    var tool: PencilTool
    var onPencilTap: (() -> Void)?
    /// When the person starts or stops touching it, to pause things like the idle timer.
    var onDrawingChange: ((Bool) -> Void)? = nil
    /// With Apple's tool palette, `tool` and `onPencilTap` are ignored: the palette picks.
    var toolPicker: PencilToolPicker? = nil

    var body: some View {
        PencilCanvasView(drawing: $drawing, tool: tool, onPencilTap: onPencilTap, onDrawingChange: onDrawingChange, toolPicker: toolPicker)
    }
}

private struct PencilCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var tool: PencilTool
    var onPencilTap: (() -> Void)?
    var onDrawingChange: ((Bool) -> Void)?
    var toolPicker: PencilToolPicker?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ResponderCanvasView {
        let canvas = ResponderCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        let style = Self.style(context.environment.colorScheme)
        canvas.overrideUserInterfaceStyle = style
        canvas.drawingPolicy = .default
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        if toolPicker != nil {
            let picker = PKToolPicker()
            // The palette and its colors match the paper.
            picker.colorUserInterfaceStyle = style
            picker.overrideUserInterfaceStyle = style
            picker.stateAutosaveName = "caloma.whiteboard"
            picker.addObserver(canvas)
            context.coordinator.picker = picker
            canvas.wantsToolPicker = true
        } else {
            canvas.tool = tool.pkTool
            canvas.addInteraction(UIPencilInteraction(delegate: context.coordinator))
            context.coordinator.lastTool = tool
        }
        context.coordinator.lastSynced = drawing
        return canvas
    }

    /// Light or dark, from SwiftUI's color scheme around the canvas.
    static func style(_ scheme: ColorScheme) -> UIUserInterfaceStyle {
        scheme == .dark ? .dark : .light
    }

    func updateUIView(_ canvas: ResponderCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Follows a switch between light and dark while it's open.
        let style = Self.style(context.environment.colorScheme)
        if canvas.overrideUserInterfaceStyle != style {
            canvas.overrideUserInterfaceStyle = style
            coordinator.picker?.colorUserInterfaceStyle = style
            coordinator.picker?.overrideUserInterfaceStyle = style
        }
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
        if let picker = coordinator.picker {
            let visible = toolPicker?.isVisible ?? false
            canvas.wantsToolPicker = visible
            picker.setVisible(visible, forFirstResponder: canvas)
            if visible, canvas.window != nil, !canvas.isFirstResponder {
                canvas.becomeFirstResponder()
            }
        } else if coordinator.lastTool != tool {
            canvas.tool = tool.pkTool
            coordinator.lastTool = tool
        }
    }

    static func dismantleUIView(_ canvas: ResponderCanvasView, coordinator: Coordinator) {
        if let picker = coordinator.picker {
            picker.setVisible(false, forFirstResponder: canvas)
            picker.removeObserver(canvas)
        }
        canvas.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: PencilCanvasView
        var lastTool: PencilTool?
        var picker: PKToolPicker?
        /// The drawing last passed between the canvas and SwiftUI.
        var lastSynced = PKDrawing()
        /// Set while SwiftUI pushes a drawing in, so it isn't echoed straight back.
        var isApplying = false

        init(_ parent: PencilCanvasView) {
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

/// A canvas that takes first responder when it reaches the window, which Apple's tool palette
/// needs to show.
private final class ResponderCanvasView: PKCanvasView {
    var wantsToolPicker = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard wantsToolPicker, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsToolPicker, self.window != nil else { return }
            self.becomeFirstResponder()
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

    /// The ink alone (transparent around it), at the drawing's own size: in light colors, or as
    /// it shows on dark paper.
    func inkImage(in rect: CGRect? = nil, scale: CGFloat = 2, dark: Bool = false) -> UIImage? {
        guard !strokes.isEmpty else { return nil }
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            ink = image(from: rect ?? bounds.insetBy(dx: -8, dy: -8), scale: scale)
        }
        return ink
    }
}
