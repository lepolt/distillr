import Foundation

/// Burst-sequence detection: timestamp clustering. Continuous shooting can
/// occasionally merge genuinely unrelated moments into one group when they
/// land inside the same capture-time gap; splitting one of those apart is a
/// manual action in the app (`AppModel.splitGroup(before:in:)`), not
/// automatic — a fixed similarity threshold doesn't reliably separate
/// normal frame-to-frame motion from a genuine scene change across widely
/// varied real content (learned the hard way porting this from the
/// original Rust app, which tried automatic perceptual-hash refinement
/// and had to revert it).
enum BurstGrouping {
    /// Comfortably larger than any real continuous-shooting interval
    /// (typically tens to a few hundred ms), comfortably smaller than the
    /// pause between separate moments (seconds, at minimum).
    static let defaultGapThreshold: TimeInterval = 2.0

    /// Groups items into burst sequences: a new group starts whenever the
    /// gap from the previous item's capture time exceeds `gapThreshold`.
    static func groupBursts(_ items: [BurstItem], gapThreshold: TimeInterval = defaultGapThreshold) -> [BurstGroup] {
        let sorted = items.sorted { $0.captureTime < $1.captureTime }

        var groups: [BurstGroup] = []
        for item in sorted {
            let startsNewGroup: Bool
            if let previous = groups.last?.items.last {
                startsNewGroup = item.captureTime.timeIntervalSince(previous.captureTime) > gapThreshold
            } else {
                startsNewGroup = true
            }

            if startsNewGroup {
                groups.append(BurstGroup(items: [item]))
            } else {
                groups[groups.count - 1].items.append(item)
            }
        }
        return groups
    }
}
