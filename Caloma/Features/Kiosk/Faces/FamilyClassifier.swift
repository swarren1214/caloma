import Accelerate
import Foundation

/// A small model trained on this family alone, on this iPad, from the looks saved at face
/// setup. A general face model only knows "how alike are two faces", and to it brothers and
/// sisters are nearly the same. This learns the opposite question, "which of these people is
/// it", from every number the face and head prints carry (hair included), so it leans on
/// whatever actually tells these particular kids apart.
///
/// It's a multinomial logistic regression over the face print (dlib) and the head print
/// (Apple's Vision feature print of the face with hair). Training holds back every fourth
/// look per person, picks the settings that do best on those, and reports how many of them it
/// got right; then it trains again on everything. Takes well under a second; runs off the main
/// thread whenever someone's face is saved or learned.
nonisolated struct FamilyClassifier: Sendable {
    struct MixUp: Sendable, Hashable {
        /// Who the held-back look really was, and who it was taken for.
        var actual: UUID
        var guessed: UUID
        var count: Int
    }

    /// How the held-back looks went: the honest measure of whether the wall can tell everyone
    /// apart.
    struct Report: Sendable, Equatable {
        var checked: Int
        var correct: Int
        var mixUps: [MixUp]
        var accuracy: Double { checked > 0 ? Double(correct) / Double(checked) : 0 }
    }

    struct Chance: Sendable, Equatable {
        var id: UUID
        var probability: Float
    }

    let ids: [UUID]
    let report: Report
    private let width: Int
    private let mean: [Float]
    private let inverseSpread: [Float]
    /// width × classes, row-major.
    private let weights: [Float]
    private let bias: [Float]
    private let temperature: Float

    /// Each person needs at least this many looks to be trained on.
    static let minimumLooks = 6
    private static let strengths: [Float] = [0.003, 0.01, 0.03, 0.1]
    private static let temperatures: [Float] = [0.5, 0.75, 1, 1.5, 2, 3, 4, 6]
    private static let steps = 200

    init?(faces: [UUID: [[Float]]]) {
        let ids = faces.filter { $0.value.count >= Self.minimumLooks }.keys.sorted { $0.uuidString < $1.uuidString }
        guard ids.count >= 2 else { return nil }
        var rows: [[Float]] = []
        var labels: [Int] = []
        var heldBack: [Bool] = []
        for (label, id) in ids.enumerated() {
            for (index, look) in (faces[id] ?? []).enumerated() {
                rows.append(FaceFeatures.classifierInput(look))
                labels.append(label)
                heldBack.append(index % 4 == 3)
            }
        }
        guard let width = rows.first?.count, width > 0 else { return nil }
        let usable = rows.indices.filter { rows[$0].count == width }
        rows = usable.map { rows[$0] }
        labels = usable.map { labels[$0] }
        heldBack = usable.map { heldBack[$0] }
        let classes = ids.count

        // Each number scaled to the family's own spread, so no one feature drowns the rest.
        var mean = [Float](repeating: 0, count: width)
        for row in rows { for index in 0..<width { mean[index] += row[index] } }
        for index in 0..<width { mean[index] /= Float(rows.count) }
        var spread = [Float](repeating: 0, count: width)
        for row in rows { for index in 0..<width { let d = row[index] - mean[index]; spread[index] += d * d } }
        let inverseSpread = spread.map { 1 / max(($0 / Float(rows.count)).squareRoot(), 1e-4) }
        let standardized: [[Float]] = rows.map { row in (0..<width).map { (row[$0] - mean[$0]) * inverseSpread[$0] } }

        // Pick the settings on the held-back looks.
        let trainIndices = standardized.indices.filter { !heldBack[$0] }
        let checkIndices = standardized.indices.filter { heldBack[$0] }
        var bestScore = Float.infinity
        var bestStrength = Self.strengths[1]
        var bestTemperature: Float = 1
        var bestGuesses: [Int] = []
        if !checkIndices.isEmpty, Set(trainIndices.map { labels[$0] }).count == classes {
            for strength in Self.strengths {
                let model = Self.train(trainIndices.map { standardized[$0] }, trainIndices.map { labels[$0] }, width: width, classes: classes, strength: strength)
                let logits = checkIndices.map { Self.logits(standardized[$0], model.weights, model.bias, width: width, classes: classes) }
                for temperature in Self.temperatures {
                    var loss: Float = 0
                    for (row, index) in checkIndices.enumerated() {
                        let chances = Self.softmax(logits[row].map { $0 / temperature })
                        loss -= log(max(chances[labels[index]], 1e-6))
                    }
                    if loss < bestScore {
                        bestScore = loss
                        bestStrength = strength
                        bestTemperature = temperature
                        bestGuesses = logits.map { Self.argmax($0) }
                    }
                }
            }
        }
        var correct = 0
        var mixUps: [MixUp] = []
        for (row, index) in checkIndices.enumerated() where row < bestGuesses.count {
            let guess = bestGuesses[row]
            if guess == labels[index] {
                correct += 1
            } else if let at = mixUps.firstIndex(where: { $0.actual == ids[labels[index]] && $0.guessed == ids[guess] }) {
                mixUps[at].count += 1
            } else {
                mixUps.append(MixUp(actual: ids[labels[index]], guessed: ids[guess], count: 1))
            }
        }
        report = Report(checked: bestGuesses.isEmpty ? 0 : checkIndices.count, correct: correct, mixUps: mixUps.sorted { $0.count > $1.count })

        let model = Self.train(standardized, labels, width: width, classes: classes, strength: bestStrength)
        self.ids = ids
        self.width = width
        self.mean = mean
        self.inverseSpread = inverseSpread
        self.weights = model.weights
        self.bias = model.bias
        self.temperature = bestTemperature
    }

    /// Everyone's chance of being this look, best first.
    func chances(_ look: [Float]) -> [Chance] {
        let input = FaceFeatures.classifierInput(look)
        guard input.count == width else { return [] }
        let standardized = (0..<width).map { (input[$0] - mean[$0]) * inverseSpread[$0] }
        let chances = Self.softmax(Self.logits(standardized, weights, bias, width: width, classes: ids.count).map { $0 / temperature })
        return zip(ids, chances).map { Chance(id: $0, probability: $1) }.sorted { $0.probability > $1.probability }
    }

    // MARK: Training

    /// Softmax regression with L2 strength, every person weighted equally however many looks
    /// they have. Adam, full batch.
    private static func train(_ rows: [[Float]], _ labels: [Int], width: Int, classes: Int, strength: Float) -> (weights: [Float], bias: [Float]) {
        let count = rows.count
        var x = [Float](repeating: 0, count: count * width)
        for (index, row) in rows.enumerated() { x.replaceSubrange(index * width..<(index + 1) * width, with: row) }
        var xt = [Float](repeating: 0, count: width * count)
        vDSP_mtrans(x, 1, &xt, 1, vDSP_Length(width), vDSP_Length(count))
        var perClass = [Int](repeating: 0, count: classes)
        for label in labels { perClass[label] += 1 }
        let rowWeight = labels.map { 1 / Float(max(perClass[$0], 1) * classes) }

        var weights = [Float](repeating: 0, count: width * classes)
        var bias = [Float](repeating: 0, count: classes)
        var m = [Float](repeating: 0, count: weights.count), v = m
        var mb = [Float](repeating: 0, count: classes), vb = mb
        var logits = [Float](repeating: 0, count: count * classes)
        var gradient = [Float](repeating: 0, count: weights.count)
        let rate: Float = 0.05, beta1: Float = 0.9, beta2: Float = 0.999, epsilon: Float = 1e-8

        for step in 1...Self.steps {
            vDSP_mmul(x, 1, weights, 1, &logits, 1, vDSP_Length(count), vDSP_Length(classes), vDSP_Length(width))
            var biasGradient = [Float](repeating: 0, count: classes)
            for row in 0..<count {
                let base = row * classes
                var top = -Float.infinity
                for c in 0..<classes { logits[base + c] += bias[c]; top = max(top, logits[base + c]) }
                var sum: Float = 0
                for c in 0..<classes { logits[base + c] = exp(logits[base + c] - top); sum += logits[base + c] }
                for c in 0..<classes {
                    let target: Float = labels[row] == c ? 1 : 0
                    let g = rowWeight[row] * (logits[base + c] / sum - target)
                    logits[base + c] = g
                    biasGradient[c] += g
                }
            }
            vDSP_mmul(xt, 1, logits, 1, &gradient, 1, vDSP_Length(width), vDSP_Length(classes), vDSP_Length(count))
            let correction1 = 1 - pow(beta1, Float(step)), correction2 = 1 - pow(beta2, Float(step))
            for index in 0..<weights.count {
                let g = gradient[index] + 2 * strength * weights[index]
                m[index] = beta1 * m[index] + (1 - beta1) * g
                v[index] = beta2 * v[index] + (1 - beta2) * g * g
                weights[index] -= rate * (m[index] / correction1) / ((v[index] / correction2).squareRoot() + epsilon)
            }
            for c in 0..<classes {
                let g = biasGradient[c]
                mb[c] = beta1 * mb[c] + (1 - beta1) * g
                vb[c] = beta2 * vb[c] + (1 - beta2) * g * g
                bias[c] -= rate * (mb[c] / correction1) / ((vb[c] / correction2).squareRoot() + epsilon)
            }
        }
        return (weights, bias)
    }

    private static func logits(_ input: [Float], _ weights: [Float], _ bias: [Float], width: Int, classes: Int) -> [Float] {
        var out = [Float](repeating: 0, count: classes)
        vDSP_mmul(input, 1, weights, 1, &out, 1, 1, vDSP_Length(classes), vDSP_Length(width))
        return zip(out, bias).map { $0 + $1 }
    }

    private static func softmax(_ values: [Float]) -> [Float] {
        let top = values.max() ?? 0
        let exps = values.map { exp($0 - top) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }

    private static func argmax(_ values: [Float]) -> Int {
        values.indices.max { values[$0] < values[$1] } ?? 0
    }
}
