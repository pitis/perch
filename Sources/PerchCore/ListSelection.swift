/// Moving a keyboard selection through a list with the arrow keys.
public enum ListSelection {
    /// The item `offset` steps from `current`, stopping at either end. With nothing selected, or a selection that has
    /// left the list, Down starts at the first item and Up at the last.
    public static func move<ID: Equatable>(_ current: ID?, by offset: Int, in ids: [ID]) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return offset < 0 ? ids.last : ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// What to select once `removed` leaves the list: the item after it, or the one before if it was last.
    public static func afterRemoving<ID: Equatable>(_ removed: ID, from ids: [ID]) -> ID? {
        guard let index = ids.firstIndex(of: removed) else { return nil }
        return index + 1 < ids.count ? ids[index + 1] : index > 0 ? ids[index - 1] : nil
    }
}
