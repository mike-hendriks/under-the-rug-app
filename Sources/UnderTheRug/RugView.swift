import AppKit
import MetalKit
import simd

/// The transparent Metal view filling one screen. It draws every rug that falls on that screen and
/// handles what you do with them there: drag to pull a rug around (also onto another screen),
/// double-click to fold an end back, drop files on a rug to shove them under, and drag exposed files
/// back out. All positions are converted to global screen points before they reach the world.
final class RugView: MTKView, MTKViewDelegate, NSDraggingSource {
    let world: RugWorld
    /// The rug the mouse is holding, also while the pointer wanders onto another screen.
    private weak var grabbedRug: Rug?

    init(frame: NSRect, device: MTLDevice, world: RugWorld) {
        self.world = world
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
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Coordinates

    private func global(windowPoint p: NSPoint) -> SIMD2<Float> {
        guard let window else { return SIMD2(Float(p.x), Float(p.y)) }
        let s = window.convertPoint(toScreen: p)
        return SIMD2(Float(s.x), Float(s.y))
    }

    private var viewOrigin: SIMD2<Float> {
        guard let window else { return .zero }
        return SIMD2(Float(window.frame.minX), Float(window.frame.minY))
    }

    // MARK: - Drawing

    func wake() {
        isPaused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        world.advance(now: CACurrentMediaTime())
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = world.renderer.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        world.renderer.encode(world.scenes(), viewOrigin: viewOrigin,
                              viewSize: SIMD2(Float(bounds.width), Float(bounds.height)), into: encoder)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Nothing moves any more: stop drawing until something happens, so the rugs cost nothing at rest.
        if world.isSettled {
            isPaused = true
        }
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = global(windowPoint: event.locationInWindow)
        world.wake()
        if let hit = world.exposedItem(at: p) {
            world.bringToFront(hit.rug)
            if event.clickCount >= 2 {
                world.onOpenItem?(hit.item.id)
            } else {
                world.pendingItem = (hit.item.id, p)
            }
            return
        }
        guard let rug = world.rug(at: p) else { return }
        world.bringToFront(rug)
        if event.clickCount >= 2 {
            rug.sim.release()
            rug.sim.toggleFold(atLocalX: rug.sim.toLocal(p).x)
            return
        }
        if rug.sim.grab(atWorld: p) {
            grabbedRug = rug
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = global(windowPoint: event.locationInWindow)
        if let pending = world.pendingItem {
            if simd_distance(p, pending.start) > 4 {
                beginItemDrag(pending.id, event: event)
            }
            return
        }
        if let rug = grabbedRug {
            rug.sim.drag(toWorld: p)
            world.wake()
        }
    }

    override func mouseUp(with event: NSEvent) {
        world.pendingItem = nil
        grabbedRug?.sim.release()
        grabbedRug = nil
        world.wake()
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = global(windowPoint: event.locationInWindow)
        guard let rug = world.rug(at: p) ?? world.exposedItem(at: p)?.rug,
              let menu = world.menuProvider?(rug) else { return }
        world.bringToFront(rug)
        world.wake()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Dragging files out from under a rug

    private func beginItemDrag(_ id: UUID, event: NSEvent) {
        world.pendingItem = nil
        guard let item = world.items.first(where: { $0.id == id }), let rug = world.rug(withID: item.rugID) else { return }
        let url = URL(fileURLWithPath: item.stashedPath)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: item.stashedPath)
        icon.size = NSSize(width: 64, height: 64)
        let w = rug.sim.toWorld(rug.localPosition(of: item)) - viewOrigin
        // The icon sits 18 pt above the centre of its label tile.
        dragItem.setDraggingFrame(NSRect(x: CGFloat(w.x) - 32, y: CGFloat(w.y) - 14, width: 64, height: 64), contents: icon)
        world.draggingOutID = id
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        world.wake()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : [.move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        world.draggingOutID = nil
        // Finder may finish the move a moment later, so check a few times whether the file left.
        for delay in [0.0, 0.6, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.world.onNeedsValidation?() }
        }
        world.wake()
    }

    // MARK: - Shoving files under a rug

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(for: sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { world.hover(at: nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = global(windowPoint: sender.draggingLocation)
        world.hover(at: nil)
        guard let rug = world.rug(at: p) else { return false }
        let local = rug.sim.toLocal(p)
        world.bringToFront(rug)

        // One of our own hidden files, dropped on a rug again: it just moves (perhaps to another rug).
        if sender.draggingSource is RugView, let id = world.draggingOutID {
            world.onMoveItem?(id, rug, rug.normalized(p))
            rug.sim.ripple(atLocal: local, strength: 0.8)
            return true
        }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        world.onShove?(urls, rug, rug.normalized(p))
        rug.sim.ripple(atLocal: local, strength: 1.6)
        world.wake()
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        world.hover(at: global(windowPoint: sender.draggingLocation)) == nil ? [] : .move
    }
}
