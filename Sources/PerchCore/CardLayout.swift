/// How the visible cards share the workspace row, and how dragging the gap between two of them changes that.
/// Widths are in points, gaps already taken out.
public enum CardLayout {
    /// Widths in proportion to the weights, except that no card goes below its minimum.
    /// Cards held at their minimum leave the rest of the row to the others, still in proportion.
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
        let widths = widths(weights, minimums: minimums, in: available)
        let pair = widths[index] + widths[index + 1]
        guard pair > 0 else { return weights }
        let left = min(max(widths[index] + delta, minimums[index]), pair - minimums[index + 1])
        let pairWeight = weights[index] + weights[index + 1]
        var result = weights
        result[index] = pairWeight * left / pair
        result[index + 1] = pairWeight - result[index]
        return result
    }
}
