import AVFoundation
import QuartzCore
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

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        // The app frames faces itself; Center Stage would crop and move them.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
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
        let fps = max(framesPerSecond, 0.5)
        guard now - lastFrame >= 1 / fps, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let handler = onFrame else { return }
        lastFrame = now
        handler(buffer)
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
