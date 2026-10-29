// The design ratchet (D77). Not generated, but written by `node tools/design-inventory.mjs --lower`.
// DesignInventoryTests fails if any ad hoc count in the generated inventory is above its number here, so the
// inventory can only go down. A piece that removes literals or merges one-off views MUST lower these: regenerate
// the inventory, then run `node tools/design-inventory.mjs --lower` (keeps the smaller of today's count and the
// ceiling, so it never raises one), or edit a single number below by hand. Counts exclude UI/, Debug/, previews and demos.
enum DesignCeiling {
    static let font = 4
    static let color = 10
    static let opacity = 19
    static let padding = 24
    static let radius = 1
    static let frame = 50
    /// Views (outside UI/) whose name is written in at most one other place.
    static let viewsUsedOnce = 52
}
