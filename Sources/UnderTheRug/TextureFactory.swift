import AppKit
import Metal

/// Turns the procedural artwork and file icons into images and Metal textures.
enum TextureFactory {
    static let rugTextureSize = (width: 2048, height: 1365)

    /// An RGBA, premultiplied, sRGB bitmap of `width` x `height` pixels with `draw` applied.
    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        return ctx
    }

    static func rugImage(style: RugStyle, width: Int, height: Int) -> CGImage? {
        bitmap(width: width, height: height) { ctx in
            RugPattern.draw(style, in: ctx, width: CGFloat(width), height: CGFloat(height))
        }?.makeImage()
    }

    static func floorImage(width: Int = 1024, height: Int = 683) -> CGImage? {
        bitmap(width: width, height: height) { ctx in
            RugPattern.drawFloor(in: ctx, width: CGFloat(width), height: CGFloat(height))
        }?.makeImage()
    }

    static func rugTexture(device: MTLDevice, queue: MTLCommandQueue, style: RugStyle) -> MTLTexture? {
        let size = rugTextureSize
        guard let ctx = bitmap(width: size.width, height: size.height, draw: { ctx in
            RugPattern.draw(style, in: ctx, width: CGFloat(size.width), height: CGFloat(size.height))
        }) else { return nil }
        return texture(from: ctx, device: device, queue: queue, mipmapped: true)
    }

    static func texture(from image: CGImage, device: MTLDevice, queue: MTLCommandQueue, mipmapped: Bool) -> MTLTexture? {
        guard let ctx = bitmap(width: image.width, height: image.height, draw: { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }) else { return nil }
        return texture(from: ctx, device: device, queue: queue, mipmapped: mipmapped)
    }

    /// Uploads the bitmap's premultiplied RGBA bytes; row 0 in memory is the top of the image, as Metal expects.
    static func texture(from ctx: CGContext, device: MTLDevice, queue: MTLCommandQueue, mipmapped: Bool) -> MTLTexture? {
        guard let data = ctx.data else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: ctx.width, height: ctx.height, mipmapped: mipmapped)
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, ctx.width, ctx.height), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        if mipmapped, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return tex
    }

    /// A Finder-style icon with its name underneath, at 2x for Retina.
    static func iconImage(path: String, name: String) -> CGImage? {
        iconImage(icon: NSWorkspace.shared.icon(forFile: path), name: name)
    }

    static func iconImage(icon: NSImage, name: String) -> CGImage? {
        let scale: CGFloat = 2
        let size = RugRenderer.iconSize
        let w = Int(CGFloat(size.x) * scale), h = Int(CGFloat(size.y) * scale)
        return bitmap(width: w, height: h) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

            let iconShadow = NSShadow()
            iconShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            iconShadow.shadowBlurRadius = 4
            iconShadow.shadowOffset = NSSize(width: 0, height: -2)
            iconShadow.set()
            icon.draw(in: NSRect(x: 24, y: 38, width: 64, height: 64))

            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            textShadow.shadowBlurRadius = 3
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
                .shadow: textShadow,
            ]
            (name as NSString).draw(in: NSRect(x: 4, y: 16, width: CGFloat(size.x) - 8, height: 16), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }?.makeImage()
    }

    /// The app icon: a rug on a wooden tile.
    static func drawAppIcon(in ctx: CGContext, size S: CGFloat) {
        let tile = CGRect(x: S * 0.1, y: S * 0.1, width: S * 0.8, height: S * 0.8)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: S * 0.18, cornerHeight: S * 0.18, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(tilePath)
        ctx.setFillColor(RGB(0x6A4529).cg())
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        if let floor = floorImage(width: max(32, Int(tile.width)), height: max(32, Int(tile.height))) {
            ctx.draw(floor, in: tile)
        }
        ctx.restoreGState()

        if let rug = rugImage(style: RugStyle.all[0], width: max(48, Int(S * 0.72)), height: max(32, Int(S * 0.48))) {
            ctx.saveGState()
            ctx.translateBy(x: S / 2, y: S / 2)
            ctx.rotate(by: 0.22)
            ctx.setShadow(offset: CGSize(width: S * 0.012, height: -S * 0.02), blur: S * 0.03, color: CGColor(gray: 0, alpha: 0.55))
            ctx.draw(rug, in: CGRect(x: -S * 0.36, y: -S * 0.24, width: S * 0.72, height: S * 0.48))
            ctx.restoreGState()
        }
    }
}
