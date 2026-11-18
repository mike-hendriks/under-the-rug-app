import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

/// Renders rug scenes into an image without a window, for snapshots and the launch GIF.
enum Offscreen {
    static func render(_ scenes: [RugScene], renderer: RugRenderer, size: SIMD2<Float>, scale: Int,
                       clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) -> CGImage? {
        let device = renderer.device
        let w = Int(size.x) * scale, h = Int(size.y) * scale
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RugRenderer.colorFormat, width: w, height: h, mipmapped: false)
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .managed
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RugRenderer.depthFormat, width: w, height: h, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc), let depth = device.makeTexture(descriptor: depthDesc) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        pass.depthAttachment.texture = depth
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depth
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare

        guard let cb = renderer.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        renderer.encode(scenes, viewOrigin: .zero, viewSize: size, into: enc)
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
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)
        else { return nil }
        return ctx.makeImage()
    }
}

/// The launch GIF in the README, scripted frame by frame with the real cloth and renderer:
/// a rug drops in, a file gets shoved under it, a second rug arrives and changes styles,
/// the first rug is pulled around and finally lifted to show what is hiding underneath.
///
///     UnderTheRug --demo docs/demo.gif
enum LaunchDemo {
    private static let canvas = SIMD2<Float>(1280, 800)
    private static let outputWidth = 720
    private static let fps: Double = 15
    private static let duration: Double = 10

    private struct Tween {
        var from: SIMD2<Float>, to: SIMD2<Float>, t0: Double, t1: Double
    }

    private struct DesktopIcon {
        let name: String
        let icon: NSImage
        let center: SIMD2<Float>
    }

    static func render(to url: URL) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? RugRenderer(device: device) else {
            print("No Metal device or shader error")
            return
        }
        let styles = ["tabriz", "shiraz", "bazaar", "fuchsia"].map(RugStyle.named)
        for style in styles {
            if let texture = TextureFactory.rugTexture(device: device, queue: renderer.queue, style: style) {
                renderer.setTexture(texture, for: style)
            }
        }
        guard let wallpaper = makeWallpaper() else { return }

        let desktop = [
            DesktopIcon(name: "invoice_final_v3.pdf", icon: NSWorkspace.shared.icon(for: .pdf), center: SIMD2(1190, 650)),
            DesktopIcon(name: "Screenshot 09.41.png", icon: NSWorkspace.shared.icon(for: .png), center: SIMD2(1190, 530)),
            DesktopIcon(name: "untitled folder", icon: NSWorkspace.shared.icon(for: .folder), center: SIMD2(1190, 410)),
        ]
        let shoved = desktop[0]
        let invoiceID = UUID()

        // Rug A lies left of centre, rug B arrives later on the right.
        let rugA = ClothSimulation(width: 570, height: 380, center: SIMD2(470, 420), angle: -0.05, dropHeight: 170)
        var rugB: ClothSimulation?
        var styleB = styles[1]
        var aOnTop = false
        var invoiceUnderRug = false
        var invoiceLocal = SIMD2<Float>.zero

        var cursor = SIMD2<Float>(1000, 120)
        var tween: Tween?
        var clicks: [(SIMD2<Float>, Double)] = []
        var carrying = false

        func move(to target: SIMD2<Float>, at t: Double, over seconds: Double) {
            tween = Tween(from: cursor, to: target, t0: t, t1: t + seconds)
        }

        let frameCount = Int(duration * fps)
        var frames: [CGImage] = []
        let start = CACurrentMediaTime()
        for frame in 0..<frameCount {
            let t = Double(frame) / fps
            func at(_ s: Double) -> Bool { frame == Int((s * fps).rounded()) }

            // The script.
            if at(1.2) { move(to: shoved.center + SIMD2(4, 18), at: t, over: 0.6) }
            if at(1.85) { clicks.append((cursor, t)); carrying = true }
            if at(1.95) { move(to: SIMD2(330, 450), at: t, over: 1.0) }
            if at(3.0) {
                carrying = false
                invoiceUnderRug = true
                invoiceLocal = rugA.toLocal(SIMD2(330, 450))
                rugA.bumps.append(RugBump(id: invoiceID, center: invoiceLocal, radius: 34, height: 16, scale: 0, target: 1))
                rugA.hoverPoint = nil
                rugA.ripple(atLocal: invoiceLocal, strength: 1.6)
            }
            if at(3.1) { move(to: SIMD2(820, 140), at: t, over: 0.7) }
            if at(3.5) { rugB = ClothSimulation(width: 420, height: 280, center: SIMD2(860, 300), angle: 0.18, dropHeight: 170) }
            if at(4.6) { styleB = styles[2]; rugB?.shake() }
            if at(5.3) { styleB = styles[3]; rugB?.shake() }
            if at(5.6) { move(to: rugA.toWorld(SIMD2(-250, 120)), at: t, over: 0.5) }
            if at(6.15) {
                clicks.append((cursor, t))
                aOnTop = true
                rugA.grab(atWorld: cursor)
                move(to: cursor + SIMD2(-70, 70), at: t, over: 0.8)
            }
            if at(7.0) { rugA.release() }
            if at(7.1) { move(to: rugA.toWorld(SIMD2(-10, 40)), at: t, over: 0.4) }
            if at(7.55) {
                clicks.append((cursor, t))
                clicks.append((cursor, t + 0.12))
                rugA.toggleFold(atLocalX: rugA.toLocal(cursor).x)
            }
            if at(8.0) { move(to: SIMD2(760, 160), at: t, over: 0.8) }

            if let tw = tween {
                let k = Float(max(0, min(1, (t - tw.t0) / (tw.t1 - tw.t0))))
                let e = k * k * (3 - 2 * k)
                cursor = tw.from + (tw.to - tw.from) * e
            }
            if carrying {
                let l = rugA.toLocal(cursor)
                let over = abs(l.x) < rugA.width / 2 && abs(l.y) < rugA.height / 2
                rugA.hoverPoint = over ? l : nil
            }
            if rugA.isGrabbing { rugA.drag(toWorld: cursor) }

            // Three 60 Hz steps per 20 fps frame keep the cloth as stable as in the app.
            let steps = Int((60 / fps).rounded())
            for _ in 0..<steps {
                rugA.update(dt: 1.0 / 60)
                rugB?.update(dt: 1.0 / 60)
            }

            var scenes: [RugScene] = []
            let icons = invoiceUnderRug ? [IconPlacement(id: invoiceID, center: rugA.toWorld(invoiceLocal)) {
                TextureFactory.iconImage(icon: shoved.icon, name: shoved.name)
            }] : []
            if let a = renderer.loadedTexture(for: styles[0]) {
                scenes.append(RugScene(sim: rugA, icons: icons, texture: a))
            }
            if let b = rugB, let tb = renderer.loadedTexture(for: styleB) {
                let sceneB = RugScene(sim: b, icons: [], texture: tb)
                if aOnTop { scenes.insert(sceneB, at: 0) } else { scenes.append(sceneB) }
            }
            guard let rugs = Offscreen.render(scenes, renderer: renderer, size: canvas, scale: 1) else { continue }

            let fadeOut = Float(max(0, min(1, (duration - t) / 0.4)))
            let hidden: Set<String> = (carrying || invoiceUnderRug) ? [shoved.name] : []
            if let image = compose(wallpaper: wallpaper, desktop: desktop, hiding: hidden, rugs: rugs, fade: fadeOut,
                                   carried: carrying ? shoved : nil, cursor: cursor, clicks: clicks, t: t) {
                frames.append(image)
            }
        }
        print(String(format: "rendered %d frames in %.1f s", frames.count, CACurrentMediaTime() - start))
        writeGIF(frames, to: url)
    }

    // MARK: - Compositing

    private static func caption(at t: Double) -> (title: String, alpha: CGFloat)? {
        let lines: [(Double, Double, String)] = [
            (0.0, 1.2, "Under the Rug"),
            (1.2, 3.4, "Shove your files under it"),
            (3.4, 5.6, "Add more rugs, ten colourful styles"),
            (5.6, 7.4, "Heavy wool, real cloth physics"),
            (7.4, 10.0, "Lift it to find them again"),
        ]
        for (a, b, text) in lines where t >= a && t < b {
            let fade = min(1, min(t - a, b - t) / 0.2)
            return (text, CGFloat(max(0, fade)))
        }
        return nil
    }

    private static func compose(wallpaper: CGImage, desktop: [DesktopIcon], hiding: Set<String>, rugs: CGImage, fade: Float,
                                carried: DesktopIcon?, cursor: SIMD2<Float>, clicks: [(SIMD2<Float>, Double)], t: Double) -> CGImage? {
        let W = Int(canvas.x), H = Int(canvas.y)
        return TextureFactory.bitmap(width: W, height: H) { ctx in
            ctx.draw(wallpaper, in: CGRect(x: 0, y: 0, width: W, height: H))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for icon in desktop where !hiding.contains(icon.name) {
                drawIcon(icon.icon, name: icon.name, center: icon.center, alpha: 1)
            }
            NSGraphicsContext.restoreGraphicsState()

            ctx.saveGState()
            ctx.setAlpha(CGFloat(fade))
            ctx.draw(rugs, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.restoreGState()

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            if let carried {
                drawIcon(carried.icon, name: nil, center: cursor + SIMD2(-4, -22), alpha: 0.85)
            }
            for (p, t0) in clicks where t >= t0 && t < t0 + 0.35 {
                let k = CGFloat((t - t0) / 0.35)
                let r = 8 + 18 * k
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8 * (1 - k)))
                ctx.setLineWidth(2.5)
                ctx.strokeEllipse(in: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: r * 2, height: r * 2))
            }
            drawCursor(ctx, at: cursor)
            if let line = caption(at: t) {
                drawCaption(line.title, alpha: line.alpha * CGFloat(fade))
            }
            NSGraphicsContext.restoreGraphicsState()
        }?.makeImage()
    }

    private static func drawIcon(_ icon: NSImage, name: String?, center: SIMD2<Float>, alpha: CGFloat) {
        let c = NSPoint(x: CGFloat(center.x), y: CGFloat(center.y))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        icon.draw(in: NSRect(x: c.x - 32, y: c.y - 14, width: 64, height: 64), from: .zero, operation: .sourceOver, fraction: alpha)
        NSGraphicsContext.restoreGraphicsState()
        guard let name else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        textShadow.shadowBlurRadius = 3
        textShadow.shadowOffset = NSSize(width: 0, height: -1)
        (name as NSString).draw(in: NSRect(x: c.x - 60, y: c.y - 36, width: 120, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: textShadow,
        ])
    }

    /// The classic arrow, tip at `p`.
    private static func drawCursor(_ ctx: CGContext, at p: SIMD2<Float>) {
        let pts: [CGPoint] = [(0, 0), (0, -22), (5.2, -17), (9, -25.5), (12.6, -24), (8.8, -15.6), (15.8, -15.6)]
            .map { CGPoint(x: CGFloat(p.x) + $0.0 * 1.15, y: CGFloat(p.y) + $0.1 * 1.15) }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    private static func drawCaption(_ text: String, alpha: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(x: (CGFloat(canvas.x) - size.width) / 2 - 28, y: 34, width: size.width + 56, height: size.height + 22)
        NSColor.black.withAlphaComponent(0.55 * alpha).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 28, y: box.minY + 11), withAttributes: attributes)
    }

    /// A calm slate gradient, so the rugs do the talking.
    private static func makeWallpaper() -> CGImage? {
        let W = Int(canvas.x), H = Int(canvas.y)
        return TextureFactory.bitmap(width: W, height: H) { ctx in
            let colors = [RGB(0x3B4A66).cg(), RGB(0x1F2740).cg()] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        }?.makeImage()
    }

    // MARK: - GIF

    /// Scales every frame down to `outputWidth` and writes a looping GIF.
    private static func writeGIF(_ frames: [CGImage], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
