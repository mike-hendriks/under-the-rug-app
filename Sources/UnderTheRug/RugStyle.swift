import CoreGraphics

/// An sRGB colour with small helpers for shading.
struct RGB {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r
        self.g = g
        self.b = b
    }

    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    /// Darkens below 1, lightens towards white above 1.
    func scaled(_ f: CGFloat) -> RGB {
        if f <= 1 { return RGB(r: r * f, g: g * f, b: b * f) }
        let t = min(f - 1, 1)
        return RGB(r: r + (1 - r) * t, g: g + (1 - g) * t, b: b + (1 - b) * t)
    }
}

/// A colour scheme plus a few drawing switches for one kind of rug.
struct RugStyle {
    let id: String
    let name: String
    let field: RGB
    let fieldMotif: RGB
    let border: RGB
    let borderMotif: RGB
    let guardBand: RGB
    let guardMotif: RGB
    let medallionOuter: RGB
    let medallionMid: RGB
    let medallionInner: RGB
    let accent: RGB
    let outline: RGB
    let fringe: RGB
    /// Tribal, stepped motifs instead of curvy city-workshop ones.
    let geometric: Bool
    /// Modern overdyed rugs: the whole pile is tinted with one bold colour.
    var overdye: RGB? = nil
    var overdyeStrength: CGFloat = 0

    static let all: [RugStyle] = [
        RugStyle(id: "tabriz", name: "Tabriz Crimson",
                 field: RGB(0x9E1B22), fieldMotif: RGB(0xE8D3A6), border: RGB(0x13284A), borderMotif: RGB(0xD9B26A),
                 guardBand: RGB(0xE9DCC0), guardMotif: RGB(0x9E1B22), medallionOuter: RGB(0x13284A), medallionMid: RGB(0xE9DCC0),
                 medallionInner: RGB(0x9E1B22), accent: RGB(0x3E7C6A), outline: RGB(0x1B1410), fringe: RGB(0xEDE4D0), geometric: false),
        RugStyle(id: "isfahan", name: "Isfahan Indigo",
                 field: RGB(0x1E2F6B), fieldMotif: RGB(0xC9A86A), border: RGB(0xEFE3C8), borderMotif: RGB(0xA3242F),
                 guardBand: RGB(0xA3242F), guardMotif: RGB(0xEFE3C8), medallionOuter: RGB(0xEFE3C8), medallionMid: RGB(0xA3242F),
                 medallionInner: RGB(0x2E7D8C), accent: RGB(0xD98E3A), outline: RGB(0x0E1430), fringe: RGB(0xF2EAD8), geometric: false),
        RugStyle(id: "kashan", name: "Kashan Rose",
                 field: RGB(0xC9566B), fieldMotif: RGB(0xF2D0C4), border: RGB(0x2D5A3D), borderMotif: RGB(0xF2C4B8),
                 guardBand: RGB(0xF4E2D0), guardMotif: RGB(0x2D5A3D), medallionOuter: RGB(0xF4E2D0), medallionMid: RGB(0x2D5A3D),
                 medallionInner: RGB(0xC9566B), accent: RGB(0xE8A33D), outline: RGB(0x3A1520), fringe: RGB(0xF6EEE2), geometric: false),
        RugStyle(id: "nain", name: "Nain Ivory & Sky",
                 field: RGB(0xEFE6D3), fieldMotif: RGB(0x3B6EA5), border: RGB(0x1F3D73), borderMotif: RGB(0xEFE6D3),
                 guardBand: RGB(0x8FB8DE), guardMotif: RGB(0x1F3D73), medallionOuter: RGB(0x1F3D73), medallionMid: RGB(0x8FB8DE),
                 medallionInner: RGB(0xEFE6D3), accent: RGB(0xC08A2E), outline: RGB(0x182A4A), fringe: RGB(0xF7F2E7), geometric: false),
        RugStyle(id: "heriz", name: "Heriz Terracotta",
                 field: RGB(0xB8532D), fieldMotif: RGB(0xF0DDB8), border: RGB(0x1D3557), borderMotif: RGB(0xE9C46A),
                 guardBand: RGB(0xF0DDB8), guardMotif: RGB(0x1D3557), medallionOuter: RGB(0x1D3557), medallionMid: RGB(0xF0DDB8),
                 medallionInner: RGB(0xB8532D), accent: RGB(0x4C8C6B), outline: RGB(0x24160F), fringe: RGB(0xEFE6D2), geometric: true),
        RugStyle(id: "qashqai", name: "Qashqai Saffron",
                 field: RGB(0xE3A21A), fieldMotif: RGB(0x7A2E1C), border: RGB(0x7A2E1C), borderMotif: RGB(0xF2C14E),
                 guardBand: RGB(0x1F4E5F), guardMotif: RGB(0xF4E7C5), medallionOuter: RGB(0xB5341F), medallionMid: RGB(0x1F4E5F),
                 medallionInner: RGB(0xF4E7C5), accent: RGB(0x2F7A4B), outline: RGB(0x2A1A12), fringe: RGB(0xEBDDBE), geometric: true),
        RugStyle(id: "shiraz", name: "Shiraz Turquoise",
                 field: RGB(0x1FA3A0), fieldMotif: RGB(0x0D5C63), border: RGB(0xE2553C), borderMotif: RGB(0xFBE3B0),
                 guardBand: RGB(0xFBE3B0), guardMotif: RGB(0xE2553C), medallionOuter: RGB(0xF3B33D), medallionMid: RGB(0xE2553C),
                 medallionInner: RGB(0x0D3B66), accent: RGB(0xFBE3B0), outline: RGB(0x0B2A33), fringe: RGB(0xF4EBD9), geometric: true),
        RugStyle(id: "fuchsia", name: "Overdyed Fuchsia",
                 field: RGB(0x9E1B22), fieldMotif: RGB(0xE8D3A6), border: RGB(0x13284A), borderMotif: RGB(0xD9B26A),
                 guardBand: RGB(0xE9DCC0), guardMotif: RGB(0x9E1B22), medallionOuter: RGB(0x13284A), medallionMid: RGB(0xE9DCC0),
                 medallionInner: RGB(0x9E1B22), accent: RGB(0x3E7C6A), outline: RGB(0x1B1410), fringe: RGB(0xF3E6EC), geometric: false,
                 overdye: RGB(0xF0158C), overdyeStrength: 0.85),
        RugStyle(id: "electric", name: "Overdyed Electric Blue",
                 field: RGB(0xB8532D), fieldMotif: RGB(0xF0DDB8), border: RGB(0x1D3557), borderMotif: RGB(0xE9C46A),
                 guardBand: RGB(0xF0DDB8), guardMotif: RGB(0x1D3557), medallionOuter: RGB(0x1D3557), medallionMid: RGB(0xF0DDB8),
                 medallionInner: RGB(0xB8532D), accent: RGB(0x4C8C6B), outline: RGB(0x24160F), fringe: RGB(0xE6ECF6), geometric: true,
                 overdye: RGB(0x1F6FFF), overdyeStrength: 0.85),
        RugStyle(id: "bazaar", name: "Acid Bazaar",
                 field: RGB(0x7B2CBF), fieldMotif: RGB(0xF72585), border: RGB(0xFFBE0B), borderMotif: RGB(0x3A86FF),
                 guardBand: RGB(0x06D6A0), guardMotif: RGB(0x7B2CBF), medallionOuter: RGB(0xF72585), medallionMid: RGB(0xFFBE0B),
                 medallionInner: RGB(0x3A86FF), accent: RGB(0x06D6A0), outline: RGB(0x1B0B2E), fringe: RGB(0xFFF4E0), geometric: true),
    ]

    static func named(_ id: String) -> RugStyle {
        all.first { $0.id == id } ?? all[0]
    }
}
