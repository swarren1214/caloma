import Accelerate
import CoreImage
import CoreML
import Vision

/// One look at the camera: the biggest face (where it is, which way it's turned, how clear it
/// is), how many faces there were, and the face's embedding when it was clear enough.
nonisolated struct FaceReading: @unchecked Sendable {
    var faceCount: Int
    /// Vision's normalized box, origin at the bottom left.
    var box: CGRect = .zero
    /// Degrees. Yaw is turning left or right, pitch is nodding.
    var yaw: Double = 0
    var pitch: Double = 0
    /// 0…1, from Vision's face capture quality.
    var quality: Double = 0
    var embedding: [Float]?
    var at: Date = .now
    /// The face's height in camera pixels; too few and there's not enough face to identify.
    var pixelHeight: CGFloat = 0
    /// Whether this is the face the wall is following (always true when it isn't following
    /// anyone). False means the followed person wasn't in this frame.
    var onTarget = true

    static let nobody = FaceReading(faceCount: 0)
    var hasFace: Bool { faceCount > 0 }
}

/// Finds faces with Vision, lines the clearest one up the way the face model learned faces
/// (eye corners and the bottom of the nose in fixed places), and turns it into an embedding.
///
/// Each look is embedded twice, as seen and mirrored, and the two averaged: the model's small
/// left-right quirks cancel out, which steadies the numbers for free. Face setup goes further
/// and also averages a few slightly turned and resized versions of each look.
nonisolated enum FaceAnalyzer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Embeddings are only made from faces at least this clear.
    static let minimumQuality = 0.25
    /// ...and at least this many camera pixels tall. The face model works on a 150-pixel chip;
    /// much smaller than this and it's guessing.
    static let minimumFacePixels: CGFloat = 64

    /// Small turns (radians) and resizes for face setup, so each saved look is an average of
    /// nearby views rather than one exact frame.
    private static let setupJitters: [(turn: CGFloat, size: CGFloat)] = [(0.05, 1), (-0.05, 1), (0, 1.05)]

    /// `target` is where the person the wall is following was last seen: their face is read
    /// even when someone else is bigger in the frame, so the wall doesn't jump between people.
    static func read(_ buffer: CVPixelBuffer, embedder: any FaceEmbedding, forSetup: Bool = false, target: CGRect? = nil) -> FaceReading {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        try? handler.perform([rectangles])
        guard let faces = rectangles.results, !faces.isEmpty else { return FaceReading(faceCount: 0, onTarget: target == nil) }
        let biggest = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height } ?? faces[0]
        var face = biggest
        var onTarget = true
        if let target {
            let followed = faces.map { ($0, overlap($0.boundingBox, target)) }.max { $0.1 < $1.1 }
            if let followed, followed.1 >= 0.1 {
                face = followed.0
            } else {
                onTarget = false
            }
        }

        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = [face]
        try? handler.perform([qualityRequest])
        let quality = Double(qualityRequest.results?.first?.faceCaptureQuality ?? 0)

        var reading = FaceReading(faceCount: faces.count)
        reading.box = face.boundingBox
        reading.yaw = (face.yaw?.doubleValue ?? 0) * 180 / .pi
        reading.pitch = (face.pitch?.doubleValue ?? 0) * 180 / .pi
        reading.quality = quality
        reading.onTarget = onTarget
        reading.pixelHeight = face.boundingBox.height * CGFloat(CVPixelBufferGetHeight(buffer))
        guard quality >= minimumQuality, reading.pixelHeight >= minimumFacePixels else { return reading }

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = [face]
        try? handler.perform([landmarks])
        guard let marked = landmarks.results?.first, let points = FaceAlignment.fivePoints(marked) else { return reading }

        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        let inPixels = points.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) }
        guard let base = FaceAlignment.transform(to: inPixels, size: embedder.chipSize, padding: embedder.chipPadding) else { return reading }

        var views: [CGAffineTransform] = [base]
        if forSetup {
            views += setupJitters.map { FaceAlignment.jittered(base, turn: $0.turn, size: $0.size, chip: embedder.chipSize) }
        }
        var embeddings: [[Float]] = []
        for view in views {
            guard let chip = chip(image, view, size: embedder.chipSize) else { continue }
            if let seen = embedder.embed(chip) { embeddings.append(seen) }
            if let mirrored = mirror(chip), let flipped = embedder.embed(mirrored) { embeddings.append(flipped) }
        }
        guard let face = FaceMath.centroid(embeddings) else { return reading }
        // The head print: Apple's on-device image feature print of the face with hair and a
        // little room, lined up the same way. It sees what the face model ignores (hair,
        // face shape, colouring), which is often what tells brothers and sisters apart.
        var head: [Float]?
        if embedder.addsHeadPrint, let headChip = chip(image, FaceAlignment.headView(base, chip: embedder.chipSize), size: HeadPrint.size) {
            head = FaceMath.centroid([HeadPrint.embed(headChip), mirror(headChip).flatMap { HeadPrint.embed($0) }].compactMap { $0 })
        }
        reading.embedding = FaceFeatures.combine(face: face, head: head)
        return reading
    }

    /// Intersection over union of two boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        let both = a.width * a.height + b.width * b.height - shared.width * shared.height
        return both > 0 ? shared.width * shared.height / both : 0
    }

    /// The face cut out through `view` (chip coordinates to image pixels).
    static func chip(_ image: CIImage, _ view: CGAffineTransform, size: CGFloat) -> CGImage? {
        let out = image.transformed(by: view.inverted()).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        guard !out.extent.isEmpty else { return nil }
        return context.createCGImage(out, from: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private static func mirror(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -ci.extent.width, y: 0))
        return context.createCGImage(flipped, from: ci.extent)
    }
}

/// Lines a face up the way dlib's face model was trained: a similarity transform (turn,
/// resize, move; no stretching) that puts the outer and inner corner of each eye and the
/// bottom of the nose where dlib's own face chips put them.
nonisolated enum FaceAlignment {
    /// dlib's 5-point face template (get_face_chip_details), x right and y down, 0…1: the
    /// right-hand eye's outer and inner corners, the left-hand eye's outer and inner corners,
    /// and the bottom of the nose.
    private static let template: [CGPoint] = [
        CGPoint(x: 0.8595674595992, y: 0.2134981538014),
        CGPoint(x: 0.6460604764104, y: 0.2289674387677),
        CGPoint(x: 0.1205750620789, y: 0.2137274526848),
        CGPoint(x: 0.3340850613712, y: 0.2290642403242),
        CGPoint(x: 0.4901123135679, y: 0.6277975316475),
    ]

    /// The same five points from Vision's landmarks, in normalized image coordinates (origin
    /// bottom left), in the template's order.
    static func fivePoints(_ face: VNFaceObservation) -> [CGPoint]? {
        guard let marks = face.landmarks,
              let one = marks.leftEye?.normalizedPoints, one.count >= 4,
              let two = marks.rightEye?.normalizedPoints, two.count >= 4,
              let nose = marks.nose?.normalizedPoints, nose.count >= 3 else { return nil }
        // Landmark points are relative to the face box.
        let box = face.boundingBox
        func inImage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
        }
        func midX(_ points: [CGPoint]) -> CGFloat { points.map(\.x).reduce(0, +) / CGFloat(points.count) }
        let a = one.map(inImage), b = two.map(inImage)
        // Which eye is which in the frame, whatever Vision calls them.
        let (leftHand, rightHand) = midX(a) < midX(b) ? (a, b) : (b, a)
        guard let rightOuter = rightHand.max(by: { $0.x < $1.x }),
              let rightInner = rightHand.min(by: { $0.x < $1.x }),
              let leftOuter = leftHand.min(by: { $0.x < $1.x }),
              let leftInner = leftHand.max(by: { $0.x < $1.x }) else { return nil }
        // The bottom of the nose: the middle of the nose outline, at its lowest point.
        let nosePoints = nose.map(inImage)
        guard let lowest = nosePoints.min(by: { $0.y < $1.y }) else { return nil }
        let noseBottom = CGPoint(x: midX(nosePoints), y: lowest.y)
        return [rightOuter, rightInner, leftOuter, leftInner, noseBottom]
    }

    /// The transform from chip coordinates (origin bottom left, `size` square) to image
    /// pixels that best lines the template up with these points.
    static func transform(to points: [CGPoint], size: CGFloat, padding: CGFloat) -> CGAffineTransform? {
        guard points.count == template.count else { return nil }
        let from = template.map { point in
            CGPoint(x: (padding + point.x) / (2 * padding + 1) * size,
                    y: size - (padding + point.y) / (2 * padding + 1) * size)
        }
        return similarity(from: from, to: points)
    }

    /// The head around the face chip: zoomed out to take in the hair, nudged up, and scaled to
    /// HeadPrint's size, in the same turn as the face.
    static func headView(_ view: CGAffineTransform, chip: CGFloat) -> CGAffineTransform {
        let middle = chip / 2
        let zoom = CGAffineTransform(translationX: -middle, y: -middle)
            .concatenating(CGAffineTransform(scaleX: 1.9, y: 1.9))
            .concatenating(CGAffineTransform(translationX: middle, y: middle + chip * 0.12))
        return CGAffineTransform(scaleX: chip / HeadPrint.size, y: chip / HeadPrint.size)
            .concatenating(zoom)
            .concatenating(view)
    }

    /// The same view, turned and resized a little around the chip's middle.
    static func jittered(_ view: CGAffineTransform, turn: CGFloat, size: CGFloat, chip: CGFloat) -> CGAffineTransform {
        let middle = chip / 2
        let nudge = CGAffineTransform(translationX: -middle, y: -middle)
            .concatenating(CGAffineTransform(rotationAngle: turn))
            .concatenating(CGAffineTransform(scaleX: size, y: size))
            .concatenating(CGAffineTransform(translationX: middle, y: middle))
        return nudge.concatenating(view)
    }

    /// Least-squares similarity transform taking `from` onto `to`.
    private static func similarity(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform? {
        let count = CGFloat(from.count)
        let fromMean = CGPoint(x: from.map(\.x).reduce(0, +) / count, y: from.map(\.y).reduce(0, +) / count)
        let toMean = CGPoint(x: to.map(\.x).reduce(0, +) / count, y: to.map(\.y).reduce(0, +) / count)
        var dot: CGFloat = 0, cross: CGFloat = 0, spread: CGFloat = 0
        for (f, t) in zip(from, to) {
            let fx = f.x - fromMean.x, fy = f.y - fromMean.y
            let tx = t.x - toMean.x, ty = t.y - toMean.y
            dot += fx * tx + fy * ty
            cross += fx * ty - fy * tx
            spread += fx * fx + fy * fy
        }
        guard spread > 0 else { return nil }
        let cosine = dot / spread, sine = cross / spread
        // Vision misreading a face shows up as a silly scale; don't embed those.
        let scale = (cosine * cosine + sine * sine).squareRoot()
        guard scale > 0.05, scale < 50 else { return nil }
        let tx = toMean.x - (cosine * fromMean.x - sine * fromMean.y)
        let ty = toMean.y - (sine * fromMean.x + cosine * fromMean.y)
        return CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine, tx: tx, ty: ty)
    }
}

/// Turns an aligned face chip into a vector; the same person's chips land close together.
nonisolated protocol FaceEmbedding: Sendable {
    /// Saved with the faces, so a different embedder never compares against them.
    var id: String { get }
    /// Cosine similarity a match must reach before there's a family to measure against.
    var matchThreshold: Float { get }
    /// With only one person set up, a match needs at least this: brothers and sisters easily
    /// clear the plain bar.
    var aloneThreshold: Float { get }
    /// Below this plain similarity, a face isn't anyone in the family (a guest, a friend).
    var guestFloor: Float { get }
    /// A new person's look this close to a stored one is someone already set up.
    var duplicateSimilarity: Float { get }
    /// How far ahead of the next person the best match must be, before family matching.
    var margin: Float { get }
    /// The chip the model takes: its side in pixels, and the room around the face.
    var chipSize: CGFloat { get }
    var chipPadding: CGFloat { get }
    /// How many numbers the face print has; any after it are the head print.
    var faceLength: Int { get }
    /// Whether looks also carry a head print (not for the feature-print fallback, which is
    /// one already).
    var addsHeadPrint: Bool { get }
    func embed(_ image: CGImage) -> [Float]?
}

/// A saved look is the face print followed by the head print, each normalized on its own.
nonisolated enum FaceFeatures {
    static func combine(face: [Float], head: [Float]?) -> [Float] {
        guard let head, !head.isEmpty else { return face }
        return face + FaceMath.normalized(head)
    }

    /// Just the face print, for face-to-face similarity.
    static func face(_ look: [Float]) -> [Float] {
        let length = FaceEmbedder.current.faceLength
        guard look.count > length else { return look }
        return FaceMath.normalized(Array(look.prefix(length)))
    }

    /// Both prints, each normalized, for the family classifier.
    static func classifierInput(_ look: [Float]) -> [Float] {
        let length = FaceEmbedder.current.faceLength
        guard look.count > length else { return look }
        return FaceMath.normalized(Array(look.prefix(length))) + FaceMath.normalized(Array(look.dropFirst(length)))
    }
}

/// Apple's image feature print (Vision, on device), used for the head around the face.
nonisolated enum HeadPrint {
    static let size: CGFloat = 224

    static func embed(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let print = request.results?.first, print.elementType == .float else { return nil }
        let count = print.elementCount
        let values: [Float] = print.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
        return FaceMath.normalized(values)
    }
}

nonisolated enum FaceEmbedder {
    /// dlib's face model in the app (DlibFace128.mlpackage), or Vision's general image
    /// feature print if it's ever missing.
    static let current: any FaceEmbedding = {
        if let model = DlibFaceEmbedder() { return model }
        return FeaturePrintEmbedder()
    }()

    static var usesFaceModel: Bool { current is DlibFaceEmbedder }
}

/// Apple's on-device image feature print. Not made for faces; only a fallback.
nonisolated struct FeaturePrintEmbedder: FaceEmbedding {
    let id = "vision.featureprint.aligned5"
    let faceLength = Int.max
    let addsHeadPrint = false
    let matchThreshold: Float = 0.80
    let aloneThreshold: Float = 0.88
    let guestFloor: Float = 0.70
    let duplicateSimilarity: Float = 0.92
    let margin: Float = 0.03
    let chipSize: CGFloat = 150
    let chipPadding: CGFloat = 0.25

    func embed(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let print = request.results?.first, print.elementType == .float else { return nil }
        let count = print.elementCount
        let values: [Float] = print.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
        return FaceMath.normalized(values)
    }
}

/// dlib's face recognition ResNet (Davis King, released into the public domain), converted to
/// Core ML: a 150×150 face chip lined up dlib's way in, 128 numbers out. Its similarities sit
/// close together: the same person is about 0.91 or more; unrelated people mostly 0.80–0.89.
/// Family matching takes the shared part out, which spreads these apart.
nonisolated final class DlibFaceEmbedder: FaceEmbedding, @unchecked Sendable {
    let id: String
    let matchThreshold: Float = 0.91
    let aloneThreshold: Float = 0.94
    let guestFloor: Float = 0.87
    let duplicateSimilarity: Float = 0.95
    let margin: Float = 0.02
    let chipSize: CGFloat = 150
    let chipPadding: CGFloat = 0.25
    let faceLength = 128
    let addsHeadPrint = true
    private let model: VNCoreMLModel

    init?() {
        guard let url = Bundle.main.url(forResource: "DlibFace128", withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url),
              let vision = try? VNCoreMLModel(for: ml) else { return nil }
        model = vision
        let version = ml.modelDescription.metadata[.versionString] as? String ?? "1"
        // ".head": looks carry a head print too, so older faces need setting up again.
        id = "coreml.\(version).head"
    }

    func embed(_ image: CGImage) -> [Float]? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue else { return nil }
        var values = [Float](repeating: 0, count: array.count)
        for index in 0..<array.count { values[index] = array[index].floatValue }
        return FaceMath.normalized(values)
    }
}

nonisolated enum FaceMath {
    static func normalized(_ values: [Float]) -> [Float] {
        let length = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return values }
        return values.map { $0 / length }
    }

    /// Both vectors are normalized, so this is the dot product.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var sum: Float = 0
        vDSP_dotpr(a, 1, b, 1, &sum, vDSP_Length(a.count))
        return sum
    }

    /// The average of a set, normalized.
    static func centroid(_ set: [[Float]]) -> [Float]? {
        guard let first = set.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in set where vector.count == sum.count {
            for index in sum.indices { sum[index] += vector[index] }
        }
        return normalized(sum)
    }

    /// A weighted average, normalized.
    static func weightedCentroid(_ set: [(vector: [Float], weight: Float)]) -> [Float]? {
        guard let first = set.first else { return nil }
        var sum = [Float](repeating: 0, count: first.vector.count)
        for (vector, weight) in set where vector.count == sum.count {
            for index in sum.indices { sum[index] += vector[index] * weight }
        }
        return normalized(sum)
    }
}
