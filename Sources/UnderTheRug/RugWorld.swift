import AppKit
import simd

/// One rug on the desktop: its look and its cloth.
final class Rug {
    let id: UUID
    var style: RugStyle {
        didSet { wantsShake = true }
    }
    private(set) var size: RugSize
    private(set) var sim: ClothSimulation
    /// Shake the rug out once its new texture is ready.
    var wantsShake = false

    init(id: UUID = UUID(), style: RugStyle, size: RugSize, center: SIMD2<Float>, angle: Float, dropHeight: Float) {
        self.id = id
        self.style = style
        self.size = size
        sim = ClothSimulation(width: size.width, height: size.height, center: center, angle: angle, dropHeight: dropHeight)
    }

    convenience init(config: RugConfig) {
        self.init(id: config.id, style: RugStyle.named(config.style), size: RugSize(rawValue: config.size) ?? .medium,
                  center: SIMD2(config.x, config.y), angle: config.angle,
                  // After an update the rugs are simply still there; on a normal launch they flutter down.
                  dropHeight: Updater.launchedAfterUpdate ? 0 : 160)
    }

    var config: RugConfig {
        RugConfig(id: id, style: style.id, size: size.rawValue, x: sim.center.x, y: sim.center.y, angle: sim.angle)
    }

    func resize(to size: RugSize) {
        self.size = size
        sim = ClothSimulation(width: size.width, height: size.height, center: sim.center, angle: sim.angle, dropHeight: 40)
    }

    /// True over the rug, but not over the bare desktop next to a folded-back end.
    func covers(_ p: SIMD2<Float>, margin: Float = 6) -> Bool {
        let l = sim.toLocal(p)
        guard abs(l.x) <= sim.width / 2 + margin && abs(l.y) <= sim.height / 2 + margin else { return false }
        return !sim.isExposed(local: l, margin: 0)
    }

    func localPosition(of item: StashedItem) -> SIMD2<Float> {
        SIMD2(item.x * sim.width, item.y * sim.height)
    }

    /// `p` (world) as a fraction of the rug size, the way stashed items store their spot.
    func normalized(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let l = sim.toLocal(p)
        return SIMD2(l.x / sim.width, l.y / sim.height)
    }
}

/// Every rug on every screen, the files under them and the one mouse that pushes them around.
///
/// World space is global screen points (Cocoa: origin at the bottom left of the main screen, y up), so a rug
/// can lie across two displays. Each screen has its own window and view; whichever view draws first in a
/// frame steps the simulation for all of them.
final class RugWorld {
    let renderer: RugRenderer
    /// Bottom to top. The last one is the rug touched most recently.
    private(set) var rugs: [Rug] = []
    var items: [StashedItem] = [] {
        didSet {
            syncBumps(animated: true)
            renderer.purgeIcons(keeping: Set(items.map(\.id)))
            wake()
        }
    }
    /// Frames of all screens, to keep rugs within reach.
    var screens: [CGRect] = []

    // The mouse.
    var pendingItem: (id: UUID, start: SIMD2<Float>)?
    var draggingOutID: UUID?
    private(set) var isDragHovering = false

    var onWake: (() -> Void)?
    var onSettled: (() -> Void)?
    var onShove: (([URL], Rug, SIMD2<Float>) -> Void)?
    var onMoveItem: ((UUID, Rug, SIMD2<Float>) -> Void)?
    var onOpenItem: ((UUID) -> Void)?
    var onNeedsValidation: (() -> Void)?
    var menuProvider: ((Rug) -> NSMenu)?

    private(set) var isSettled = false
    private var lastAdvance: CFTimeInterval = 0

    init(renderer: RugRenderer) {
        self.renderer = renderer
    }

    var activeRug: Rug? { rugs.last }

    func rug(withID id: UUID?) -> Rug? { rugs.first { $0.id == id } }

    func items(on rug: Rug) -> [StashedItem] { items.filter { $0.rugID == rug.id } }

    // MARK: - Rugs

    func add(_ rug: Rug) {
        rugs.append(rug)
        syncBumps(animated: false)
        wake()
    }

    func remove(_ rug: Rug) {
        rugs.removeAll { $0 === rug }
        renderer.purgeRugTextures(keeping: Set(rugs.map(\.style.id)))
        wake()
    }

    func bringToFront(_ rug: Rug) {
        guard let i = rugs.firstIndex(where: { $0 === rug }), i != rugs.count - 1 else { return }
        rugs.remove(at: i)
        rugs.append(rug)
    }

    func setStyle(_ style: RugStyle, of rug: Rug) {
        rug.style = style
        renderer.purgeRugTextures(keeping: Set(rugs.map(\.style.id)))
        wake()
    }

    func setSize(_ size: RugSize, of rug: Rug) {
        rug.resize(to: size)
        syncBumps(animated: false)
        wake()
    }

    /// Lays every rug flat again, fanned out over the middle of `screen`.
    func bringAllBack(to screen: CGRect) {
        let mid = SIMD2(Float(screen.midX), Float(screen.minY + screen.height * 0.45))
        let count = Float(rugs.count)
        for (i, rug) in rugs.enumerated() {
            let step = Float(i) - (count - 1) / 2
            rug.sim.release()
            rug.sim.unfold()
            rug.sim.moveFrame(to: mid + SIMD2(step * 40, -step * 30), angle: -0.035)
        }
        wake()
    }

    // MARK: - Hit testing

    /// The topmost rug at `p`.
    func rug(at p: SIMD2<Float>) -> Rug? {
        rugs.last { $0.covers(p) }
    }

    /// A hidden file lying in the open next to a folded-back rug, unless another rug lies on top of it.
    func exposedItem(at p: SIMD2<Float>) -> (item: StashedItem, rug: Rug)? {
        for rug in rugs.reversed() {
            for item in items(on: rug).reversed() {
                let local = rug.localPosition(of: item)
                guard rug.sim.isExposed(local: local, margin: 16) else { continue }
                let w = rug.sim.toWorld(local)
                if abs(p.x - w.x) < 40 && abs(p.y - w.y) < 46 { return (item, rug) }
            }
            if rug.covers(p) { return nil }
        }
        return nil
    }

    /// Whether the windows should take the mouse at `p` instead of letting it through to the desktop.
    func wantsMouse(at p: SIMD2<Float>) -> Bool {
        rugs.contains { $0.sim.isGrabbing } || pendingItem != nil || rug(at: p) != nil || exposedItem(at: p) != nil
    }

    /// Lifts the rug a file is dragged over a little. Returns that rug, if any.
    @discardableResult
    func hover(at p: SIMD2<Float>?) -> Rug? {
        let target = p.flatMap { rug(at: $0) }
        for rug in rugs {
            rug.sim.hoverPoint = (rug === target && p != nil) ? rug.sim.toLocal(p!) : nil
        }
        isDragHovering = target != nil
        wake()
        return target
    }

    // MARK: - Simulation

    func wake() {
        isSettled = false
        onWake?()
    }

    /// Steps every rug once per frame, however many screens ask.
    func advance(now: CFTimeInterval) {
        let elapsed = now - lastAdvance
        guard elapsed > 1.0 / 250 else { return }
        lastAdvance = now
        let dt = Float(min(elapsed, 1.0 / 30))

        var settled = true
        for rug in rugs {
            guard renderer.texture(for: rug.style, ready: { [weak self] in self?.wake() }) != nil else {
                settled = false
                continue
            }
            if rug.wantsShake {
                rug.sim.shake()
                rug.wantsShake = false
            }
            rug.sim.update(dt: dt)
            if !rug.sim.isGrabbing && !rug.sim.isMovingFrame, let target = onScreenCenter(for: rug) {
                rug.sim.moveFrame(to: target, angle: rug.sim.angle)
            }
            if !rug.sim.isSettled { settled = false }
        }
        if isDragHovering || pendingItem != nil || draggingOutID != nil { settled = false }

        if settled && !isSettled {
            isSettled = true
            onSettled?()
        } else if !settled {
            isSettled = false
        }
    }

    /// Where a rug should glide to be back on a screen, at least a third of it in view; nil when it already is.
    private func onScreenCenter(for rug: Rug) -> SIMD2<Float>? {
        guard !screens.isEmpty else { return nil }
        let mx = rug.sim.width * 0.3, my = rug.sim.height * 0.3
        let menuBar: Float = 24
        let c = rug.sim.center
        var best = c
        var bestDistance = Float.infinity
        for s in screens {
            let clamped = SIMD2(min(max(c.x, Float(s.minX) + mx), Float(s.maxX) - mx),
                                min(max(c.y, Float(s.minY) + my), Float(s.maxY) - menuBar - my))
            let d = simd_distance(clamped, c)
            if d < bestDistance {
                bestDistance = d
                best = clamped
            }
        }
        return bestDistance > 0.5 ? best : nil
    }

    private func syncBumps(animated: Bool) {
        for rug in rugs {
            let radius = min(rug.sim.width, rug.sim.height) * 0.09
            let mine = items(on: rug)
            var next: [RugBump] = []
            for item in mine {
                let center = rug.localPosition(of: item)
                if var bump = rug.sim.bumps.first(where: { $0.id == item.id }) {
                    bump.center = center
                    bump.target = 1
                    next.append(bump)
                } else {
                    // Vary a little per item so it looks lived in.
                    let height = 13 + Float(item.id.uuid.0 % 6)
                    next.append(RugBump(id: item.id, center: center, radius: radius, height: height,
                                        scale: animated ? 0 : 1, target: 1))
                }
            }
            for var bump in rug.sim.bumps where !mine.contains(where: { $0.id == bump.id }) {
                bump.target = 0
                next.append(bump)
            }
            rug.sim.bumps = next
        }
    }

    /// What to draw, bottom rug first. Rugs whose texture is still being woven are left out.
    func scenes() -> [RugScene] {
        rugs.compactMap { rug in
            guard let texture = renderer.loadedTexture(for: rug.style) else { return nil }
            let icons = items(on: rug).compactMap { item -> IconPlacement? in
                guard item.id != draggingOutID else { return nil }
                let path = item.stashedPath, name = item.name
                return IconPlacement(id: item.id, center: rug.sim.toWorld(rug.localPosition(of: item))) {
                    TextureFactory.iconImage(path: path, name: name)
                }
            }
            return RugScene(sim: rug.sim, icons: icons, texture: texture)
        }
    }
}
