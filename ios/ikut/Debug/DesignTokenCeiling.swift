// The design-token ratchet (D78). Not generated, but written by `node tools/design-inventory.mjs --lower`.
// DesignInventoryTests fails if the number of tokens defined in UI/Theme.swift (Spacing, Radius), UI/Palette.swift
// (Elevation, TintFill, Palette colours) and Map/MapColors.swift is above its number here, so the scales can only
// shrink. Adding a token means merging another one away. A piece that removes tokens MUST lower these: regenerate
// the inventory, then run `node tools/design-inventory.mjs --lower` (keeps the smaller of today's count and the
// ceiling, so it never raises one), or edit a single number below by hand.
enum TokenCeiling {
    static let spacing = 6
    static let radius = 3
    static let elevation = 2
    static let tintFill = 2
    static let colour = 17
}
