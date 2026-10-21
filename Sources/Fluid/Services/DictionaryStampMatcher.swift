import Accelerate
import Foundation

/// Finds a recorded word inside a dictation by sliding each recording's encoder frames along
/// the dictation (subsequence dynamic time warping). The best stretch may start and end anywhere,
/// and its length may differ from the recording, so the word can be faster or slower in a sentence.
nonisolated enum DictionaryStampMatcher {
    // Distance = mean per-frame cosine distance along the matched path (0 identical, 1 unrelated).
    // Tuned 2026-10-20 on 2,007 checks (5 words x the user's last 500 dictations + test sentences):
    // real uses 0.03-0.20, deliberate sound-alikes 0.180 and 0.198, ordinary speech never below 0.268.
    // At these values: 40 of 43 real uses caught, 0 of 1,964 others swapped (a fixed 0.14 caught 32).

    /// Below this, the sound alone is enough to replace.
    static let sureDistance: Float = 0.16
    /// Between `sureDistance` and this, replace only if the words also look like the word
    /// (see `DictionaryAudioSpan.greyZoneMinimumResemblance`). At or above it, never replace.
    static let greyZoneLimit: Float = 0.175
    static let maximumQueryFrames = 1500

    struct Hit: Equatable, Sendable {
        let frames: Range<Int>
        let distance: Float
    }

    /// Up to `limit` non-overlapping stretches of `query` closer than `greyZoneLimit` to any reference.
    static func hits(references: [DictionaryMatchFrames], in query: DictionaryMatchFrames, limit: Int = 3) -> [Hit] {
        let m = query.count
        guard m > 0, m <= self.maximumQueryFrames, query.values.count == m * query.hiddenSize,
              query.values.allSatisfy(\.isFinite) else { return [] }
        let normalizedQuery = self.normalizedRows(query)
        var bestDistance = [Float](repeating: .infinity, count: m)
        var bestStart = [Int](repeating: 0, count: m)
        for reference in references where reference.hiddenSize == query.hiddenSize && !reference.values.isEmpty
            && reference.values.count == reference.count * reference.hiddenSize && reference.values.allSatisfy(\.isFinite)
        {
            let (distances, starts) = self.endScores(reference: self.normalizedRows(reference), rows: reference.count, query: normalizedQuery, columns: m, hidden: query.hiddenSize)
            for j in 0..<m where distances[j] < bestDistance[j] {
                bestDistance[j] = distances[j]
                bestStart[j] = starts[j]
            }
        }
        var hits: [Hit] = []
        var available = [Bool](repeating: true, count: m)
        while hits.count < limit {
            var candidate: Int?
            for j in 0..<m where available[j] && bestDistance[j] < self.greyZoneLimit {
                if candidate.map({ bestDistance[j] < bestDistance[$0] }) ?? true { candidate = j }
            }
            guard let end = candidate else { break }
            let range = bestStart[end]..<(end + 1)
            hits.append(Hit(frames: range, distance: bestDistance[end]))
            for j in 0..<m where available[j] && (bestStart[j]..<(j + 1)).overlaps(range) {
                available[j] = false
            }
        }
        return hits
    }

    private static func normalizedRows(_ frames: DictionaryMatchFrames) -> [Float] {
        var values = frames.values
        let hidden = frames.hiddenSize
        for row in 0..<frames.count {
            let start = row * hidden
            var norm: Float = 0
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_svesq(base + start, 1, &norm, vDSP_Length(hidden))
            }
            let scale = 1 / max(sqrt(norm), 1e-8)
            for d in start..<(start + hidden) {
                values[d] *= scale
            }
        }
        return values
    }

    /// For every possible end frame in the query: the length-normalized path cost of the best
    /// alignment of the whole reference ending there, and where that alignment starts.
    private static func endScores(reference: [Float], rows n: Int, query: [Float], columns m: Int, hidden: Int) -> ([Float], [Int]) {
        var similarity = [Float](repeating: 0, count: n * m)
        reference.withUnsafeBufferPointer { r in
            query.withUnsafeBufferPointer { q in
                similarity.withUnsafeMutableBufferPointer { s in
                    cblas_sgemm(
                        CblasRowMajor,
                        CblasNoTrans,
                        CblasTrans,
                        Int32(n),
                        Int32(m),
                        Int32(hidden),
                        1,
                        r.baseAddress,
                        Int32(hidden),
                        q.baseAddress,
                        Int32(hidden),
                        0,
                        s.baseAddress,
                        Int32(m)
                    )
                }
            }
        }
        var previousCost = [Float](repeating: 0, count: m)
        var previousStart = Array(0..<m)
        for j in 0..<m {
            previousCost[j] = 1 - similarity[j]
        }
        var cost = previousCost, start = previousStart
        for i in 1..<max(1, n) {
            for j in 0..<m {
                var best = previousCost[j], from = previousStart[j]
                if j > 0 {
                    if previousCost[j - 1] < best { best = previousCost[j - 1]; from = previousStart[j - 1] }
                    if cost[j - 1] < best { best = cost[j - 1]; from = start[j - 1] }
                }
                cost[j] = best + 1 - similarity[i * m + j]
                start[j] = from
            }
            previousCost = cost
            previousStart = start
        }
        var distances = [Float](repeating: .infinity, count: m)
        for j in 0..<m {
            let matched = j + 1 - start[j]
            // A word in a sentence may be up to twice as fast or slow as the recording, no more.
            guard matched * 2 >= n, matched <= n * 2 else { continue }
            distances[j] = cost[j] / Float(matched + n)
        }
        return (distances, start)
    }
}
