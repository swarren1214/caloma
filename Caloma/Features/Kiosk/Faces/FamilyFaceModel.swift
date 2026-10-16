import Foundation

/// The family-specific step. Face models learn from adults who weren't related, so to them
/// brothers and sisters look alike: siblings often score over a fixed match bar against each
/// other. This model is built from the faces set up on this iPad only:
///
/// 1. What the whole family shares is taken out of every embedding, so what's left is what
///    makes each person different from the others.
/// 2. Each person is scored by their typical look (the average of their 3 closest stored
///    looks), not their single closest one, so one odd look can't pull everyone in.
/// 3. For each person, it measures how close the rest of the family usually comes to them.
///    A match has to stand well clear of that, rather than clear one number that suits some
///    faces and not others.
nonisolated struct FamilyFaceModel: Sendable {
    struct Person: Sendable {
        /// Family-centered, normalized looks.
        var looks: [[Float]]
        /// The looks as the embedder made them, for the plain similarity.
        var rawLooks: [[Float]]
        /// How close the rest of the family comes to this person: the average and spread.
        var familyMean: Float = 0
        var familySpread: Float = 1
        var familySamples = 0
    }

    struct Score: Sendable, Equatable {
        var id: UUID
        /// The typical-look similarity (family-centered once two or more people are set up).
        var similarity: Float
        /// The plain typical-look similarity, before the family is taken out. Someone outside
        /// the family scores low here even when they happen to stand out from it.
        var plain: Float
        /// Spreads above how close the rest of the family usually comes. Nil until two or
        /// more people are set up.
        var standout: Float?
        /// What the decision uses.
        var rank: Float { standout ?? similarity }
    }

    enum Verdict: Equatable {
        case nobody
        case match(UUID)
        /// Two people both plausible and neither clearly ahead.
        case closeCall(UUID, UUID)
    }

    /// A match must stand this many spreads above how close the rest of the family comes...
    static let matchStandout: Float = 3.0
    /// ...and this many ahead of the next person.
    static let standoutMargin: Float = 1.5
    /// Two people both at least this plausible, with neither clearly ahead: ask which.
    static let closeCallStandout: Float = 2.0
    /// A spread is never taken as tighter than this, so a small family isn't over-trusted.
    private static let minimumSpread: Float = 0.04
    private static let minimumSamples = 8
    private static let typicalCount = 3

    let shared: [Float]?
    let people: [UUID: Person]

    static let empty = FamilyFaceModel(faces: [:])

    /// Every person has a measured family spread to stand out from.
    var isCalibrated: Bool {
        people.count >= 2 && people.values.allSatisfy { $0.familySamples >= Self.minimumSamples }
    }

    init(faces: [UUID: [[Float]]]) {
        let present = faces.filter { !$0.value.isEmpty }
        // What everyone shares: the average of each person's average, so a person with more
        // looks doesn't count for more.
        let centroids = present.values.compactMap { FaceMath.centroid($0) }
        var shared: [Float]?
        if centroids.count >= 2, let width = centroids.first?.count {
            var sum = [Float](repeating: 0, count: width)
            for centroid in centroids where centroid.count == width {
                for index in sum.indices { sum[index] += centroid[index] }
            }
            shared = sum.map { $0 / Float(centroids.count) }
        }
        self.shared = shared

        var people: [UUID: Person] = [:]
        for (id, looks) in present {
            people[id] = Person(looks: looks.map { Self.center($0, shared) }, rawLooks: looks)
        }
        // How close everyone else's looks come to each person.
        if people.count >= 2 {
            for (id, person) in people {
                var values: [Float] = []
                for (otherID, other) in people where otherID != id {
                    for look in other.looks {
                        values.append(Self.typical(look, person.looks))
                    }
                }
                guard !values.isEmpty else { continue }
                let mean = values.reduce(0, +) / Float(values.count)
                let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
                people[id]?.familyMean = mean
                people[id]?.familySpread = max(variance.squareRoot(), Self.minimumSpread)
                people[id]?.familySamples = values.count
            }
        }
        self.people = people
    }

    /// Everyone's score for this embedding, best first.
    func scores(_ embedding: [Float]) -> [Score] {
        let look = Self.center(embedding, shared)
        let calibrated = isCalibrated
        return people.map { id, person in
            let similarity = Self.typical(look, person.looks)
            let plain = shared == nil ? similarity : Self.typical(embedding, person.rawLooks)
            let standout = calibrated ? (similarity - person.familyMean) / person.familySpread : nil
            return Score(id: id, similarity: similarity, plain: plain, standout: standout)
        }
        .sorted { $0.rank > $1.rank }
    }

    /// Who this one look is, if anyone. The embedder's own bars apply until there's a family
    /// to measure against.
    func verdict(_ ranked: [Score], embedder: any FaceEmbedding) -> Verdict {
        guard let best = ranked.first else { return .nobody }
        let second = ranked.count > 1 ? ranked[1] : nil
        guard isCalibrated, let bestStandout = best.standout else {
            // With only one person set up, a brother or sister easily clears the usual bar;
            // that's how one child used to be taken for all the others.
            let bar = people.count < 2 ? embedder.aloneThreshold : embedder.matchThreshold
            if best.similarity >= bar, second == nil || best.similarity - second!.similarity >= embedder.margin {
                return .match(best.id)
            }
            return .nobody
        }
        // Not plausibly anyone in the family: a guest, or a friend over to play.
        guard best.plain >= embedder.guestFloor else { return .nobody }
        let secondStandout = second?.standout ?? -.infinity
        if bestStandout >= Self.matchStandout, bestStandout - secondStandout >= Self.standoutMargin {
            return .match(best.id)
        }
        if let second, bestStandout >= Self.closeCallStandout, secondStandout >= Self.closeCallStandout {
            return .closeCall(best.id, second.id)
        }
        return .nobody
    }

    /// Whether a look is safe to keep as this person's: the camera was already leaning their
    /// way, or it was a close call they were part of. A pick never teaches Caloma a look that's
    /// clearly closer to someone else, which is how one wrong tap used to spread.
    func leans(_ embedding: [Float], toward id: UUID, embedder: any FaceEmbedding) -> Bool {
        let ranked = scores(embedding)
        guard let best = ranked.first, let theirs = ranked.first(where: { $0.id == id }) else { return false }
        if best.id == id {
            // Leaning their way, though not far enough to match on its own.
            return isCalibrated ? (theirs.standout ?? 0) >= 1 : theirs.similarity >= embedder.guestFloor
        }
        guard isCalibrated, let standout = theirs.standout, let top = best.standout else { return false }
        return standout >= Self.closeCallStandout && top - standout < Self.standoutMargin
    }

    /// Whether a new person's look would be taken for someone already set up.
    func isRival(_ embedding: [Float], embedder: any FaceEmbedding) -> UUID? {
        let ranked = scores(embedding)
        if isCalibrated {
            if case .match(let id) = verdict(ranked, embedder: embedder) { return id }
            return nil
        }
        // Too few people to measure the family yet: only a look nearly the same as a stored
        // one counts, so a brother or sister isn't turned away.
        guard let best = ranked.first, best.similarity >= embedder.duplicateSimilarity else { return nil }
        return best.id
    }

    // MARK: Math

    private static func center(_ embedding: [Float], _ shared: [Float]?) -> [Float] {
        guard let shared, shared.count == embedding.count else { return embedding }
        var centered = embedding
        for index in centered.indices { centered[index] -= shared[index] }
        return FaceMath.normalized(centered)
    }

    /// The average of the closest few stored looks.
    private static func typical(_ look: [Float], _ looks: [[Float]]) -> Float {
        guard !looks.isEmpty else { return -1 }
        var best = looks.map { FaceMath.similarity(look, $0) }
        best.sort(by: >)
        let count = min(Self.typicalCount, best.count)
        return best.prefix(count).reduce(0, +) / Float(count)
    }
}
