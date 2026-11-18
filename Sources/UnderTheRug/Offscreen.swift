import AppKit
import Metal
import simd

/// Renders rug scenes into an image without a window, for snapshots and the launch GIF.
enum Offscreen {
    /// `size` is the image in points; `viewOrigin`/`viewSize` pick the part of world space it shows (a camera).
    static func render(_ scenes: [RugScene], renderer: RugRenderer, size: SIMD2<Float>, scale: Int,
                       viewOrigin: SIMD2<Float> = .zero, viewSize: SIMD2<Float>? = nil,
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
        renderer.encode(scenes, viewOrigin: viewOrigin, viewSize: viewSize ?? size, into: enc)
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
