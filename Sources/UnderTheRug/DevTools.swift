import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

/// Command-line helpers for the build script and for checking the rendering without a screen:
///
///     UnderTheRug --export-iconset <dir.iconset>
///     UnderTheRug --export-textures <dir>
///     UnderTheRug --snapshot <file.png> [--style id] [--fold] [--grab] [--frames n]
enum DevTools {
    static func handle(_ args: [String]) -> Bool {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let dir = value(after: "--export-iconset") {
            exportIconset(to: URL(fileURLWithPath: dir))
            return true
        }
        if let dir = value(after: "--export-textures") {
            exportTextures(to: URL(fileURLWithPath: dir))
            return true
        }
        if let file = value(after: "--snapshot") {
            snapshot(to: URL(fileURLWithPath: file), styleID: value(after: "--style") ?? "tabriz",
                     fold: args.contains("--fold"), grab: args.contains("--grab"),
                     frames: Int(value(after: "--frames") ?? "") ?? 150)
            return true
        }
        return false
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func exportIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            guard let image = TextureFactory.bitmap(width: px, height: px, draw: { ctx in
                TextureFactory.drawAppIcon(in: ctx, size: CGFloat(px))
            })?.makeImage() else { continue }
            writePNG(image, to: dir.appendingPathComponent("\(name).png"))
        }
    }

    private static func exportTextures(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for style in RugStyle.all {
            if let image = TextureFactory.rugImage(style: style, width: 1200, height: 800) {
                writePNG(image, to: dir.appendingPathComponent("rug-\(style.id).png"))
            }
        }
        if let floor = TextureFactory.floorImage() {
            writePNG(floor, to: dir.appendingPathComponent("floor.png"))
        }
    }

    /// Simulates a rug with a few things under it and renders one frame to a PNG, offscreen.
    private static func snapshot(to url: URL, styleID: String, fold: Bool, grab: Bool, frames: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? RugRenderer(device: device) else {
            print("No Metal device or shader error")
            return
        }
        let size = SIMD2<Float>(1000, 700)
        let scale = 2
        renderer.rugTexture = TextureFactory.rugTexture(device: device, queue: renderer.queue, style: RugStyle.named(styleID))
        renderer.floorTexture = TextureFactory.floorTexture(device: device, queue: renderer.queue)

        let sim = ClothSimulation(width: 570, height: 380, center: size / 2, angle: -0.06, dropHeight: 0)
        let things: [(String, SIMD2<Float>)] = [
            ("/System/Applications/Notes.app", SIMD2(-0.3, 0.15)),
            ("/System/Applications/Calculator.app", SIMD2(-0.25, -0.2)),
            ("/etc/hosts", SIMD2(0.1, 0.05)),
            ("/Library", SIMD2(0.28, -0.18)),
        ]
        sim.bumps = things.enumerated().map { i, t in
            RugBump(id: UUID(), center: SIMD2(t.1.x * sim.width, t.1.y * sim.height), radius: 34, height: 13 + Float(i) * 1.5, scale: 1, target: 1)
        }
        let start = CACurrentMediaTime()
        var settledAt: Int?
        for f in 0..<frames {
            sim.update(dt: 1.0 / 60)
            if settledAt == nil && sim.isSettled { settledAt = f }
            if f % 30 == 0, ProcessInfo.processInfo.environment["RUG_DEBUG"] != nil { print("flat", f, sim.lastMaxMove) }
        }
        if fold {
            sim.toggleFold(atLocalX: -sim.width * 0.12)
            for f in 0..<120 { sim.update(dt: 1.0 / 60); if f % 10 == 0, ProcessInfo.processInfo.environment["RUG_DEBUG"] != nil { print(f, sim.center, sim.angle, sim.foldDistance, sim.positions.map(\.z).max()!, sim.lastMaxMove, sim.debugWorstParticle()) } }
        }
        if grab {
            let corner = sim.toWorld(SIMD2(sim.width * 0.48, sim.height * 0.46))
            sim.grab(atWorld: corner)
            for f in 0..<40 {
                sim.drag(toWorld: corner + SIMD2(Float(f) * 3, Float(f) * 1.5))
                sim.update(dt: 1.0 / 60)
            }
        }
        if ProcessInfo.processInfo.environment["RUG_THROW"] != nil {
            // Fling the rug hard to the right, let go, then bring it back the way the app does.
            let p0 = sim.toWorld(SIMD2(sim.width * 0.4, 0))
            sim.grab(atWorld: p0)
            for f in 0..<6 {
                sim.drag(toWorld: p0 + SIMD2(Float(f) * 120, 0))
                sim.update(dt: 1.0 / 60)
            }
            sim.release()
            for _ in 0..<120 { sim.update(dt: 1.0 / 60) }
            print("after throw centre \(sim.center)")
            sim.moveFrame(to: size / 2, angle: -0.035)
            var frames = 0
            while sim.isMovingFrame && frames < 600 {
                sim.update(dt: 1.0 / 60)
                frames += 1
            }
            print("back at \(sim.center) after \(frames) frames")
        }
        let simTime = (CACurrentMediaTime() - start) * 1000
        print(String(format: "simulated in %.0f ms; settled at frame %@", simTime, settledAt.map(String.init) ?? "never"))
        let zs = sim.positions.map(\.z)
        print("max z \(zs.max() ?? 0), NaNs \(zs.filter(\.isNaN).count), centre \(sim.center), angle \(sim.angle), fold \(sim.foldSide) \(sim.foldDistance)")

        let icons = things.enumerated().map { _, t in
            IconPlacement(id: UUID(), center: sim.toWorld(SIMD2(t.1.x * sim.width, t.1.y * sim.height))) {
                TextureFactory.iconImage(path: t.0, name: (t.0 as NSString).lastPathComponent)
            }
        }
        let scene = RugScene(sim: sim, icons: icons, floorCorners: sim.floorCorners(fringe: Float(RugPattern.fringeFraction)), viewSize: size)

        let w = Int(size.x) * scale, h = Int(size.y) * scale
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RugRenderer.colorFormat, width: w, height: h, mipmapped: false)
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .managed
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RugRenderer.depthFormat, width: w, height: h, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc), let depth = device.makeTexture(descriptor: depthDesc) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.27, blue: 0.36, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depth
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare

        guard let cb = renderer.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        renderer.encode(scene, into: enc)
        enc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: color)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        color.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info),
              let image = ctx.makeImage() else { return }
        writePNG(image, to: url)
        print("wrote \(url.path)")
    }
}
