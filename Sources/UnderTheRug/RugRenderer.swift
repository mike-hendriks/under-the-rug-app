import CoreGraphics
import Foundation
import Metal
import simd

/// Mirrors `Uniforms` in Shaders.swift; keep the field order identical (72 bytes).
struct Uniforms {
    var viewSize: SIMD2<Float>
    var viewOrigin: SIMD2<Float>
    var perspCenter: SIMD2<Float>
    var shadowBase: SIMD2<Float>
    var shadowSlope: SIMD2<Float>
    var knotGrid: SIMD2<Float>
    var perspDist: Float
    var fringe: Float
    var shadowAlpha: Float
    var aspect: Float
    var quadAlpha: Float
    /// Stacking order of the rug being drawn: higher layers win the depth test.
    var layer: Float
}

struct ClothVertex {
    var px: Float = 0, py: Float = 0, pz: Float = 0
    var nx: Float = 0, ny: Float = 0, nz: Float = 1
    var u: Float = 0, v: Float = 0
}

struct QuadVertex {
    var x: Float, y: Float, u: Float, v: Float
}

/// A hidden file's icon, lying on the desktop under its rug.
struct IconPlacement {
    let id: UUID
    let center: SIMD2<Float>
    let image: () -> CGImage?
}

/// One rug to draw, with what lies under it.
struct RugScene {
    let sim: ClothSimulation
    let icons: [IconPlacement]
    let texture: MTLTexture
}

enum RendererError: Error {
    case setup(String)
}

/// Shared by every screen. Draws the rugs bottom to top, each as: the icons hidden under it,
/// its shadow, the rug itself.
final class RugRenderer {
    static let colorFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float_stencil8
    static let iconSize = SIMD2<Float>(112, 104)

    let device: MTLDevice
    let queue: MTLCommandQueue

    private let clothPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let quadPipeline: MTLRenderPipelineState
    private let clothDepth: MTLDepthStencilState
    private let flatDepth: MTLDepthStencilState
    private let shadowDepth: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private var rugTextures: [String: MTLTexture] = [:]
    private var loadingStyles: Set<String> = []
    private var iconTextures: [UUID: MTLTexture] = [:]
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var vertices: [ClothVertex] = []

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.setup("command queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: Shaders.source, options: nil)

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = RugRenderer.colorFormat
            d.depthAttachmentPixelFormat = RugRenderer.depthFormat
            d.stencilAttachmentPixelFormat = RugRenderer.depthFormat
            if blended, let a = d.colorAttachments[0] {
                // Premultiplied alpha all the way to the transparent window.
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        clothPipeline = try pipeline("clothVertex", "clothFragment", blended: false)
        shadowPipeline = try pipeline("shadowVertex", "shadowFragment", blended: true)
        quadPipeline = try pipeline("quadVertex", "quadFragment", blended: true)

        let cloth = MTLDepthStencilDescriptor()
        cloth.depthCompareFunction = .lessEqual
        cloth.isDepthWriteEnabled = true
        let flat = MTLDepthStencilDescriptor()
        flat.depthCompareFunction = .always
        flat.isDepthWriteEnabled = false
        // Each rug's shadow darkens a pixel once (a folded rug would otherwise double it), yet still
        // falls on the rugs below: rug n writes n into the stencil and only passes where it is lower.
        let shadow = MTLDepthStencilDescriptor()
        shadow.depthCompareFunction = .always
        shadow.isDepthWriteEnabled = false
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .greater
        stencil.depthStencilPassOperation = .replace
        shadow.frontFaceStencil = stencil
        shadow.backFaceStencil = stencil
        guard let c = device.makeDepthStencilState(descriptor: cloth),
              let f = device.makeDepthStencilState(descriptor: flat),
              let s = device.makeDepthStencilState(descriptor: shadow) else { throw RendererError.setup("depth state") }
        clothDepth = c
        flatDepth = f
        shadowDepth = s

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.maxAnisotropy = 8
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let smp = device.makeSamplerState(descriptor: sd) else { throw RendererError.setup("sampler") }
        sampler = smp
    }

    // MARK: - Textures

    /// The woven texture for `style`, or nil while it is still being generated (`ready` runs once it is).
    func texture(for style: RugStyle, ready: @escaping () -> Void) -> MTLTexture? {
        if let texture = rugTextures[style.id] { return texture }
        guard !loadingStyles.contains(style.id) else { return nil }
        loadingStyles.insert(style.id)
        let device = device, queue = queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let texture = TextureFactory.rugTexture(device: device, queue: queue, style: style)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingStyles.remove(style.id)
                self.rugTextures[style.id] = texture
                ready()
            }
        }
        return nil
    }

    func loadedTexture(for style: RugStyle) -> MTLTexture? { rugTextures[style.id] }

    /// Seeds the cache, for the offscreen snapshot tool.
    func setTexture(_ texture: MTLTexture, for style: RugStyle) { rugTextures[style.id] = texture }

    /// Frees the 15 MB per style that no rug wears any more.
    func purgeRugTextures(keeping styleIDs: Set<String>) {
        rugTextures = rugTextures.filter { styleIDs.contains($0.key) }
    }

    func purgeIcons(keeping ids: Set<UUID>) {
        iconTextures = iconTextures.filter { ids.contains($0.key) }
    }

    // MARK: - Drawing

    /// Draws `scenes` (bottom rug first) into a view that shows the part of world space starting at `viewOrigin`.
    func encode(_ scenes: [RugScene], viewOrigin: SIMD2<Float>, viewSize: SIMD2<Float>, into enc: MTLRenderCommandEncoder) {
        enc.setCullMode(.none)
        for (layer, scene) in scenes.enumerated() {
            encode(scene, layer: layer, viewOrigin: viewOrigin, viewSize: viewSize, into: enc)
        }
    }

    private func encode(_ scene: RugScene, layer: Int, viewOrigin: SIMD2<Float>, viewSize: SIMD2<Float>, into enc: MTLRenderCommandEncoder) {
        let sim = scene.sim
        var U = Uniforms(viewSize: viewSize,
                         viewOrigin: viewOrigin,
                         perspCenter: sim.center,
                         shadowBase: SIMD2(2.5, -3.5),
                         shadowSlope: SIMD2(0.32, -0.42),
                         knotGrid: SIMD2(sim.width / 2.2, sim.height / 2.2),
                         perspDist: 1800,
                         fringe: Float(RugPattern.fringeFraction),
                         shadowAlpha: 0.38,
                         aspect: sim.width / sim.height,
                         quadAlpha: 1,
                         layer: Float(layer))

        let half = RugRenderer.iconSize / 2
        for icon in scene.icons {
            guard let tex = iconTexture(for: icon) else { continue }
            let c = icon.center
            let corners = [c + SIMD2(-half.x, -half.y), c + SIMD2(half.x, -half.y), c + SIMD2(-half.x, half.y), c + SIMD2(half.x, half.y)]
            drawQuad(enc, corners: corners, texture: tex, uniforms: &U)
        }

        ensureIndexBuffer(sim)
        fillVertices(sim)
        guard let ib = indexBuffer,
              let vb = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<ClothVertex>.stride, options: .storageModeShared)
        else { return }
        let uniformLength = MemoryLayout<Uniforms>.stride

        enc.setRenderPipelineState(shadowPipeline)
        enc.setDepthStencilState(shadowDepth)
        enc.setStencilReferenceValue(UInt32(min(layer + 1, 255)))
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setVertexBytes(&U, length: uniformLength, index: 1)
        enc.setFragmentTexture(scene.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&U, length: uniformLength, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)

        enc.setRenderPipelineState(clothPipeline)
        enc.setDepthStencilState(clothDepth)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)
    }

    private func drawQuad(_ enc: MTLRenderCommandEncoder, corners: [SIMD2<Float>], texture: MTLTexture, uniforms U: inout Uniforms) {
        guard corners.count == 4 else { return }
        var quad = [
            QuadVertex(x: corners[0].x, y: corners[0].y, u: 0, v: 1),
            QuadVertex(x: corners[1].x, y: corners[1].y, u: 1, v: 1),
            QuadVertex(x: corners[2].x, y: corners[2].y, u: 0, v: 0),
            QuadVertex(x: corners[3].x, y: corners[3].y, u: 1, v: 0),
        ]
        enc.setRenderPipelineState(quadPipeline)
        enc.setDepthStencilState(flatDepth)
        enc.setVertexBytes(&quad, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
        enc.setVertexBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func iconTexture(for icon: IconPlacement) -> MTLTexture? {
        if let tex = iconTextures[icon.id] { return tex }
        guard let image = icon.image(),
              let tex = TextureFactory.texture(from: image, device: device, queue: queue, mipmapped: false) else { return nil }
        iconTextures[icon.id] = tex
        return tex
    }

    private func ensureIndexBuffer(_ sim: ClothSimulation) {
        guard indexBuffer == nil || indexCount != sim.indices.count else { return }
        indexBuffer = device.makeBuffer(bytes: sim.indices, length: sim.indices.count * MemoryLayout<UInt16>.stride, options: .storageModeShared)
        indexCount = sim.indices.count
    }

    private func fillVertices(_ sim: ClothSimulation) {
        let cols = sim.cols, rows = sim.rows
        if vertices.count != cols * rows {
            vertices = Array(repeating: ClothVertex(), count: cols * rows)
        }
        let uvs = sim.uvs
        sim.positions.withUnsafeBufferPointer { p in
            for r in 0..<rows {
                for c in 0..<cols {
                    let i = r * cols + c
                    let left = p[r * cols + max(c - 1, 0)], right = p[r * cols + min(c + 1, cols - 1)]
                    let down = p[max(r - 1, 0) * cols + c], up = p[min(r + 1, rows - 1) * cols + c]
                    var n = simd_cross(right - left, up - down)
                    let len = simd_length(n)
                    n = len > 1e-6 ? n / len : SIMD3(0, 0, 1)
                    let pos = p[i]
                    vertices[i] = ClothVertex(px: pos.x, py: pos.y, pz: pos.z, nx: n.x, ny: n.y, nz: n.z, u: uvs[i].x, v: uvs[i].y)
                }
            }
        }
    }
}
