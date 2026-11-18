import AppKit
import Metal
import ServiceManagement
import simd

/// Owns the windows (one per screen), the rugs, the stash of hidden files and the menu bar item.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var device: MTLDevice!
    private var world: RugWorld!
    private var windows: [RugWindow] = []
    private var views: [RugView] = []
    private var statusItem: NSStatusItem!
    private let stash = Stash()
    private var passthroughTimer: Timer?
    private var swatches: [String: NSImage] = [:]
    /// The rug a menu acts on: the one right-clicked, or else the one touched last.
    private weak var menuRug: Rug?

    func applicationDidFinishLaunching(_ notification: Notification) {
        stash.load()
        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("This Mac has no Metal GPU, so the rug can't be drawn.")
            return
        }
        self.device = device
        do {
            world = RugWorld(renderer: try RugRenderer(device: device))
        } catch {
            fail("The rug's shaders failed to load: \(error.localizedDescription)")
            return
        }
        wireUpWorld()

        let configs = Settings.rugs
        if configs.isEmpty {
            world.add(newRug(style: RugStyle.all[0], size: .medium, on: NSScreen.screens.first))
        } else {
            configs.forEach { world.add(Rug(config: $0)) }
        }
        if let first = world.rugs.first {
            stash.adoptOrphans(knownRugs: Set(world.rugs.map(\.id)), into: first.id)
        }
        world.items = stash.items

        buildWindows()
        setUpStatusItem()
        startPassthrough()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        renderSwatches()
        saveRugs()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveRugs()
    }

    private func saveRugs() {
        guard let world else { return }
        Settings.rugs = world.rugs.map(\.config)
    }

    private func wireUpWorld() {
        world.onWake = { [weak self] in self?.views.forEach { $0.wake() } }
        world.onSettled = { [weak self] in self?.saveRugs() }
        world.onShove = { [weak self] urls, rug, position in self?.shove(urls, under: rug, at: position) }
        world.onMoveItem = { [weak self] id, rug, position in
            self?.stash.move(id, to: position, rugID: rug.id)
            self?.refreshItems()
        }
        world.onOpenItem = { [weak self] id in
            guard let item = self?.stash.items.first(where: { $0.id == id }) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: item.stashedPath))
        }
        world.onNeedsValidation = { [weak self] in
            guard let self, self.stash.pruneMissing() else { return }
            self.refreshItems()
        }
        world.menuProvider = { [weak self] rug in
            let menu = NSMenu()
            self?.populate(menu, for: rug)
            return menu
        }
    }

    private func refreshItems() {
        world.items = stash.items
    }

    // MARK: - Screens

    /// One transparent window per screen, all drawing the same rugs in global coordinates,
    /// so a rug can be dragged from one display to the next.
    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        for screen in NSScreen.screens {
            let window = RugWindow(screen: screen)
            let view = RugView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device, world: world)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        world.screens = NSScreen.screens.map(\.frame)
        world.wake()
    }

    @objc private func screensChanged() {
        buildWindows()
    }

    /// The windows cover whole screens but only take clicks (and file drops) over a rug.
    private func startPassthrough() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.updatePassthrough() }
        RunLoop.main.add(timer, forMode: .common)
        passthroughTimer = timer
    }

    private func updatePassthrough() {
        let m = NSEvent.mouseLocation
        let wants = world.wantsMouse(at: SIMD2(Float(m.x), Float(m.y)))
        for window in windows where window.ignoresMouseEvents == wants {
            window.ignoresMouseEvents = !wants
        }
    }

    /// The screen under the mouse pointer, where new rugs land.
    private var screenUnderMouse: NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.screens.first
    }

    // MARK: - Rugs

    private func newRug(style: RugStyle, size: RugSize, on screen: NSScreen?) -> Rug {
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let jitter = SIMD2(Float.random(in: -60...60), Float.random(in: -40...40))
        let center = SIMD2(Float(frame.midX), Float(frame.minY + frame.height * 0.45)) + jitter
        return Rug(style: style, size: size, center: center, angle: Float.random(in: -0.08...0.08), dropHeight: 160)
    }

    private var targetRug: Rug? { menuRug ?? world.activeRug }

    @objc private func addRug() {
        // A style that is not on the desktop yet, if there is one.
        let used = Set(world.rugs.map(\.style.id))
        let style = RugStyle.all.first { !used.contains($0.id) } ?? RugStyle.all.randomElement() ?? RugStyle.all[0]
        world.add(newRug(style: style, size: world.activeRug?.size ?? .medium, on: screenUnderMouse))
        saveRugs()
    }

    @objc private func removeRug() {
        guard let rug = targetRug, world.rugs.count > 1 else { return }
        let hidden = world.items(on: rug)
        if !hidden.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Remove this rug?"
            alert.informativeText = hidden.count == 1
                ? "1 thing is hidden under it. It goes back to where it came from."
                : "\(hidden.count) things are hidden under it. They go back to where they came from."
            alert.addButton(withTitle: "Remove Rug")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let errors = stash.pullOutAll(rugID: rug.id)
            if !errors.isEmpty {
                refreshItems()
                showFailures(errors)
                return
            }
        }
        world.remove(rug)
        refreshItems()
        saveRugs()
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let rug = targetRug else { return }
        world.setStyle(RugStyle.named(id), of: rug)
        saveRugs()
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = RugSize(rawValue: raw), let rug = targetRug else { return }
        world.setSize(size, of: rug)
        saveRugs()
    }

    @objc private func toggleLift() {
        guard let rug = targetRug else { return }
        if rug.sim.isFolded {
            rug.sim.unfold()
        } else {
            rug.sim.fold(side: -1, distance: rug.sim.width * 0.45)
        }
        world.wake()
    }

    @objc private func straighten() {
        guard let rug = targetRug else { return }
        rug.sim.moveFrame(to: rug.sim.center, angle: 0)
        world.wake()
    }

    @objc private func bringBack() {
        world.bringAllBack(to: (screenUnderMouse ?? NSScreen.screens[0]).frame)
    }

    // MARK: - Stash actions

    private func shove(_ urls: [URL], under rug: Rug, at position: SIMD2<Float>) {
        let size = SIMD2(rug.sim.width, rug.sim.height)
        let result = stash.shove(urls, positions: Stash.spiral(count: urls.count, around: position, rugSize: size), rugID: rug.id)
        refreshItems()
        if !result.failures.isEmpty {
            DispatchQueue.main.async { self.showFailures(result.failures.map(\.error)) }
        }
    }

    @objc private func pullOutItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        do {
            try stash.pullOut(id)
        } catch {
            showFailures([error])
        }
        refreshItems()
    }

    @objc private func pullOutEverything() {
        let errors = stash.pullOutAll()
        refreshItems()
        if !errors.isEmpty { showFailures(errors) }
    }

    @objc private func revealStash() {
        NSWorkspace.shared.activateFileViewerSelecting([stash.stashFolder])
    }

    @objc private func sweepDesktop() {
        guard let rug = targetRug else { return }
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL }
        } catch {
            showFailures([error])
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        guard !urls.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Your Desktop is already spotless."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Shove 1 item under the rug?" : "Shove \(urls.count) items under the rug?"
        alert.informativeText = "Everything on your Desktop moves to ~/Library/Application Support/Under the Rug. "
            + "Pull things back out from the menu bar, or double-click the rug to lift it and drag them out."
        alert.addButton(withTitle: "Shove Them Under")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let positions = Stash.scatter(count: urls.count, offset: world.items(on: rug).count)
        let result = stash.shove(urls, positions: positions, rugID: rug.id)
        refreshItems()
        for item in world.items(on: rug) {
            rug.sim.ripple(atLocal: rug.localPosition(of: item), strength: 1.0, radius: 70)
        }
        world.wake()
        if !result.failures.isEmpty { showFailures(result.failures.map(\.error)) }
    }

    private func showFailures(_ errors: [Error]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = errors.count == 1 ? "That didn't fit under the rug." : "\(errors.count) things didn't fit under the rug."
        alert.informativeText = errors.prefix(5).map(\.localizedDescription).joined(separator: "\n")
        alert.runModal()
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Under the Rug can't start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showFailures([error])
        }
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppDelegate.statusIcon()
        statusItem.button?.toolTip = "Under the Rug"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if stash.pruneMissing() { refreshItems() }
        populate(menu, for: nil)
    }

    /// The menu bar menu (`rug` nil: acts on the rug touched last) or a rug's right-click menu.
    private func populate(_ menu: NSMenu, for rug: Rug?) {
        menuRug = rug
        menu.removeAllItems()
        let multiple = world.rugs.count > 1

        // First thing in the menu: for when a rug got thrown off the screen.
        let reset = addItem(menu, multiple ? "Bring the Rugs Back" : "Bring the Rug Back", #selector(bringBack))
        reset.keyEquivalent = "r"
        reset.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: nil)
        let add = addItem(menu, "Add a Rug", #selector(addRug))
        add.keyEquivalent = "n"
        add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        menu.addItem(.separator())

        let items = stash.items
        let header = NSMenuItem(title: items.isEmpty ? "Nothing under the rugs yet" : "Under the rugs (\(items.count))",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in items.prefix(25) {
            let entry = NSMenuItem(title: item.name, action: #selector(pullOutItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.toolTip = "Pull out, back to \((item.originalPath as NSString).deletingLastPathComponent)"
            let icon = NSWorkspace.shared.icon(forFile: item.stashedPath)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        if items.count > 25 {
            let more = NSMenuItem(title: "…and \(items.count - 25) more", action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
        if !items.isEmpty {
            addItem(menu, "Pull Everything Back Out", #selector(pullOutEverything))
            addItem(menu, "Show the Stash in Finder", #selector(revealStash))
        }

        guard let target = targetRug else { return finish(menu) }
        menu.addItem(.separator())
        let section = NSMenuItem(title: multiple ? "This rug: \(target.style.name)" : target.style.name, action: nil, keyEquivalent: "")
        section.isEnabled = false
        section.image = swatches[target.style.id]
        menu.addItem(section)
        addItem(menu, target.sim.isFolded ? "Lay It Flat" : "Lift It", #selector(toggleLift))
        addItem(menu, "Sweep the Desktop Under It…", #selector(sweepDesktop))

        let styleMenu = NSMenu()
        for style in RugStyle.all {
            let entry = NSMenuItem(title: style.name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.id
            entry.image = swatches[style.id]
            entry.state = style.id == target.style.id ? .on : .off
            styleMenu.addItem(entry)
        }
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let sizeMenu = NSMenu()
        for size in RugSize.allCases {
            let entry = NSMenuItem(title: size.title, action: #selector(chooseSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = size.rawValue
            entry.state = size == target.size ? .on : .off
            sizeMenu.addItem(entry)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        addItem(menu, "Straighten It", #selector(straighten))
        if multiple {
            addItem(menu, "Remove This Rug…", #selector(removeRug))
        }
        finish(menu)
    }

    private func finish(_ menu: NSMenu) {
        menu.addItem(.separator())
        let login = addItem(menu, "Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = NSMenuItem(title: "Quit Under the Rug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    /// Tiny rugs for the style menu, drawn by the same code as the real thing.
    private func renderSwatches() {
        DispatchQueue.global(qos: .utility).async {
            var result: [String: NSImage] = [:]
            for style in RugStyle.all {
                if let image = TextureFactory.rugImage(style: style, width: 108, height: 72) {
                    result[style.id] = NSImage(cgImage: image, size: NSSize(width: 36, height: 24))
                }
            }
            DispatchQueue.main.async { self.swatches = result }
        }
    }

    /// A small template rug for the menu bar: a frame with a medallion and fringe on both ends.
    static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: NSRect(x: 5, y: 3.5, width: 12, height: 9), xRadius: 1, yRadius: 1)
            body.lineWidth = 1.4
            body.stroke()
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: 11, y: 5.6))
            diamond.line(to: NSPoint(x: 13.4, y: 8))
            diamond.line(to: NSPoint(x: 11, y: 10.4))
            diamond.line(to: NSPoint(x: 8.6, y: 8))
            diamond.close()
            diamond.fill()
            let fringe = NSBezierPath()
            fringe.lineWidth = 0.9
            for y in stride(from: 4.6, through: 11.5, by: 1.7) {
                fringe.move(to: NSPoint(x: 2.2, y: y))
                fringe.line(to: NSPoint(x: 4.6, y: y))
                fringe.move(to: NSPoint(x: 17.4, y: y))
                fringe.line(to: NSPoint(x: 19.8, y: y))
            }
            fringe.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
