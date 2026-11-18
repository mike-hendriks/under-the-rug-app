import AppKit
import MetalKit
import simd

/// The full-screen, mostly transparent Metal view that draws the rug and handles everything you do with it:
/// drag to pull it around, double-click to fold an end back, drop files on it to shove them under,
/// and drag exposed files back out from under a folded rug.
final class RugView: MTKView, MTKViewDelegate, NSDraggingSource {
    var onShove: (([URL], SIMD2<Float>) -> Void)?
    var onMoveItem: ((UUID, SIMD2<Float>) -> Void)?
    var onOpenItem: ((UUID) -> Void)?
    var onNeedsValidation: (() -> Void)?
    var onSettled: ((SIMD2<Float>, Float) -> Void)?
    var menuProvider: (() -> NSMenu)?

    let renderer: RugRenderer
    private(set) var sim: ClothSimulation
    private(set) var style: RugStyle
    private(set) var rugSize: RugSize

    var items: [StashedItem] = [] {
        didSet {
            syncBumps(animated: true)
            renderer.purgeIcons(keeping: Set(items.map(\.id)))
            wake()
        }
    }

    private var lastFrame: CFTimeInterval = 0
    private var pendingItem: (id: UUID, start: NSPoint)?
    private var draggingOutID: UUID?
    private var isDragHovering = false
    private var textureGeneration = 0

    init(frame: NSRect, device: MTLDevice, style: RugStyle, size: RugSize, center: SIMD2<Float>?, angle: Float) throws {
        renderer = try RugRenderer(device: device)
        self.style = style
        rugSize = size
        let start = center ?? SIMD2(Float(frame.midX), Float(frame.height * 0.42))
        sim = ClothSimulation(width: size.width, height: size.height, center: start, angle: angle, dropHeight: 160)
        super.init(frame: frame, device: device)

        colorPixelFormat = RugRenderer.colorFormat
        depthStencilPixelFormat = RugRenderer.depthFormat
        if device.supportsFamily(.apple1) {
            depthStencilStorageMode = .memoryless
        }
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clearDepth = 1
        clearStencil = 0
        preferredFramesPerSecond = 60
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        delegate = self
        registerForDraggedTypes([.fileURL])

        loadTexture(for: style, shake: false)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Configuration

    func setStyle(_ style: RugStyle) {
        self.style = style
        loadTexture(for: style, shake: true)
    }

    func setSize(_ size: RugSize) {
        rugSize = size
        let old = sim
        sim = ClothSimulation(width: size.width, height: size.height, center: old.center, angle: old.angle, dropHeight: 40)
        syncBumps(animated: false)
        wake()
    }

    func straighten() {
        sim.moveFrame(to: sim.center, angle: 0)
        wake()
    }

    /// Lays the rug flat, straight-ish, in the middle of the screen.
    func bringBack() {
        sim.release()
        sim.unfold()
        sim.moveFrame(to: defaultCenter, angle: -0.035)
        wake()
    }

    /// Glides the rug back when it ended up (mostly) off screen: after a throw or a display change.
    /// At least about a third of the rug stays in view.
    func keepOnScreen() {
        if let target = onScreenCenter() {
            sim.moveFrame(to: target, angle: sim.angle)
        }
        wake()
    }

    /// Where the rug centre should go to be back in view, or nil when it already is.
    private func onScreenCenter() -> SIMD2<Float>? {
        let mx = sim.width * 0.3, my = sim.height * 0.3
        let w = Float(bounds.width), h = Float(bounds.height)
        let menuBar: Float = 24
        let c = sim.center
        let clamped = SIMD2(min(max(c.x, mx), w - mx), min(max(c.y, my), h - menuBar - my))
        return simd_distance(clamped, c) > 0.5 ? clamped : nil
    }

    func toggleLift() {
        if sim.isFolded {
            sim.unfold()
        } else {
            sim.fold(side: -1, distance: sim.width * 0.45)
        }
        wake()
    }

    var isLifted: Bool { sim.isFolded }

    /// Every lump puffs up once, for when a whole desktop just went under.
    func rippleEverything() {
        for item in items {
            sim.ripple(atLocal: localPosition(of: item), strength: 1.0, radius: 70)
        }
        wake()
    }

    private var defaultCenter: SIMD2<Float> {
        SIMD2(Float(bounds.midX), Float(bounds.height * 0.42))
    }

    private func loadTexture(for style: RugStyle, shake: Bool) {
        textureGeneration += 1
        let generation = textureGeneration
        let device = renderer.device, queue = renderer.queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let texture = TextureFactory.rugTexture(device: device, queue: queue, style: style)
            DispatchQueue.main.async {
                guard let self, generation == self.textureGeneration else { return }
                self.renderer.rugTexture = texture
                if shake { self.sim.shake() }
                self.wake()
            }
        }
    }

    private func syncBumps(animated: Bool) {
        let radius = min(sim.width, sim.height) * 0.09
        var next: [RugBump] = []
        for item in items {
            let center = localPosition(of: item)
            if var bump = sim.bumps.first(where: { $0.id == item.id }) {
                bump.center = center
                bump.target = 1
                next.append(bump)
            } else {
                // Folders and big things make bigger lumps; vary a little per item so it looks lived in.
                let height = 13 + Float(item.id.uuid.0 % 6)
                next.append(RugBump(id: item.id, center: center, radius: radius, height: height, scale: animated ? 0 : 1, target: 1))
            }
        }
        for var bump in sim.bumps where !items.contains(where: { $0.id == bump.id }) {
            bump.target = 0
            next.append(bump)
        }
        sim.bumps = next
    }

    // MARK: - Drawing

    func wake() {
        guard isPaused else { return }
        lastFrame = CACurrentMediaTime()
        isPaused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrame, 1.0 / 240), 1.0 / 30))
        lastFrame = now
        guard renderer.rugTexture != nil else { return }

        sim.update(dt: dt)
        if !sim.isGrabbing && !sim.isMovingFrame, let target = onScreenCenter() {
            sim.moveFrame(to: target, angle: sim.angle)
        }

        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = renderer.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        renderer.encode(scene(), into: encoder)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Nothing moves any more: stop drawing until something happens, so the rug costs nothing at rest.
        if sim.isSettled && !isDragHovering && pendingItem == nil && draggingOutID == nil {
            isPaused = true
            onSettled?(sim.center, sim.angle)
        }
    }

    private func scene() -> RugScene {
        let icons = items.compactMap { item -> IconPlacement? in
            guard item.id != draggingOutID else { return nil }
            let path = item.stashedPath, name = item.name
            return IconPlacement(id: item.id, center: sim.toWorld(localPosition(of: item))) {
                TextureFactory.iconImage(path: path, name: name)
            }
        }
        return RugScene(sim: sim, icons: icons,
                        viewSize: SIMD2(Float(bounds.width), Float(bounds.height)))
    }

    // MARK: - Hit testing

    private func world(_ p: NSPoint) -> SIMD2<Float> { SIMD2(Float(p.x), Float(p.y)) }
    private func localPoint(_ p: NSPoint) -> SIMD2<Float> { sim.toLocal(world(p)) }
    private func localPosition(of item: StashedItem) -> SIMD2<Float> { SIMD2(item.x * sim.width, item.y * sim.height) }

    func rugContains(_ p: NSPoint) -> Bool {
        let l = localPoint(p)
        return abs(l.x) <= sim.width / 2 + 6 && abs(l.y) <= sim.height / 2 + 6
    }

    /// Whether the window should take the mouse at `p` instead of letting it through to the desktop.
    func wantsMouse(at p: NSPoint) -> Bool {
        sim.isGrabbing || pendingItem != nil || rugContains(p)
    }

    private func exposedItem(at p: NSPoint) -> StashedItem? {
        for item in items.reversed() {
            let local = localPosition(of: item)
            guard sim.isExposed(local: local, margin: 16) else { continue }
            let w = sim.toWorld(local)
            if abs(Float(p.x) - w.x) < 40 && abs(Float(p.y) - w.y) < 46 { return item }
        }
        return nil
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        wake()
        if let item = exposedItem(at: p) {
            if event.clickCount >= 2 {
                onOpenItem?(item.id)
            } else {
                pendingItem = (item.id, p)
            }
            return
        }
        guard rugContains(p) else { return }
        if event.clickCount >= 2 {
            sim.release()
            sim.toggleFold(atLocalX: localPoint(p).x)
            return
        }
        // Bare floor next to a folded-back end: nothing to pick up there.
        if sim.isExposed(local: localPoint(p), margin: 0) { return }
        sim.grab(atWorld: world(p))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let pending = pendingItem {
            if hypot(p.x - pending.start.x, p.y - pending.start.y) > 4 {
                beginItemDrag(pending.id, event: event)
            }
            return
        }
        if sim.isGrabbing {
            sim.drag(toWorld: world(p))
            wake()
        }
    }

    override func mouseUp(with event: NSEvent) {
        pendingItem = nil
        if sim.isGrabbing {
            sim.release()
            wake()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Dragging files out from under the rug

    private func beginItemDrag(_ id: UUID, event: NSEvent) {
        pendingItem = nil
        guard let item = items.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: item.stashedPath)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: item.stashedPath)
        icon.size = NSSize(width: 64, height: 64)
        let w = sim.toWorld(localPosition(of: item))
        // The icon sits 18 pt above the centre of its label tile.
        dragItem.setDraggingFrame(NSRect(x: CGFloat(w.x) - 32, y: CGFloat(w.y) - 14, width: 64, height: 64), contents: icon)
        draggingOutID = id
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        wake()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : [.move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingOutID = nil
        // Finder may finish the move a moment later, so check a few times whether the file left.
        for delay in [0.0, 0.6, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.onNeedsValidation?() }
        }
        wake()
    }

    // MARK: - Shoving files under the rug

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(for: sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { endHover() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        endHover()
        guard rugContains(p) else { return false }
        let local = localPoint(p)
        let normalized = SIMD2(local.x / sim.width, local.y / sim.height)

        if (sender.draggingSource as AnyObject?) === self, let id = draggingOutID {
            onMoveItem?(id, normalized)
            sim.ripple(atLocal: local, strength: 0.8)
            return true
        }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onShove?(urls, normalized)
        sim.ripple(atLocal: local, strength: 1.6)
        wake()
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        guard rugContains(p) else {
            endHover()
            return []
        }
        isDragHovering = true
        sim.hoverPoint = localPoint(p)
        wake()
        return .move
    }

    private func endHover() {
        isDragHovering = false
        sim.hoverPoint = nil
        wake()
    }
}
