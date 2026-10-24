import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import Caloma

/// The face model and the way faces are lined up, checked against dlib's own output for the
/// same photo (FaceTestExpected.json). If these pass, the converted model and the alignment
/// do what dlib does; family matching sits on top of that.
@MainActor
struct FaceModelTests {
    private struct Expected: Decodable {
        struct Face: Decodable {
            var descriptor: [Float]
            var points: [Double]
        }
        var chip: [Float]
        var photoFaces: [Face]
    }

    private final class BundleToken {}
    private var bundle: Bundle { Bundle(for: BundleToken.self) }

    private func expected() throws -> Expected {
        let url = try #require(bundle.url(forResource: "FaceTestExpected", withExtension: "json"))
        return try JSONDecoder().decode(Expected.self, from: Data(contentsOf: url))
    }

    private func image(_ name: String, _ ext: String) throws -> CGImage {
        let url = try #require(bundle.url(forResource: name, withExtension: ext))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func embedder() throws -> DlibFaceEmbedder {
        try #require(DlibFaceEmbedder(), "DlibFace128.mlpackage isn't in the app")
    }

    @Test func modelMatchesDlib() throws {
        let embedding = try #require(try embedder().embed(image("FaceTestChip", "png")))
        let similarity = FaceMath.similarity(embedding, FaceMath.normalized(try expected().chip))
        #expect(similarity > 0.999, "Core ML model drifted from dlib: \(similarity)")
    }

    @Test func alignmentMatchesDlib() throws {
        let photo = try image("FaceTestPhoto", "jpg")
        let height = CGFloat(photo.height)
        let face = try expected().photoFaces[0]
        // dlib's points are y down; the app works y up.
        let points = stride(from: 0, to: 10, by: 2).map { CGPoint(x: face.points[$0], y: height - face.points[$0 + 1]) }
        let embedder = try embedder()
        let view = try #require(FaceAlignment.transform(to: points, size: embedder.chipSize, padding: embedder.chipPadding))
        let chip = try #require(FaceAnalyzer.chip(CIImage(cgImage: photo), view, size: embedder.chipSize))
        let embedding = try #require(embedder.embed(chip))
        let similarity = FaceMath.similarity(embedding, FaceMath.normalized(face.descriptor))
        #expect(similarity > 0.99, "Lining up drifted from dlib: \(similarity)")
    }

    /// The whole path the wall uses: Vision finds the face and its landmarks, the app lines it up,
    /// and the result should be the same face dlib saw.
    @Test func visionPipelineMatchesDlib() throws {
        let photo = try image("FaceTestPhoto", "jpg")
        let buffer = try #require(pixelBuffer(photo))
        let embedder = try embedder()
        let reading = FaceAnalyzer.read(buffer, embedder: embedder)
        let look = try #require(reading.embedding, "No clear face found (quality \(reading.quality))")
        #expect(look.count > 128, "No head print on the look")
        let embedding = FaceFeatures.face(look)
        let best = try expected().photoFaces.map { FaceMath.similarity(embedding, FaceMath.normalized($0.descriptor)) }.max() ?? 0
        // The same person is about 0.91 or more on this model; unrelated people mostly under 0.89.
        #expect(best > 0.95, "Vision's landmarks line faces up differently from dlib's: \(best)")
    }

    private func pixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }
        CIContext().render(CIImage(cgImage: image), to: buffer)
        return buffer
    }
}

/// Family matching on made-up embeddings: brothers and sisters who share most of their look.
struct FamilyFaceModelTests {
    private struct Generator {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
        mutating func vector(_ count: Int) -> [Float] { FaceMath.normalized((0..<count).map { _ in next() }) }
    }

    private func mix(_ parts: [([Float], Float)]) -> [Float] {
        var sum = [Float](repeating: 0, count: parts[0].0.count)
        for (vector, weight) in parts { for index in sum.indices { sum[index] += vector[index] * weight } }
        return FaceMath.normalized(sum)
    }

    /// Six kids sharing 85% of their look: raw similarity between siblings is high, but each
    /// still matches only themselves.
    @Test func siblingsMatchThemselves() {
        var random = Generator(state: 42)
        let width = 128
        let family = random.vector(width)
        let kids = (0..<6).map { _ in mix([(family, 0.85.squareRoot()), (random.vector(width), 0.15.squareRoot())]) }
        func look(_ kid: [Float]) -> [Float] { mix([(kid, 1), (random.vector(width), 0.25)]) }
        var faces: [UUID: [[Float]]] = [:]
        let ids = kids.map { _ in UUID() }
        for (id, kid) in zip(ids, kids) { faces[id] = (0..<20).map { _ in look(kid) } }
        let model = FamilyFaceModel(faces: faces)
        #expect(model.isCalibrated)

        let embedder = FeaturePrintEmbedder()
        var right = 0, wrong = 0
        for (id, kid) in zip(ids, kids) {
            for _ in 0..<20 {
                switch model.verdict(model.scores(look(kid)), embedder: embedder) {
                case .match(let who): if who == id { right += 1 } else { wrong += 1 }
                default: break
                }
            }
        }
        #expect(wrong == 0)
        #expect(right > 100)
    }

    /// With only one child set up, a brother or sister isn't taken for her.
    @Test func oneSetUpDoesNotClaimSiblings() {
        var random = Generator(state: 7)
        let width = 128
        let family = random.vector(width)
        let her = mix([(family, 0.85.squareRoot()), (random.vector(width), 0.15.squareRoot())])
        let brother = mix([(family, 0.85.squareRoot()), (random.vector(width), 0.15.squareRoot())])
        let id = UUID()
        let model = FamilyFaceModel(faces: [id: (0..<20).map { _ in mix([(her, 1), (random.vector(width), 0.1)]) }])
        let embedder = FeaturePrintEmbedder()
        let look = mix([(brother, 1), (random.vector(width), 0.1)])
        #expect(model.verdict(model.scores(look), embedder: embedder) == .nobody)
    }
}

/// The family classifier on made-up looks: brothers and sisters close on the face print, with
/// a head print that differs a little.
struct FamilyClassifierTests {
    @Test func learnsSiblingsAndReportsHonestly() throws {
        var state: UInt64 = 99
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
        func vector(_ count: Int) -> [Float] { FaceMath.normalized((0..<count).map { _ in next() }) }
        func mix(_ a: [Float], _ wa: Float, _ b: [Float], _ wb: Float) -> [Float] { FaceMath.normalized(zip(a, b).map { $0 * wa + $1 * wb }) }
        let familyFace = vector(128), familyHead = vector(768)
        let kids = (0..<4).map { _ in (face: mix(familyFace, 0.95, vector(128), 0.3), head: mix(familyHead, 0.9, vector(768), 0.45)) }
        func look(_ kid: (face: [Float], head: [Float])) -> [Float] {
            FaceFeatures.combine(face: mix(kid.face, 1, vector(128), 0.25), head: mix(kid.head, 1, vector(768), 0.5))
        }
        let ids = kids.map { _ in UUID() }
        var faces: [UUID: [[Float]]] = [:]
        for (id, kid) in zip(ids, kids) { faces[id] = (0..<40).map { _ in look(kid) } }
        let classifier = try #require(FamilyClassifier(faces: faces))
        #expect(classifier.report.checked == 40)
        #expect(classifier.report.accuracy > 0.9)
        var right = 0
        for (id, kid) in zip(ids, kids) {
            for _ in 0..<10 where classifier.chances(look(kid)).first?.id == id { right += 1 }
        }
        #expect(right >= 36)
    }

    @Test func needsTwoPeople() {
        #expect(FamilyClassifier(faces: [UUID(): Array(repeating: [Float](repeating: 0.1, count: 896), count: 10)]) == nil)
    }
}
