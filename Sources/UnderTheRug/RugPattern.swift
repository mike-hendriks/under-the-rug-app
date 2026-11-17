import CoreGraphics
import Foundation

/// Deterministic random numbers, so a style looks the same on every launch.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}

/// Procedural Persian rug artwork: fringe, kilim ends, guard stripes, main border, field lattice,
/// corner spandrels and a central medallion with pendants. Everything is sized relative to the
/// texture height, so the same code draws a 2048 px texture and a 36 px menu swatch.
enum RugPattern {
    /// Share of the texture width taken by the fringe at each short end.
    static let fringeFraction: CGFloat = 0.055

    /// Draws the whole rug for `s` into `ctx`, filling `W` x `H` (y up, origin bottom left).
    static func draw(_ s: RugStyle, in ctx: CGContext, width W: CGFloat, height H: CGFloat) {
        var rng = SplitMix64(seed: stableSeed(s.id))
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        let u = H / 1000
        let fl = (W * fringeFraction).rounded()
        let body = CGRect(x: fl, y: 0, width: W - 2 * fl, height: H)
        let lw = max(0.6, 2.8 * u)

        drawFringe(s, ctx, body: body, length: fl, u: u, rng: &rng)

        ctx.saveGState()
        ctx.clip(to: body)

        // Kilim ends: the flat-woven band between the knotted pile and the fringe.
        let kilim = 24 * u
        ctx.setFillColor(s.fringe.scaled(0.9).cg())
        ctx.fill(body)
        for x in [body.minX, body.maxX - kilim] {
            ctx.setFillColor(s.border.cg())
            ctx.fill(CGRect(x: x + kilim * 0.3, y: 0, width: kilim * 0.14, height: H))
            ctx.setFillColor(s.medallionOuter.cg())
            ctx.fill(CGRect(x: x + kilim * 0.62, y: 0, width: kilim * 0.1, height: H))
        }

        // Selvedge cords along the long edges.
        var r = body.insetBy(dx: kilim, dy: 0)
        ctx.setFillColor(s.outline.cg())
        ctx.fill(r)
        r = r.insetBy(dx: lw, dy: 6 * u)

        let outerGuard = 30 * u
        let mainBorder = 96 * u
        let innerGuard = 24 * u
        let r2 = r.insetBy(dx: outerGuard, dy: outerGuard)
        let r3 = r2.insetBy(dx: mainBorder, dy: mainBorder)
        let field = r3.insetBy(dx: innerGuard, dy: innerGuard)

        ctx.setFillColor(s.guardBand.cg())
        ctx.fill(r)
        drawGuard(s, ctx, outer: r, width: outerGuard, variant: 0, u: u)
        ctx.setFillColor(s.border.cg())
        ctx.fill(r2)
        drawMainBorder(s, ctx, outer: r2, width: mainBorder, u: u)
        ctx.setFillColor(s.guardBand.cg())
        ctx.fill(r3)
        drawGuard(s, ctx, outer: r3, width: innerGuard, variant: 1, u: u)
        drawField(s, ctx, field: field, u: u, rng: &rng)

        ctx.setStrokeColor(s.outline.cg())
        ctx.setLineWidth(lw)
        for rect in [r2, r3, field] { ctx.stroke(rect) }

        // Wear: lighter patches where feet have walked for a century or two.
        for _ in 0..<140 {
            let p = CGPoint(x: rng.range(body.minX, body.maxX), y: rng.range(0, H))
            let rad = rng.range(8, 50) * u
            ctx.setFillColor(CGColor(gray: 1, alpha: rng.range(0.008, 0.025)))
            ctx.fillEllipse(in: CGRect(x: p.x - rad, y: p.y - rad * 0.6, width: rad * 2, height: rad * 1.2))
        }

        if let dye = s.overdye {
            // Keep the pattern's lightness, take the dye's hue: the look of a stripped and overdyed antique.
            ctx.setBlendMode(.color)
            ctx.setFillColor(dye.cg(s.overdyeStrength))
            ctx.fill(body)
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()
    }

    // MARK: - Fringe

    private static func drawFringe(_ s: RugStyle, _ ctx: CGContext, body: CGRect, length fl: CGFloat, u: CGFloat, rng: inout SplitMix64) {
        let H = body.height
        let count = max(8, Int(H / (9 * u)))
        let spacing = H / CGFloat(count)
        ctx.setLineCap(.round)
        for end in [-1.0, 1.0] as [CGFloat] {
            let edge = end < 0 ? body.minX : body.maxX
            ctx.setLineWidth(max(0.5, 5 * u))
            for k in 0..<count {
                let y = (CGFloat(k) + 0.5) * spacing
                let len = fl * rng.range(0.78, 0.96)
                let sway = rng.range(-1, 1) * 7 * u
                ctx.setStrokeColor(s.fringe.scaled(rng.range(0.84, 1.02)).cg())
                ctx.move(to: CGPoint(x: edge, y: y))
                ctx.addQuadCurve(to: CGPoint(x: edge + end * len, y: y + sway * 1.6),
                                 control: CGPoint(x: edge + end * len * 0.55, y: y + sway))
                ctx.strokePath()
            }
            // Knots that bundle the warp threads.
            let group = 5
            var k = 0
            ctx.setFillColor(s.fringe.scaled(0.8).cg())
            while k < count {
                let y0 = CGFloat(k) * spacing
                let y1 = CGFloat(min(k + group, count)) * spacing
                let knot = CGRect(x: end < 0 ? edge - 16 * u : edge + 4 * u, y: y0 + spacing * 0.6,
                                  width: 12 * u, height: max(1, y1 - y0 - spacing * 1.2))
                ctx.addPath(CGPath(roundedRect: knot, cornerWidth: 5 * u, cornerHeight: 5 * u, transform: nil))
                ctx.fillPath()
                k += group
            }
        }
    }

    // MARK: - Borders

    private static func clipToBand(_ ctx: CGContext, _ outer: CGRect, _ w: CGFloat) {
        ctx.addRect(outer)
        ctx.addRect(outer.insetBy(dx: w, dy: w))
        ctx.clip(using: .evenOdd)
    }

    /// Calls `side` with evenly spaced centre points along a frame band (with the outward angle and
    /// an index), and `corner` for its four corner squares.
    private static func alongBand(outer: CGRect, width w: CGFloat, step: CGFloat,
                                  side: (CGPoint, CGFloat, Int) -> Void, corner: (CGPoint) -> Void) {
        let mid = outer.insetBy(dx: w / 2, dy: w / 2)
        let hLen = mid.width - w
        let hn = max(1, Int((hLen / step).rounded()))
        let hs = hLen / CGFloat(hn)
        for y in [mid.minY, mid.maxY] {
            for i in 0..<hn {
                side(CGPoint(x: mid.minX + w / 2 + (CGFloat(i) + 0.5) * hs, y: y), y == mid.maxY ? .pi / 2 : -.pi / 2, i)
            }
        }
        let vLen = mid.height - w
        let vn = max(1, Int((vLen / step).rounded()))
        let vs = vLen / CGFloat(vn)
        for x in [mid.minX, mid.maxX] {
            for i in 0..<vn {
                side(CGPoint(x: x, y: mid.minY + w / 2 + (CGFloat(i) + 0.5) * vs), x == mid.maxX ? 0 : .pi, i)
            }
        }
        for p in [CGPoint(x: mid.minX, y: mid.minY), CGPoint(x: mid.maxX, y: mid.minY),
                  CGPoint(x: mid.minX, y: mid.maxY), CGPoint(x: mid.maxX, y: mid.maxY)] {
            corner(p)
        }
    }

    private static func drawGuard(_ s: RugStyle, _ ctx: CGContext, outer: CGRect, width w: CGFloat, variant: Int, u: CGFloat) {
        ctx.saveGState()
        clipToBand(ctx, outer, w)
        alongBand(outer: outer, width: w, step: w * 1.1, side: { p, _, i in
            if (i + variant) % 2 == 0 {
                diamond(ctx, center: p, rx: w * 0.36, ry: w * 0.36, color: s.guardMotif)
                dot(ctx, p, w * 0.11, s.guardBand)
            } else {
                dot(ctx, p, w * 0.13, s.accent)
            }
        }, corner: { p in
            rosette(ctx, center: p, radius: w * 0.45, petals: 6, petal: s.guardMotif, core: s.accent, outline: s.outline, lw: 1.5 * u)
        })
        ctx.restoreGState()
    }

    private static func drawMainBorder(_ s: RugStyle, _ ctx: CGContext, outer: CGRect, width w: CGFloat, u: CGFloat) {
        ctx.saveGState()
        clipToBand(ctx, outer, w)
        let lw = max(0.5, 2 * u)
        let step = w * 1.15

        if s.geometric {
            // Reciprocal teeth along both edges of the band.
            let inner = outer.insetBy(dx: w, dy: w)
            for rect in [outer, inner] {
                ctx.setStrokeColor(s.borderMotif.cg(0.8))
                ctx.setLineWidth(max(0.5, 5 * u))
                ctx.setLineDash(phase: 0, lengths: [9 * u, 9 * u])
                ctx.stroke(rect.insetBy(dx: rect == outer ? 9 * u : -9 * u, dy: rect == outer ? 9 * u : -9 * u))
                ctx.setLineDash(phase: 0, lengths: [])
            }
            alongBand(outer: outer, width: w, step: step, side: { p, _, i in
                if i % 2 == 0 {
                    paint(ctx, steppedDiamond(p, rx: w * 0.36, ry: w * 0.36, steps: 3), fill: s.borderMotif, stroke: s.outline, lw: lw)
                    paint(ctx, steppedDiamond(p, rx: w * 0.17, ry: w * 0.17, steps: 2), fill: s.accent, stroke: nil, lw: 0)
                    dot(ctx, p, w * 0.05, s.outline)
                } else {
                    ctx.setFillColor(s.medallionMid.cg())
                    ctx.fill(CGRect(x: p.x - w * 0.2, y: p.y - w * 0.05, width: w * 0.4, height: w * 0.1))
                    ctx.fill(CGRect(x: p.x - w * 0.05, y: p.y - w * 0.2, width: w * 0.1, height: w * 0.4))
                    for (dx, dy) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] as [(CGFloat, CGFloat)] {
                        dot(ctx, CGPoint(x: p.x + dx * w * 0.2, y: p.y + dy * w * 0.2), w * 0.05, s.borderMotif)
                    }
                }
            }, corner: { p in
                paint(ctx, steppedDiamond(p, rx: w * 0.44, ry: w * 0.44, steps: 4), fill: s.medallionOuter, stroke: s.outline, lw: lw)
                paint(ctx, steppedDiamond(p, rx: w * 0.22, ry: w * 0.22, steps: 2), fill: s.borderMotif, stroke: nil, lw: 0)
            })
        } else {
            drawVine(s, ctx, outer: outer, width: w, step: step, u: u)
            alongBand(outer: outer, width: w, step: step, side: { p, angle, i in
                if i % 2 == 0 {
                    rosette(ctx, center: p, radius: w * 0.3, petals: 8, petal: s.borderMotif, core: s.medallionInner, outline: s.outline, lw: lw)
                } else {
                    let flip: CGFloat = (i / 2) % 2 == 0 ? 0 : .pi
                    palmette(ctx, center: p, size: w * 0.3, angle: angle + flip, fill: s.medallionMid, inner: s.accent, outline: s.outline, lw: lw)
                }
            }, corner: { p in
                rosette(ctx, center: p, radius: w * 0.42, petals: 10, petal: s.borderMotif, core: s.medallionOuter, outline: s.outline, lw: lw)
            })
        }
        ctx.restoreGState()
    }

    /// A sine-shaped vine with small leaves, threading between the border motifs.
    private static func drawVine(_ s: RugStyle, _ ctx: CGContext, outer: CGRect, width w: CGFloat, step: CGFloat, u: CGFloat) {
        let mid = outer.insetBy(dx: w / 2, dy: w / 2)
        let amp = w * 0.26
        ctx.setStrokeColor(s.accent.cg(0.95))
        ctx.setLineWidth(max(0.5, 4 * u))
        // (start, direction, length, normal)
        let sides: [(CGPoint, CGVector, CGFloat, CGVector)] = [
            (CGPoint(x: mid.minX + w / 2, y: mid.minY), CGVector(dx: 1, dy: 0), mid.width - w, CGVector(dx: 0, dy: 1)),
            (CGPoint(x: mid.minX + w / 2, y: mid.maxY), CGVector(dx: 1, dy: 0), mid.width - w, CGVector(dx: 0, dy: 1)),
            (CGPoint(x: mid.minX, y: mid.minY + w / 2), CGVector(dx: 0, dy: 1), mid.height - w, CGVector(dx: 1, dy: 0)),
            (CGPoint(x: mid.maxX, y: mid.minY + w / 2), CGVector(dx: 0, dy: 1), mid.height - w, CGVector(dx: 1, dy: 0)),
        ]
        for (start, dir, len, normal) in sides {
            let n = max(1, Int((len / step).rounded()))
            let seg = len / CGFloat(n)
            let samples = n * 24
            for k in 0...samples {
                let t = CGFloat(k) / CGFloat(samples) * len
                // Zero crossings at each motif centre, alternating sides in between.
                let off = amp * sin(.pi * (t / seg - 0.5))
                let p = CGPoint(x: start.x + dir.dx * t + normal.dx * off, y: start.y + dir.dy * t + normal.dy * off)
                if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
            for i in 0..<n {
                let t = (CGFloat(i) + 1) * seg - seg * 0.25
                let off = amp * sin(.pi * (t / seg - 0.5))
                let p = CGPoint(x: start.x + dir.dx * t + normal.dx * off, y: start.y + dir.dy * t + normal.dy * off)
                let a = atan2(dir.dy, dir.dx) + (i % 2 == 0 ? 0.7 : -0.7)
                leaf(ctx, center: p, length: w * 0.22, width: w * 0.08, angle: a, color: s.accent)
            }
        }
    }

    // MARK: - Field

    private static func drawField(_ s: RugStyle, _ ctx: CGContext, field: CGRect, u: CGFloat, rng: inout SplitMix64) {
        ctx.saveGState()
        ctx.clip(to: field)
        ctx.setFillColor(s.field.cg())
        ctx.fill(field)

        // Abrash: bands where a new batch of dyed wool was used, running across the warp.
        var x = field.minX
        while x < field.maxX {
            let w = rng.range(30, 160) * u
            let dark = rng.unit() < 0.5
            ctx.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: rng.range(0, 0.06)))
            ctx.fill(CGRect(x: x, y: field.minY, width: w, height: field.height))
            x += w
        }

        if s.geometric {
            geometricLattice(s, ctx, field: field, u: u)
        } else {
            floralLattice(s, ctx, field: field, u: u)
        }
        for sx in [-1.0, 1.0] as [CGFloat] {
            for sy in [-1.0, 1.0] as [CGFloat] {
                spandrel(s, ctx, field: field, sx: sx, sy: sy, u: u)
            }
        }
        if s.geometric {
            geometricMedallion(s, ctx, field: field, u: u)
        } else {
            floralMedallion(s, ctx, field: field, u: u)
        }
        ctx.restoreGState()
    }

    private static func floralLattice(_ s: RugStyle, _ ctx: CGContext, field: CGRect, u: CGFloat) {
        let L = field.height / 6
        let c = CGPoint(x: field.midX, y: field.midY)
        let nx = Int(field.width / L / 2) + 2
        let ny = Int(field.height / L / 2) + 2
        func node(_ i: Int, _ j: Int) -> CGPoint { CGPoint(x: c.x + CGFloat(i) * L, y: c.y + CGFloat(j) * L) }

        ctx.setStrokeColor(s.fieldMotif.cg(0.45))
        ctx.setLineWidth(max(0.5, 3.2 * u))
        for i in -nx...nx {
            for j in -ny...ny where (i + j) & 1 == 0 {
                let p = node(i, j)
                for (di, dj) in [(1, 1), (1, -1)] {
                    let q = node(i + di, j + dj)
                    let m = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                    let bend: CGFloat = (i & 1 == 0) ? 0.12 : -0.12
                    let ctl = CGPoint(x: m.x - CGFloat(dj) * L * bend, y: m.y + CGFloat(di) * L * bend)
                    ctx.move(to: p)
                    ctx.addQuadCurve(to: q, control: ctl)
                }
            }
        }
        ctx.strokePath()

        for i in -nx...nx {
            for j in -ny...ny {
                let p = node(i, j)
                if (i + j) & 1 == 0 {
                    for k in 0..<4 {
                        let a = CGFloat(k) * .pi / 2
                        leaf(ctx, center: CGPoint(x: p.x + cos(a) * L * 0.34, y: p.y + sin(a) * L * 0.34),
                             length: L * 0.28, width: L * 0.085, angle: a, color: s.accent)
                    }
                    rosette(ctx, center: p, radius: L * 0.17, petals: 6, petal: s.fieldMotif, core: s.accent, outline: s.outline, lw: max(0.4, 1.4 * u))
                } else {
                    ctx.setFillColor(s.fieldMotif.cg(0.8))
                    ctx.addPath(diamondPath(p, rx: L * 0.12, ry: L * 0.17))
                    ctx.fillPath()
                    dot(ctx, p, L * 0.04, s.medallionInner)
                }
            }
        }
    }

    private static func geometricLattice(_ s: RugStyle, _ ctx: CGContext, field: CGRect, u: CGFloat) {
        let L = field.height / 6.5
        let c = CGPoint(x: field.midX, y: field.midY)
        let nx = Int(field.width / L / 2) + 2
        let ny = Int(field.height / L / 2) + 2
        let palette = [s.fieldMotif, s.accent, s.medallionMid, s.borderMotif]
        let lw = max(0.4, 1.6 * u)
        for j in -ny...ny {
            for i in -nx...nx {
                let shift: CGFloat = (j & 1 == 0) ? 0 : 0.5
                let p = CGPoint(x: c.x + (CGFloat(i) + shift) * L, y: c.y + CGFloat(j) * L)
                let color = palette[(abs(i) + abs(j)) % palette.count]
                paint(ctx, steppedDiamond(p, rx: L * 0.24, ry: L * 0.3, steps: 3), fill: color, stroke: s.outline, lw: lw)
                paint(ctx, steppedDiamond(p, rx: L * 0.11, ry: L * 0.14, steps: 2), fill: s.field, stroke: nil, lw: 0)
                dot(ctx, p, L * 0.035, palette[(abs(i) + abs(j) + 1) % palette.count])
                // Little crosses between the diamonds.
                let q = CGPoint(x: p.x + L * 0.5, y: p.y + L * 0.5)
                ctx.setFillColor(s.fieldMotif.cg(0.7))
                ctx.fill(CGRect(x: q.x - L * 0.08, y: q.y - L * 0.02, width: L * 0.16, height: L * 0.04))
                ctx.fill(CGRect(x: q.x - L * 0.02, y: q.y - L * 0.08, width: L * 0.04, height: L * 0.16))
            }
        }
    }

    private static func spandrel(_ s: RugStyle, _ ctx: CGContext, field: CGRect, sx: CGFloat, sy: CGFloat, u: CGFloat) {
        let corner = CGPoint(x: sx < 0 ? field.minX : field.maxX, y: sy < 0 ? field.minY : field.maxY)
        let lw = max(0.5, 2.4 * u)
        if s.geometric {
            let rx = field.width * 0.17, ry = field.height * 0.3
            paint(ctx, steppedDiamond(corner, rx: rx * 1.05, ry: ry * 1.05, steps: 7), fill: s.outline, stroke: nil, lw: 0)
            paint(ctx, steppedDiamond(corner, rx: rx, ry: ry, steps: 7), fill: s.medallionOuter, stroke: nil, lw: 0)
            paint(ctx, steppedDiamond(corner, rx: rx * 0.64, ry: ry * 0.64, steps: 5), fill: s.medallionMid, stroke: s.outline, lw: lw)
            paint(ctx, steppedDiamond(corner, rx: rx * 0.32, ry: ry * 0.32, steps: 3), fill: s.medallionInner, stroke: s.outline, lw: lw)
        } else {
            let rx = field.width * 0.2, ry = field.height * 0.3
            paint(ctx, lobedPath(corner, rx: rx, ry: ry, lobes: 14, depth: 0.07), fill: s.medallionOuter, stroke: s.outline, lw: lw)
            paint(ctx, lobedPath(corner, rx: rx * 0.7, ry: ry * 0.7, lobes: 10, depth: 0.09), fill: s.medallionMid, stroke: s.outline, lw: lw)
            let base = atan2(-sy, -sx)
            for k in -1...1 {
                let a = base + CGFloat(k) * 0.5
                rosette(ctx, center: CGPoint(x: corner.x + cos(a) * rx * 0.84, y: corner.y + sin(a) * ry * 0.84),
                        radius: ry * 0.06, petals: 6, petal: s.medallionInner, core: s.accent, outline: s.outline, lw: lw * 0.6)
            }
            rosette(ctx, center: CGPoint(x: corner.x + cos(base) * rx * 0.4, y: corner.y + sin(base) * ry * 0.4),
                    radius: ry * 0.1, petals: 8, petal: s.accent, core: s.medallionOuter, outline: s.outline, lw: lw * 0.6)
        }
    }

    private static func floralMedallion(_ s: RugStyle, _ ctx: CGContext, field: CGRect, u: CGFloat) {
        let c = CGPoint(x: field.midX, y: field.midY)
        let rx = field.width * 0.25, ry = field.height * 0.34
        let lw = max(0.5, 2.8 * u)

        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.setFillColor(s.medallionOuter.cg())
            let stemX = side < 0 ? c.x - rx * 1.2 : c.x + rx * 0.85
            ctx.fill(CGRect(x: stemX, y: c.y - ry * 0.035, width: rx * 0.35, height: ry * 0.07))
            let pc = CGPoint(x: c.x + side * rx * 1.2, y: c.y)
            paint(ctx, lobedPath(pc, rx: rx * 0.13, ry: ry * 0.22, lobes: 8, depth: 0.12), fill: s.medallionMid, stroke: s.outline, lw: lw)
            rosette(ctx, center: pc, radius: ry * 0.08, petals: 6, petal: s.medallionInner, core: s.accent, outline: s.outline, lw: lw * 0.6)
            palmette(ctx, center: CGPoint(x: c.x + side * rx * 1.42, y: c.y), size: ry * 0.09,
                     angle: side > 0 ? 0 : .pi, fill: s.medallionOuter, inner: s.accent, outline: s.outline, lw: lw * 0.7)
        }

        paint(ctx, lobedPath(c, rx: rx, ry: ry, lobes: 16, depth: 0.07), fill: s.medallionOuter, stroke: s.outline, lw: lw * 1.3)
        for k in 0..<16 {
            let a = CGFloat(k) / 16 * 2 * .pi
            let p = CGPoint(x: c.x + cos(a) * rx * 0.8, y: c.y + sin(a) * ry * 0.8)
            if k % 2 == 0 {
                rosette(ctx, center: p, radius: ry * 0.05, petals: 6, petal: s.medallionInner, core: s.accent, outline: s.outline, lw: lw * 0.5)
            } else {
                dot(ctx, p, ry * 0.018, s.medallionMid)
            }
        }
        paint(ctx, lobedPath(c, rx: rx * 0.7, ry: ry * 0.7, lobes: 12, depth: 0.09), fill: s.medallionMid, stroke: s.outline, lw: lw)
        paint(ctx, starPath(c, rx: rx * 0.52, ry: ry * 0.52, points: 8, inner: 0.62), fill: s.medallionInner, stroke: s.outline, lw: lw)
        paint(ctx, lobedPath(c, rx: rx * 0.28, ry: ry * 0.28, lobes: 8, depth: 0.12), fill: s.medallionOuter, stroke: s.outline, lw: lw)
        rosette(ctx, center: c, radius: min(rx, ry) * 0.17, petals: 8, petal: s.accent, core: s.medallionMid, outline: s.outline, lw: lw * 0.7)
    }

    private static func geometricMedallion(_ s: RugStyle, _ ctx: CGContext, field: CGRect, u: CGFloat) {
        let c = CGPoint(x: field.midX, y: field.midY)
        let rx = field.width * 0.24, ry = field.height * 0.36
        let lw = max(0.5, 2.6 * u)

        for side in [-1.0, 1.0] as [CGFloat] {
            let pc = CGPoint(x: c.x + side * rx * 1.13, y: c.y)
            ctx.setFillColor(s.outline.cg())
            ctx.fill(CGRect(x: side < 0 ? pc.x : c.x + rx * 0.9, y: c.y - ry * 0.03, width: rx * 0.23, height: ry * 0.06))
            paint(ctx, steppedDiamond(pc, rx: rx * 0.12, ry: ry * 0.17, steps: 3), fill: s.medallionMid, stroke: s.outline, lw: lw)
            dot(ctx, pc, ry * 0.03, s.accent)
        }
        paint(ctx, steppedDiamond(c, rx: rx * 1.05, ry: ry * 1.05, steps: 8), fill: s.outline, stroke: nil, lw: 0)
        paint(ctx, steppedDiamond(c, rx: rx, ry: ry, steps: 8), fill: s.medallionOuter, stroke: nil, lw: 0)
        for k in 0..<8 {
            let a = CGFloat(k) / 8 * 2 * .pi
            let p = CGPoint(x: c.x + cos(a) * rx * 0.72, y: c.y + sin(a) * ry * 0.72)
            paint(ctx, steppedDiamond(p, rx: rx * 0.06, ry: ry * 0.07, steps: 2), fill: s.medallionInner, stroke: nil, lw: 0)
        }
        paint(ctx, steppedDiamond(c, rx: rx * 0.6, ry: ry * 0.6, steps: 6), fill: s.outline, stroke: nil, lw: 0)
        paint(ctx, steppedDiamond(c, rx: rx * 0.57, ry: ry * 0.57, steps: 6), fill: s.medallionMid, stroke: nil, lw: 0)
        paint(ctx, octagonPath(c, rx: rx * 0.34, ry: ry * 0.34), fill: s.medallionInner, stroke: s.outline, lw: lw)
        paint(ctx, steppedDiamond(c, rx: rx * 0.16, ry: ry * 0.16, steps: 2), fill: s.accent, stroke: s.outline, lw: lw)
        dot(ctx, c, ry * 0.035, s.outline)
    }

    // MARK: - Shapes

    private static func paint(_ ctx: CGContext, _ path: CGPath, fill: RGB, stroke: RGB?, lw: CGFloat) {
        ctx.addPath(path)
        ctx.setFillColor(fill.cg())
        ctx.fillPath()
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cg())
            ctx.setLineWidth(lw)
            ctx.strokePath()
        }
    }

    private static func dot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: RGB) {
        ctx.setFillColor(color.cg())
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private static func diamondPath(_ c: CGPoint, rx: CGFloat, ry: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: c.x, y: c.y + ry), CGPoint(x: c.x + rx, y: c.y),
                             CGPoint(x: c.x, y: c.y - ry), CGPoint(x: c.x - rx, y: c.y)])
        p.closeSubpath()
        return p
    }

    private static func diamond(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat, color: RGB) {
        ctx.addPath(diamondPath(center, rx: rx, ry: ry))
        ctx.setFillColor(color.cg())
        ctx.fillPath()
    }

    /// An ellipse whose radius ripples `lobes` times, the classic cusped outline of a medallion.
    private static func lobedPath(_ c: CGPoint, rx: CGFloat, ry: CGFloat, lobes: Int, depth: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n = 360
        for k in 0...n {
            let t = CGFloat(k) / CGFloat(n) * 2 * .pi
            let rr = (1 + depth * cos(CGFloat(lobes) * t)) / (1 + depth)
            let pt = CGPoint(x: c.x + rx * rr * cos(t), y: c.y + ry * rr * sin(t))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private static func starPath(_ c: CGPoint, rx: CGFloat, ry: CGFloat, points n: Int, inner: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for k in 0..<(2 * n) {
            let a = CGFloat(k) * .pi / CGFloat(n)
            let f = k % 2 == 0 ? 1 : inner
            let pt = CGPoint(x: c.x + cos(a) * rx * f, y: c.y + sin(a) * ry * f)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private static func octagonPath(_ c: CGPoint, rx: CGFloat, ry: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4 + .pi / 8
            let pt = CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    /// A diamond with stair-stepped edges, the building block of tribal designs.
    private static func steppedDiamond(_ c: CGPoint, rx: CGFloat, ry: CGFloat, steps: Int) -> CGPath {
        let n = max(1, steps)
        let dx = rx / CGFloat(n), dy = ry / CGFloat(n)
        var q: [CGPoint] = []
        for i in 0..<n {
            q.append(CGPoint(x: CGFloat(i) * dx, y: ry - CGFloat(i) * dy))
            q.append(CGPoint(x: CGFloat(i + 1) * dx, y: ry - CGFloat(i) * dy))
        }
        q.append(CGPoint(x: rx, y: 0))
        // Mirror the top-right quadrant around the other three.
        let pts = q + q.reversed().map { CGPoint(x: $0.x, y: -$0.y) }
            + q.map { CGPoint(x: -$0.x, y: -$0.y) } + q.reversed().map { CGPoint(x: -$0.x, y: $0.y) }
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) })
        p.closeSubpath()
        return p
    }

    private static func rosette(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, petals: Int,
                                petal: RGB, core: RGB, outline: RGB, lw: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.setLineWidth(lw)
        for k in 0..<petals {
            ctx.saveGState()
            ctx.rotate(by: CGFloat(k) / CGFloat(petals) * 2 * .pi)
            let rect = CGRect(x: r * 0.2, y: -r * 0.21, width: r * 0.8, height: r * 0.42)
            ctx.setFillColor(petal.cg())
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(outline.cg())
            ctx.strokeEllipse(in: rect)
            ctx.restoreGState()
        }
        let coreRect = CGRect(x: -r * 0.32, y: -r * 0.32, width: r * 0.64, height: r * 0.64)
        ctx.setFillColor(core.cg())
        ctx.fillEllipse(in: coreRect)
        ctx.setStrokeColor(outline.cg())
        ctx.strokeEllipse(in: coreRect)
        ctx.restoreGState()
    }

    private static func teardrop(size s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: s))
        p.addCurve(to: CGPoint(x: 0, y: -s * 0.7), control1: CGPoint(x: s * 0.9, y: s * 0.1), control2: CGPoint(x: s * 0.6, y: -s * 0.7))
        p.addCurve(to: CGPoint(x: 0, y: s), control1: CGPoint(x: -s * 0.6, y: -s * 0.7), control2: CGPoint(x: -s * 0.9, y: s * 0.1))
        p.closeSubpath()
        return p
    }

    /// A lotus palmette whose tip points along `angle`.
    private static func palmette(_ ctx: CGContext, center: CGPoint, size s: CGFloat, angle: CGFloat,
                                 fill: RGB, inner: RGB, outline: RGB, lw: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle - .pi / 2)
        let path = teardrop(size: s)
        paint(ctx, path, fill: fill, stroke: outline, lw: lw)
        var t = CGAffineTransform(translationX: 0, y: -s * 0.12).scaledBy(x: 0.55, y: 0.55)
        if let innerPath = path.copy(using: &t) {
            paint(ctx, innerPath, fill: inner, stroke: nil, lw: 0)
        }
        ctx.restoreGState()
    }

    private static func leaf(_ ctx: CGContext, center: CGPoint, length: CGFloat, width: CGFloat, angle: CGFloat, color: RGB) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.setFillColor(color.cg(0.9))
        ctx.fillEllipse(in: CGRect(x: -length / 2, y: -width / 2, width: length, height: width))
        ctx.restoreGState()
    }

    // MARK: - Floor under the rug

    /// Dim oak floorboards with dust and a few dust bunnies: what you find when you lift the rug.
    static func drawFloor(in ctx: CGContext, width W: CGFloat, height H: CGFloat) {
        var rng = SplitMix64(seed: 0xF100F)
        let oak = RGB(0x7A5232)
        let plank = H / 5.5
        let k = H / 683
        var y: CGFloat = 0
        while y < H {
            var x = -rng.range(0, W * 0.5)
            while x < W {
                let len = rng.range(W * 0.35, W * 0.75)
                let tone = rng.range(0.78, 1.08)
                let rect = CGRect(x: x, y: y, width: len, height: plank)
                ctx.setFillColor(oak.scaled(tone).cg())
                ctx.fill(rect)
                ctx.saveGState()
                ctx.clip(to: rect)
                for _ in 0..<12 {
                    let gy = y + rng.range(0.05, 0.95) * plank
                    let amp = rng.range(1, 5) * k
                    let freq = rng.range(0.004, 0.012) / k
                    let phase = rng.range(0, 6.28)
                    ctx.setStrokeColor(oak.scaled(tone * 0.7).cg(rng.range(0.15, 0.4)))
                    ctx.setLineWidth(rng.range(0.6, 1.8) * k)
                    ctx.move(to: CGPoint(x: x, y: gy))
                    var gx = x
                    while gx <= x + len {
                        ctx.addLine(to: CGPoint(x: gx, y: gy + sin(gx * freq + phase) * amp))
                        gx += 8 * k
                    }
                    ctx.strokePath()
                }
                ctx.restoreGState()
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
                ctx.fill(CGRect(x: x + len - 1.5 * k, y: y, width: 3 * k, height: plank))
                x += len
            }
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
            ctx.fill(CGRect(x: 0, y: y - 1.5 * k, width: W, height: 3 * k))
            y += plank
        }

        for _ in 0..<1600 {
            let r = rng.range(0.5, 1.8) * k
            ctx.setFillColor(CGColor(gray: 0.85, alpha: rng.range(0.08, 0.3)))
            ctx.fillEllipse(in: CGRect(x: rng.range(0, W), y: rng.range(0, H), width: r * 2, height: r * 2))
        }
        ctx.setLineCap(.round)
        for _ in 0..<5 {
            let c = CGPoint(x: rng.range(W * 0.1, W * 0.9), y: rng.range(H * 0.1, H * 0.9))
            let size = rng.range(14, 30) * k
            ctx.setLineWidth(1 * k)
            for _ in 0..<140 {
                let a = rng.range(0, 2 * .pi)
                let r0 = rng.range(0, size)
                let len = rng.range(4, 16) * k
                let b = a + rng.range(-1, 1)
                let p = CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0)
                ctx.setStrokeColor(CGColor(gray: 0.78, alpha: rng.range(0.15, 0.35)))
                ctx.move(to: p)
                ctx.addLine(to: CGPoint(x: p.x + cos(b) * len, y: p.y + sin(b) * len))
                ctx.strokePath()
            }
        }

        // It is dark under a rug.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.6)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.translateBy(x: W / 2, y: H / 2)
            ctx.scaleBy(x: W / 2, y: H / 2)
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0.35, endCenter: .zero, endRadius: 1.2,
                                   options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    /// FNV-1a, because String.hashValue changes on every launch.
    static func stableSeed(_ text: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01B3
        }
        return h
    }
}
