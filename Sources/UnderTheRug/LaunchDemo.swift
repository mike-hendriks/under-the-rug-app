import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

/// The launch GIF in the README: a 12 second motion piece, scripted frame by frame on top of the real
/// cloth simulation and renderer. A messy desktop, a rug slamming down, every file getting sucked under it
/// (the lumps crawl under the cloth), ten styles in rapid fire, a pile of rugs, the big reveal, an end card.
///
///     UnderTheRug --demo docs/demo.gif
enum LaunchDemo {
    private static let canvas = SIMD2<Float>(1280, 800)
    private static let fps: Double = 12
    private static let duration: Double = 12.6
    private static let outputWidth = 640

    // Sticker colours, taken from the rugs.
    private static let crimson = NSColor(srgbRed: 0.90, green: 0.22, blue: 0.27, alpha: 1)
    private static let saffron = NSColor(srgbRed: 1.00, green: 0.75, blue: 0.04, alpha: 1)
    private static let fuchsia = NSColor(srgbRed: 0.97, green: 0.15, blue: 0.52, alpha: 1)
    private static let mint = NSColor(srgbRed: 0.02, green: 0.84, blue: 0.63, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.07, green: 0.05, blue: 0.12, alpha: 1)

    // MARK: - Cast

    private final class FileIcon {
        let id = UUID()
        let name: String
        let image: NSImage
        let home: SIMD2<Float>
        let popAt: Double
        let flyAt: Double
        /// Where it ends up under the big rug, rug-local.
        let target: SIMD2<Float>
        var entry = SIMD2<Float>.zero
        var arrived = false

        init(name: String, image: NSImage, home: SIMD2<Float>, popAt: Double, flyAt: Double, target: SIMD2<Float>) {
            self.name = name
            self.image = image
            self.home = home
            self.popAt = popAt
            self.flyAt = flyAt
            self.target = target
        }
    }

    private final class Actor {
        let sim: ClothSimulation
        var style: RugStyle
        let bornAt: Double
        var landed = false

        init(sim: ClothSimulation, style: RugStyle, bornAt: Double) {
            self.sim = sim
            self.style = style
            self.bornAt = bornAt
        }
    }

    private struct Puff {
        var p: SIMD2<Float>
        var v: SIMD2<Float>
        var r: Float
        var t0: Double
    }

    private static let flight = 0.42
    private static let crawl = 0.36

    // MARK: - Render

    static func render(to url: URL) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? RugRenderer(device: device) else {
            print("No Metal device or shader error")
            return
        }
        for style in RugStyle.all {
            if let texture = TextureFactory.rugTexture(device: device, queue: renderer.queue, style: style) {
                renderer.setTexture(texture, for: style)
            }
        }
        guard let wallpaper = makeWallpaper(), let appIcon = makeAppIcon() else { return }

        let icons = makeDesktop()
        var actors: [Actor] = []
        var big: Actor?
        var impacts: [(t: Double, amp: Float)] = []
        var puffs: [Puff] = []
        var rng = SplitMix64(seed: 7)

        let cycle = ["isfahan", "kashan", "nain", "heriz", "qashqai", "shiraz", "fuchsia", "electric", "bazaar", "tabriz"]
        let swaps: [Double] = [6.35, 6.6, 6.82, 7.02, 7.2, 7.36, 7.5, 7.63, 7.76, 7.95]
        let extraRugs: [(t: Double, center: SIMD2<Float>, angle: Float, style: String)] = [
            (8.05, SIMD2(1075, 600), 0.2, "qashqai"),
            (8.4, SIMD2(1080, 230), -0.14, "shiraz"),
            (8.75, SIMD2(930, 420), 0.34, "bazaar"),
        ]

        let frameCount = Int(duration * fps)
        var frames: [CGImage] = []
        let start = CACurrentMediaTime()
        for frame in 0..<frameCount {
            let t = Double(frame) / fps
            func at(_ s: Double) -> Bool { frame == Int((s * fps).rounded()) }

            // The big rug slams down from high up (perspective makes it huge at first).
            if at(1.3) {
                let a = Actor(sim: ClothSimulation(width: 750, height: 500, center: SIMD2(470, 410), angle: -0.04, dropHeight: 380),
                              style: RugStyle.named("tabriz"), bornAt: t)
                actors.append(a)
                big = a
            }
            for (i, swap) in swaps.enumerated() where at(swap) {
                big?.style = RugStyle.named(cycle[i])
                big?.sim.shake()
                impacts.append((t, i == swaps.count - 1 ? 9 : 3))
            }
            for extra in extraRugs where at(extra.t) {
                actors.append(Actor(sim: ClothSimulation(width: 420, height: 280, center: extra.center, angle: extra.angle, dropHeight: 330),
                                    style: RugStyle.named(extra.style), bornAt: t))
            }
            if at(9.5), let a = big { a.sim.toggleFold(atLocalX: -20) }

            // Files: fly to the rug's edge, then crawl under it as a lump.
            if let a = big {
                let edgeX = a.sim.width / 2 - 8
                for icon in icons {
                    if at(icon.flyAt + flight) {
                        icon.entry = SIMD2(edgeX, icon.target.y)
                        a.sim.bumps.append(RugBump(id: icon.id, center: icon.entry, radius: 44, height: 17, scale: 0.4, target: 1))
                        a.sim.ripple(atLocal: icon.entry, strength: 1.1, radius: 90)
                    }
                    let k = (t - icon.flyAt - flight) / crawl
                    if k >= 0 && k <= 1, let i = a.sim.bumps.firstIndex(where: { $0.id == icon.id }) {
                        let e = Float(easeInOut(k))
                        a.sim.bumps[i].center = icon.entry + (icon.target - icon.entry) * e
                    }
                    if k > 1 && !icon.arrived {
                        icon.arrived = true
                        a.sim.ripple(atLocal: icon.target, strength: 0.6, radius: 60)
                    }
                }
            }

            // Three 60 Hz steps per frame keep the cloth as stable as in the app.
            for _ in 0..<Int((60 / fps).rounded()) {
                for actor in actors { actor.sim.update(dt: 1.0 / 60) }
            }
            for actor in actors where !actor.landed && t - actor.bornAt > 0.2 {
                if (actor.sim.positions.map(\.z).max() ?? 0) < 26 {
                    actor.landed = true
                    impacts.append((t, actor === big ? 16 : 10))
                    puffs += dust(around: actor.sim, at: t, rng: &rng)
                }
            }
            puffs.removeAll { t - $0.t0 > 0.7 }

            // Camera: push in on the lumps, pull back for the pile, push in again for the reveal.
            let cam = camera(at: t)
            let viewSize = canvas / cam.zoom
            var shake = SIMD2<Float>.zero
            for impact in impacts where t >= impact.t {
                let dt = Float(t - impact.t)
                let falloff = impact.amp * exp(-dt * 11)
                shake += SIMD2(sin(dt * 95), cos(dt * 83)) * falloff
            }
            let viewOrigin = cam.center - viewSize / 2 + shake

            var scenes: [RugScene] = []
            for actor in actors {
                guard let texture = renderer.loadedTexture(for: actor.style) else { continue }
                var hidden: [IconPlacement] = []
                if actor === big {
                    hidden = icons.filter(\.arrived).map { icon in
                        IconPlacement(id: icon.id, center: actor.sim.toWorld(icon.target)) {
                            TextureFactory.iconImage(icon: icon.image, name: icon.name)
                        }
                    }
                }
                scenes.append(RugScene(sim: actor.sim, icons: hidden, texture: texture))
            }
            guard let rugs = Offscreen.render(scenes, renderer: renderer, size: canvas, scale: 1,
                                              viewOrigin: viewOrigin, viewSize: viewSize) else { continue }

            let arrivedCount = icons.filter(\.arrived).count
            let styleName = swapStyleName(at: t, swaps: swaps, cycle: cycle)
            if let image = compose(t: t, wallpaper: wallpaper, appIcon: appIcon, icons: icons, big: big, rugs: rugs, puffs: puffs,
                                   viewOrigin: viewOrigin, zoom: cam.zoom, arrived: arrivedCount, styleName: styleName) {
                frames.append(image)
            }
        }
        print(String(format: "rendered %d frames in %.1f s", frames.count, CACurrentMediaTime() - start))
        writeGIF(frames, to: url)
    }

    // MARK: - Choreography

    /// A messy desktop: three columns of files on the right, popping in one by one.
    private static func makeDesktop() -> [FileIcon] {
        let files: [(String, UTType)] = [
            ("final_FINAL.pdf", .pdf), ("Screenshot 09.41.png", .png), ("taxes-2025.zip", .zip),
            ("IMG_4821.jpg", .jpeg), ("untitled folder", .folder), ("budget.xlsx", UTType(filenameExtension: "xlsx") ?? .data),
            ("notes.txt", .plainText), ("pitch-v7.key", UTType(filenameExtension: "key") ?? .data), ("Screenshot 09.42.png", .png),
            ("recording.mov", .quickTimeMovie), ("logo-new-new.psd", UTType(filenameExtension: "psd") ?? .image), ("Installer.dmg", .diskImage),
            ("todo.txt", .plainText), ("untitled folder 2", .folder), ("meme.gif", .gif),
            ("invoice_v3.pdf", .pdf), ("old stuff", .folder), ("song.mp3", .mp3),
        ]
        return files.enumerated().map { i, file in
            let col = i / 6, row = i % 6
            let home = SIMD2<Float>(1200 - Float(col) * 112, 700 - Float(row) * 112)
            // R2 sequence over the left part of the rug, so the reveal shows the whole pile.
            let u = (0.5 + Float(i) * 0.754_877_7).truncatingRemainder(dividingBy: 1)
            let v = (0.5 + Float(i) * 0.569_840_3).truncatingRemainder(dividingBy: 1)
            let target = SIMD2<Float>(-305 + u * 250, -170 + v * 340)
            return FileIcon(name: file.0, image: NSWorkspace.shared.icon(for: file.1), home: home,
                            popAt: 0.05 + Double(i) * 0.045, flyAt: 2.85 + Double(i) * 0.09, target: target)
        }
    }

    private static func camera(at t: Double) -> (center: SIMD2<Float>, zoom: Float) {
        let wide = (SIMD2<Float>(640, 400), Float(1))
        let lumps = (SIMD2<Float>(470, 420), Float(1.14))
        let reveal = (SIMD2<Float>(330, 420), Float(1.2))
        let keys: [(Double, (SIMD2<Float>, Float))] = [
            (0, wide), (5.15, wide), (5.95, lumps), (7.95, lumps), (8.35, wide), (9.45, wide), (10.2, reveal), (12.6, reveal),
        ]
        for i in 0..<(keys.count - 1) where t >= keys[i].0 && t <= keys[i + 1].0 {
            let k = Float(easeInOut((t - keys[i].0) / max(keys[i + 1].0 - keys[i].0, 0.001)))
            let a = keys[i].1, b = keys[i + 1].1
            return (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k)
        }
        return reveal
    }

    private static func swapStyleName(at t: Double, swaps: [Double], cycle: [String]) -> String {
        var name = RugStyle.named("tabriz").name
        for (i, s) in swaps.enumerated() where t >= s { name = RugStyle.named(cycle[i]).name }
        return name
    }

    private static func dust(around sim: ClothSimulation, at t: Double, rng: inout SplitMix64) -> [Puff] {
        (0..<34).map { _ in
            let side = Int(rng.unit() * 4)
            let u = Float(rng.range(-0.5, 0.5))
            var local: SIMD2<Float>
            var out: SIMD2<Float>
            switch side {
            case 0: local = SIMD2(u * sim.width, -sim.height / 2); out = SIMD2(0, -1)
            case 1: local = SIMD2(u * sim.width, sim.height / 2); out = SIMD2(0, 1)
            case 2: local = SIMD2(-sim.width / 2, u * sim.height); out = SIMD2(-1, 0)
            default: local = SIMD2(sim.width / 2, u * sim.height); out = SIMD2(1, 0)
            }
            let speed = Float(rng.range(70, 220))
            let dir = rotate(out + SIMD2(Float(rng.range(-0.5, 0.5)), Float(rng.range(-0.5, 0.5))), sim.angle)
            return Puff(p: sim.toWorld(local), v: dir * speed, r: Float(rng.range(3, 9)), t0: t)
        }
    }

    // MARK: - Compositing

    private static func compose(t: Double, wallpaper: CGImage, appIcon: CGImage, icons: [FileIcon], big: Actor?, rugs: CGImage,
                                puffs: [Puff], viewOrigin: SIMD2<Float>, zoom: Float, arrived: Int, styleName: String) -> CGImage? {
        let W = Int(canvas.x), H = Int(canvas.y)
        return TextureFactory.bitmap(width: W, height: H) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

            // World layer under the rugs: wallpaper and the files still on the desktop.
            ctx.saveGState()
            ctx.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
            ctx.translateBy(x: CGFloat(-viewOrigin.x), y: CGFloat(-viewOrigin.y))
            ctx.draw(wallpaper, in: CGRect(x: -240, y: -240, width: 1760, height: 1280))
            for icon in icons where t >= icon.popAt && t < icon.flyAt {
                let k = (t - icon.popAt) / 0.28
                let s = k >= 1 ? 1 : CGFloat(easeOutBack(min(1, k)))
                drawIcon(icon.image, name: icon.name, at: icon.home, scale: s, rotation: 0, alpha: CGFloat(min(1, k * 4)))
            }
            ctx.restoreGState()

            ctx.draw(rugs, in: CGRect(x: 0, y: 0, width: W, height: H))

            // World layer above the rugs: files in flight and dust.
            ctx.saveGState()
            ctx.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
            ctx.translateBy(x: CGFloat(-viewOrigin.x), y: CGFloat(-viewOrigin.y))
            if let big {
                for icon in icons where t >= icon.flyAt && t < icon.flyAt + flight {
                    let k = (t - icon.flyAt) / flight
                    let e = Float(easeIn(k))
                    let to = big.sim.toWorld(SIMD2(big.sim.width / 2 + 30, icon.target.y))
                    var p = icon.home + (to - icon.home) * e
                    p.y += Float(sin(k * .pi)) * 90
                    drawIcon(icon.image, name: nil, at: p, scale: CGFloat(1 - 0.35 * k), rotation: CGFloat(k * 1.2), alpha: 1)
                }
            }
            for puff in puffs {
                let k = Float(t - puff.t0) / 0.7
                let p = puff.p + puff.v * Float(t - puff.t0) * (1 - k * 0.5)
                let r = CGFloat(puff.r * (1 + k * 2.2))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.96, blue: 0.88, alpha: CGFloat(0.55 * (1 - k))))
                ctx.fillEllipse(in: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: r * 2, height: r * 2))
            }
            ctx.restoreGState()

            drawTitles(t: t, arrived: arrived, styleName: styleName, ctx: ctx)
            drawEndCard(t: t, appIcon: appIcon, ctx: ctx)
            NSGraphicsContext.restoreGraphicsState()
        }?.makeImage()
    }

    // MARK: - Kinetic type

    /// One sticker line: slams in with an overshoot, holds, snaps out.
    private struct Line {
        let text: String
        let size: CGFloat
        let fill: NSColor
        let ink: NSColor
        let center: CGPoint
        let rotation: CGFloat
        let t0: Double
        let t1: Double
    }

    private static func drawTitles(t: Double, arrived: Int, styleName: String, ctx: CGContext) {
        var lines: [Line] = [
            Line(text: "YOUR DESKTOP", size: 74, fill: .white, ink: ink, center: CGPoint(x: 470, y: 470), rotation: -0.04, t0: 0.15, t1: 1.3),
            Line(text: "IS A MESS.", size: 92, fill: crimson, ink: .white, center: CGPoint(x: 490, y: 360), rotation: 0.03, t0: 0.4, t1: 1.3),

            Line(text: "MEET YOUR", size: 58, fill: .white, ink: ink, center: CGPoint(x: 470, y: 470), rotation: -0.03, t0: 1.9, t1: 2.8),
            Line(text: "NEW RUG.", size: 96, fill: saffron, ink: ink, center: CGPoint(x: 480, y: 365), rotation: 0.025, t0: 2.0, t1: 2.8),

            Line(text: "SHOVE IT ALL", size: 64, fill: .white, ink: ink, center: CGPoint(x: 470, y: 720), rotation: -0.02, t0: 2.85, t1: 5.15),
            Line(text: "UNDER THE RUG.", size: 64, fill: fuchsia, ink: .white, center: CGPoint(x: 480, y: 635), rotation: 0.02, t0: 2.95, t1: 5.15),

            Line(text: "AH.", size: 150, fill: mint, ink: ink, center: CGPoint(x: 640, y: 470), rotation: -0.05, t0: 5.2, t1: 6.15),
            Line(text: "MUCH BETTER.", size: 56, fill: .white, ink: ink, center: CGPoint(x: 650, y: 330), rotation: 0.03, t0: 5.35, t1: 6.15),

            Line(text: "10 STYLES", size: 104, fill: saffron, ink: ink, center: CGPoint(x: 640, y: 700), rotation: -0.03, t0: 6.2, t1: 7.95),

            Line(text: "STACK 'EM.", size: 100, fill: crimson, ink: .white, center: CGPoint(x: 420, y: 700), rotation: -0.035, t0: 8.05, t1: 9.4),

            Line(text: "LIFT IT.", size: 96, fill: mint, ink: ink, center: CGPoint(x: 870, y: 610), rotation: 0.03, t0: 9.55, t1: 10.95),
            Line(text: "IT'S ALL STILL THERE.", size: 46, fill: .white, ink: ink, center: CGPoint(x: 880, y: 500), rotation: -0.02, t0: 9.75, t1: 10.95),
        ]
        if t >= 3.3 && t < 5.15 {
            lines.append(Line(text: arrived == 1 ? "1 FILE GONE" : "\(arrived) FILES GONE", size: 40, fill: ink, ink: saffron, center: CGPoint(x: 1040, y: 110),
                              rotation: 0.04, t0: 3.3, t1: 5.15))
        }
        if t >= 6.3 && t < 7.95 {
            lines.append(Line(text: styleName.uppercased(), size: 40, fill: ink, ink: .white, center: CGPoint(x: 640, y: 600),
                              rotation: 0.02, t0: 6.3, t1: 7.95))
        }
        for line in lines where t >= line.t0 && t < line.t1 {
            let kIn = min(1, (t - line.t0) / 0.24)
            var scale = 1.7 - 0.7 * CGFloat(easeOutBack(kIn))
            var alpha = CGFloat(min(1, kIn * 4))
            let kOut = (line.t1 - t) / 0.14
            if kOut < 1 {
                alpha *= CGFloat(max(0, kOut))
                scale *= 0.85 + 0.15 * CGFloat(max(0, kOut))
            }
            sticker(line, scale: scale, alpha: alpha, ctx: ctx)
        }
    }

    private static func sticker(_ line: Line, scale: CGFloat, alpha: CGFloat, ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: line.size, weight: .black)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: line.ink, .kern: -line.size * 0.03]
        let size = (line.text as NSString).size(withAttributes: attributes)
        let padX = line.size * 0.28, padY = line.size * 0.1
        let box = CGRect(x: -size.width / 2 - padX, y: -size.height / 2 - padY, width: size.width + padX * 2, height: size.height + padY * 2)

        ctx.saveGState()
        ctx.translateBy(x: line.center.x, y: line.center.y)
        ctx.rotate(by: line.rotation)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // Hard offset shadow: flat, graphic, poster-like.
        ctx.addPath(CGPath(roundedRect: box.offsetBy(dx: 7, dy: -7), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(line.fill.cgColor)
        ctx.fillPath()
        (line.text as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawEndCard(t: Double, appIcon: CGImage, ctx: CGContext) {
        let t0 = 11.0
        guard t >= t0 else { return }
        let W = CGFloat(canvas.x), H = CGFloat(canvas.y)
        let k = min(1, (t - t0) / 0.3)
        ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.04, blue: 0.11, alpha: CGFloat(0.86 * k)))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        let iconK = min(1, max(0, (t - t0 - 0.1) / 0.35))
        let s = CGFloat(easeOutBack(iconK)) * 230
        if s > 1 {
            ctx.saveGState()
            ctx.translateBy(x: W / 2, y: 520)
            ctx.rotate(by: CGFloat((1 - iconK) * -0.5))
            ctx.draw(appIcon, in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
            ctx.restoreGState()
        }
        let title = Line(text: "UNDER THE RUG", size: 92, fill: saffron, ink: ink, center: CGPoint(x: W / 2, y: 330),
                         rotation: -0.02, t0: t0 + 0.3, t1: 99)
        let tag = Line(text: "A PERSIAN RUG FOR YOUR MAC DESKTOP", size: 30, fill: .white, ink: ink, center: CGPoint(x: W / 2, y: 235),
                       rotation: 0.015, t0: t0 + 0.5, t1: 99)
        let free = Line(text: "FREE  ·  macOS 13+  ·  ON GITHUB", size: 26, fill: fuchsia, ink: .white, center: CGPoint(x: W / 2, y: 160),
                        rotation: -0.01, t0: t0 + 0.7, t1: 99)
        for line in [title, tag, free] where t >= line.t0 {
            let kIn = min(1, (t - line.t0) / 0.24)
            sticker(line, scale: 1.7 - 0.7 * CGFloat(easeOutBack(kIn)), alpha: CGFloat(min(1, kIn * 4)), ctx: ctx)
        }
    }

    private static func drawIcon(_ image: NSImage, name: String?, at p: SIMD2<Float>, scale: CGFloat, rotation: CGFloat, alpha: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext, scale > 0.01 else { return }
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(p.x), y: CGFloat(p.y))
        ctx.rotate(by: rotation)
        ctx.scaleBy(x: scale, y: scale)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        image.draw(in: NSRect(x: -36, y: -12, width: 72, height: 72), from: .zero, operation: .sourceOver, fraction: alpha)
        NSGraphicsContext.restoreGraphicsState()
        if let name {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            textShadow.shadowBlurRadius = 3
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            (name as NSString).draw(in: NSRect(x: -54, y: -34, width: 108, height: 17), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                .paragraphStyle: paragraph,
                .shadow: textShadow,
            ])
        }
        ctx.restoreGState()
    }

    /// A flat, graphic wallpaper: deep indigo with two hard-edged diagonal bands, bigger than the canvas for camera
    /// moves. No gradients on purpose: GIF dithering turns them into noise that bloats every frame.
    private static func makeWallpaper() -> CGImage? {
        TextureFactory.bitmap(width: 1760, height: 1280) { ctx in
            ctx.setFillColor(RGB(0x241A52).cg())
            ctx.fill(CGRect(x: 0, y: 0, width: 1760, height: 1280))
            for (offset, width, color) in [(560.0, 380.0, RGB(0x2E2266)), (1180.0, 160.0, RGB(0x2A1F5E))] as [(CGFloat, CGFloat, RGB)] {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: offset, y: 0))
                ctx.addLine(to: CGPoint(x: offset + width, y: 0))
                ctx.addLine(to: CGPoint(x: offset + width - 700, y: 1280))
                ctx.addLine(to: CGPoint(x: offset - 700, y: 1280))
                ctx.closePath()
                ctx.setFillColor(color.cg())
                ctx.fillPath()
            }
        }?.makeImage()
    }

    private static func makeAppIcon() -> CGImage? {
        TextureFactory.bitmap(width: 512, height: 512) { ctx in
            TextureFactory.drawAppIcon(in: ctx, size: 512)
        }?.makeImage()
    }

    // MARK: - Easing

    private static func easeInOut(_ x: Double) -> Double {
        let k = max(0, min(1, x))
        return k * k * (3 - 2 * k)
    }

    private static func easeIn(_ x: Double) -> Double {
        let k = max(0, min(1, x))
        return k * k
    }

    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        let k = max(0, min(1, x)) - 1
        return 1 + c3 * k * k * k + c1 * k * k
    }

    // MARK: - GIF

    /// Scales every frame down to `outputWidth` and writes a looping GIF.
    private static func writeGIF(_ frames: [CGImage], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        let outW = outputWidth, outH = Int(Double(outputWidth) * Double(canvas.y) / Double(canvas.x))
        for frame in frames {
            guard let small = TextureFactory.bitmap(width: outW, height: outH, draw: { ctx in
                ctx.interpolationQuality = .high
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            })?.makeImage() else { continue }
            CGImageDestinationAddImage(dest, small, frameProperties)
        }
        CGImageDestinationFinalize(dest)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print(String(format: "wrote %@ (%.1f MB)", url.path, Double(bytes) / 1_000_000))
    }
}
