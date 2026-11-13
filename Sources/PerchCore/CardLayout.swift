/// How the visible cards share the workspace row, and how dragging the gap between two of them changes that.
/// `available` is the row's width minus the gaps between cards; widths are in points.
public enum CardLayout {
    /// Widths in proportion to the weights, except that no card goes below its minimum.
    /// Cards held at their minimum leave the rest of the row to the others, still in proportion. If the minimums
    /// don't fit, every card gets its minimum and the row overflows.
    public static func widths(_ weights: [Double], minimums: [Double], in available: Double) -> [Double] {
        var held = Set<Int>()
        while true {
            let free = available - held.reduce(0) { $0 + minimums[$1] }
            let shared = weights.indices.filter { !held.contains($0) }.reduce(0) { $0 + max(weights[$1], 0) }
            let widths = weights.indices.map { held.contains($0) ? minimums[$0] : free * max(weights[$0], 0) / max(shared, .ulpOfOne) }
            let under = weights.indices.filter { !held.contains($0) && widths[$0] < minimums[$0] }
            if under.isEmpty { return widths }
            held.formUnion(under)
        }
    }

    /// Moves the gap after card `index` by `delta` points. Only that card and the next trade width,
    /// and neither goes below its minimum, so the other cards stay where they are.
    public static func resize(_ weights: [Double], at index: Int, by delta: Double, minimums: [Double], in available: Double) -> [Double] {
        guard weights.indices.contains(index), weights.indices.contains(index + 1) else { return weights }
        var target = widths(weights, minimums: minimums, in: available)
        let pair = target[index] + target[index + 1]
        target[index] = min(max(target[index] + delta, minimums[index]), pair - minimums[index + 1])
        target[index + 1] = pair - target[index]
        // Every card's weight comes from its width on screen, so a card held at its minimum is no longer held and
        // the other cards keep their widths exactly. The total weight stays, so hidden cards keep their share.
        let scale = weights.reduce(0, +) / target.reduce(0, +)
        guard scale.isFinite, scale > 0 else { return weights }
        return target.map { $0 * scale }
    }
}
