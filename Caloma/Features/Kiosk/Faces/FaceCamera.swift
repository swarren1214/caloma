import AVFoundation
import ImageIO
import QuartzCore
import SwiftUI
import UIKit

/// The iPad's front camera, for faces in Kiosk Mode. Frames arrive on a background queue,
/// turned upright, and are handed on a few times a second. Nothing is recorded or kept.
nonisolated final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let device: AVCaptureDevice? = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)

    private let queue = DispatchQueue(label: "com.stephenwarren.caloma.faces.camera")
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var lastFrame: CFTimeInterval = 0
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    private let lock = NSLock()
    private var _framesPerSecond: Double = 6
    private var _onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var _onPresence: (@Sendable (_ motion: Bool, _ brightness: Double?) -> Void)?

    /// Faces and the wall's dimming share the camera; it runs while either needs it.
    private var users: Set<String> = []
    private var lastPresence: CFTimeInterval = 0
    private var previousGrid: [UInt8] = []

    /// How many frames a second are handed on. Lower at night.
    var framesPerSecond: Double {
        get { lock.withLock { _framesPerSecond } }
        set { lock.withLock { _framesPerSecond = newValue } }
    }

    /// Called on the camera's queue with each frame that's handed on.
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Called on the camera's queue twice a second: whether anything moved, and how bright the
    /// room is (the camera's own brightness reading, in APEX stops: about 0 in a dim room,
    /// 5 or more in a bright one).
    var onPresence: (@Sendable (_ motion: Bool, _ brightness: Double?) -> Void)? {
        get { lock.withLock { _onPresence } }
        set { lock.withLock { _onPresence = newValue } }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(_ user: String = "faces") {
        queue.async { [self] in
            users.insert(user)
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop(_ user: String = "faces") {
        queue.async { [self] in
            users.remove(user)
            if users.isEmpty, session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        // The app frames faces itself; Center Stage would crop and move them.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Full HD: someone standing back from a wall iPad still has a face big enough to
        // identify (at 640×480 a face across the room was a few dozen pixels).
        for preset: AVCaptureSession.Preset in [.hd1920x1080, .hd1280x720, .vga640x480] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        configured = true

        // Keep frames upright as the iPad turns, so faces read the right way up.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.queue.async { [weak self] in self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let presence = onPresence, now - lastPresence >= 0.5 {
            lastPresence = now
            presence(moved(buffer), roomBrightness(sampleBuffer))
        }
        let fps = max(framesPerSecond, 0.5)
        guard now - lastFrame >= 1 / fps, let handler = onFrame else { return }
        lastFrame = now
        handler(buffer)
    }

    /// Compares a coarse 32×24 grid of the frame with the last one. Movement is when more
    /// than 6% of the cells change noticeably.
    private func moved(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let columns = 32, rows = 24
        var grid = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let y = min(height - 1, row * height / rows + height / (rows * 2))
            for column in 0..<columns {
                let x = min(width - 1, column * width / columns + width / (columns * 2))
                // BGRA: the green channel stands in for brightness.
                grid[row * columns + column] = pixels[y * bytesPerRow + x * 4 + 1]
            }
        }
        defer { previousGrid = grid }
        guard previousGrid.count == grid.count else { return false }
        var changed = 0
        for index in grid.indices where abs(Int(grid[index]) - Int(previousGrid[index])) > 18 {
            changed += 1
        }
        return Double(changed) / Double(grid.count) > 0.06
    }

    /// The scene's brightness value from the frame's EXIF data.
    private func roomBrightness(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any],
              let exif = attachments[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        return (exif[kCGImagePropertyExifBrightnessValue as String] as? NSNumber)?.doubleValue
    }
}

/// The live camera in a circle for face setup, mirrored like the Camera app's selfie view.
struct FaceCameraPreview: UIViewRepresentable {
    var camera: FaceCamera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let device = camera.device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: view.previewLayer)
            view.coordinator = coordinator
            view.observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak view] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { [weak view] in view?.apply(angle) }
            }
        }
        // The preview's connection only exists once the session runs; turn it then.
        view.token = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: camera.session, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.reapply() }
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var coordinator: AVCaptureDevice.RotationCoordinator?
        var observation: NSKeyValueObservation?
        var token: NSObjectProtocol?
        private var angle: CGFloat = 0

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        func reapply() { apply(angle) }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reapply()
        }

        func apply(_ angle: CGFloat) {
            self.angle = angle
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The connection appears once the session is running.
            apply(angle)
        }
    }
}
