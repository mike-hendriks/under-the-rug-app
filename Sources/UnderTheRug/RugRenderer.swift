import CoreGraphics
import Metal
import simd

/// Mirrors `Uniforms` in Shaders.swift; keep the field order identical (64 bytes).
struct Uniforms {
    var viewSize: SIMD2<Float>
    var perspCenter: SIMD2<Float>
    var shadowBase: SIMD2<Float>
    var shadowSlope: SIMD2<Float>
    var knotGrid: SIMD2<Float>
    var perspDist: Float
    var fringe: Float
    var shadowAlpha: Float
    var aspect: Float
    var quadAlpha: Float
    var pad: Float = 0
}

struct ClothVertex {
    var px: Float = 0, py: Float = 0, pz: Float = 0
    var nx: Float = 0, ny: Float = 0, nz: Float = 1
    var u: Float = 0, v: Float = 0
}

struct QuadVertex {
    var x: Float, y: Float, u: Float, v: Float
}

/// A file icon lying on the floor under the rug.
struct IconPlacement {
    let id: UUID
    let center: SIMD2<Float>
    let image: () -> CGImage?
}

struct RugScene {
    let sim: ClothSimulation
    let icons: [IconPlacement]
    let floorCorners: [SIMD2<Float>]
    let viewSize: SIMD2<Float>
}

enum RendererError: Error {
    case setup(String)
}

/// Draws, back to front: the floor under the rug, the hidden file icons, the rug's shadow, the rug.
final class RugRenderer {
    static let colorFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float_stencil8
    static let iconSize = SIMD2<Float>(112, 104)

    let device: MTLDevice
    let queue: MTLCommandQueue
    var rugTexture: MTLTexture?
    var floorTexture: MTLTexture?

    private let clothPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let quadPipeline: MTLRenderPipelineState
    private let clothDepth: MTLDepthStencilState
    private let flatDepth: MTLDepthStencilState
    private let shadowDepth: MTLDepthStencilState
    private let sampler: MTLSamplerState
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
        // The shadow writes each pixel once, so a folded rug does not cast a double-dark shadow.
        let shadow = MTLDepthStencilDescriptor()
        shadow.depthCompareFunction = .always
        shadow.isDepthWriteEnabled = false
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .equal
        stencil.depthStencilPassOperation = .incrementClamp
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

    func purgeIcons(keeping ids: Set<UUID>) {
        iconTextures = iconTextures.filter { ids.contains($0.key) }
    }

    func encode(_ scene: RugScene, into enc: MTLRenderCommandEncoder) {
        let sim = scene.sim
        var U = Uniforms(viewSize: scene.viewSize,
                         perspCenter: sim.center,
                         shadowBase: SIMD2(2.5, -3.5),
                         shadowSlope: SIMD2(0.32, -0.42),
                         knotGrid: SIMD2(sim.width / 2.2, sim.height / 2.2),
                         perspDist: 1800,
                         fringe: Float(RugPattern.fringeFraction),
                         shadowAlpha: 0.38,
                         aspect: sim.width / sim.height,
                         quadAlpha: 1)
        enc.setCullMode(.none)

        guard let rug = rugTexture else { return }

        if let floor = floorTexture {
            drawQuad(enc, corners: scene.floorCorners, texture: floor, uniforms: &U)
        }
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
        enc.setStencilReferenceValue(0)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setVertexBytes(&U, length: uniformLength, index: 1)
        enc.setFragmentTexture(rug, index: 0)
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
