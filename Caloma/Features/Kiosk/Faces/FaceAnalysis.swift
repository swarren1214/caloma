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

    static let nobody = FaceReading(faceCount: 0)
    var hasFace: Bool { faceCount > 0 }
}

/// Finds faces with Vision and turns the clearest one into an embedding.
nonisolated enum FaceAnalyzer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Embeddings are only made from faces at least this clear.
    static let minimumQuality = 0.25

    static func read(_ buffer: CVPixelBuffer, embedder: any FaceEmbedding) -> FaceReading {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        try? handler.perform([rectangles])
        guard let faces = rectangles.results, !faces.isEmpty else { return .nobody }
        let face = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height } ?? faces[0]

        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = [face]
        try? handler.perform([qualityRequest])
        let quality = Double(qualityRequest.results?.first?.faceCaptureQuality ?? 0)

        var reading = FaceReading(faceCount: faces.count)
        reading.box = face.boundingBox
        reading.yaw = (face.yaw?.doubleValue ?? 0) * 180 / .pi
        reading.pitch = (face.pitch?.doubleValue ?? 0) * 180 / .pi
        reading.quality = quality
        if quality >= minimumQuality, let crop = crop(buffer, around: face.boundingBox, scale: embedder.cropScale) {
            reading.embedding = embedder.embed(crop)
        }
        return reading
    }

    /// A square around the face with a little room, scaled down for the embedder.
    private static func crop(_ buffer: CVPixelBuffer, around box: CGRect, scale room: CGFloat) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        let rect = VNImageRectForNormalizedRect(box, Int(extent.width), Int(extent.height))
        let side = max(rect.width, rect.height) * room
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side).intersection(extent)
        guard square.width > 20, square.height > 20 else { return nil }
        let scale = 160 / max(square.width, square.height)
        let cropped = image.cropped(to: square).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(cropped, from: cropped.extent)
    }
}

/// Turns a face crop into a vector; the same person's crops land close together.
nonisolated protocol FaceEmbedding: Sendable {
    /// Saved with the faces, so a different embedder never compares against them.
    var id: String { get }
    /// Cosine similarity a match must reach.
    var matchThreshold: Float { get }
    /// How far ahead of the next person the best match must be.
    var margin: Float { get }
    /// How much room around Vision's face box the crop gets.
    var cropScale: CGFloat { get }
    func embed(_ image: CGImage) -> [Float]?
}

nonisolated enum FaceEmbedder {
    /// The FaceNet face model in the app (FaceNet512.mlpackage), or Vision's general image
    /// feature print if it's ever missing.
    static let current: any FaceEmbedding = {
        if let model = CoreMLFaceEmbedder() { return model }
        return FeaturePrintEmbedder()
    }()

    static var usesFaceModel: Bool { current is CoreMLFaceEmbedder }
}

/// Apple's on-device image feature print. Not made for faces, but steady on one wall with
/// one family; the thresholds are tuned for it.
nonisolated struct FeaturePrintEmbedder: FaceEmbedding {
    let id = "vision.featureprint"
    let matchThreshold: Float = 0.80
    let margin: Float = 0.03
    let cropScale: CGFloat = 1.3

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

/// FaceNet (Inception-ResNet-v1, VGGFace2 weights from facenet-pytorch), converted to Core ML:
/// a 160×160 face crop in, a 512-number embedding out. Same person: about 0.6–0.9 similar;
/// different people: under about 0.4.
nonisolated final class CoreMLFaceEmbedder: FaceEmbedding, @unchecked Sendable {
    let id: String
    let matchThreshold: Float = 0.55
    let margin: Float = 0.10
    let cropScale: CGFloat = 1.2
    private let model: VNCoreMLModel

    init?() {
        guard let url = Bundle.main.url(forResource: "FaceNet512", withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url),
              let vision = try? VNCoreMLModel(for: ml) else { return nil }
        model = vision
        let version = ml.modelDescription.metadata[.versionString] as? String ?? "1"
        id = "coreml.\(version)"
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
        guard a.count == b.count else { return -1 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }

    /// Each person's closest stored embedding to this one, best first.
    static func rank(_ embedding: [Float], in faces: [UUID: [[Float]]]) -> [(id: UUID, score: Float)] {
        faces.compactMap { id, stored -> (id: UUID, score: Float)? in
            guard let best = stored.map({ similarity(embedding, $0) }).max() else { return nil }
            return (id, best)
        }
        .sorted { $0.score > $1.score }
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
}
