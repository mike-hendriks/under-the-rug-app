import AppKit
import Metal
import ServiceManagement
import simd

/// Owns the rug window, the stash of hidden files and the menu bar item.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: RugWindow!
    private var rugView: RugView!
    private var statusItem: NSStatusItem!
    private let stash = Stash()
    private var passthroughTimer: Timer?
    private var swatches: [String: NSImage] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        stash.load()
        guard let device = MTLCreateSystemDefaultDevice(), let screen = NSScreen.screens.first else {
            fail("This Mac has no Metal GPU, so the rug can't be drawn.")
            return
        }
        window = RugWindow(screen: screen)
        let frame = NSRect(origin: .zero, size: screen.frame.size)
        var center = Settings.center
        if let c = center, c.x < 0 || c.y < 0 || c.x > Float(frame.width) || c.y > Float(frame.height) { center = nil }
        do {
            rugView = try RugView(frame: frame, device: device, style: Settings.style, size: Settings.size,
                                  center: center, angle: Settings.angle)
        } catch {
            fail("The rug's shaders failed to load: \(error.localizedDescription)")
            return
        }
        window.contentView = rugView
        wireUpRug()
        rugView.items = stash.items
        window.orderFrontRegardless()

        setUpStatusItem()
        startPassthrough()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        renderSwatches()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let rugView else { return }
        Settings.center = rugView.sim.center
        Settings.angle = rugView.sim.angle
    }

    private func wireUpRug() {
        rugView.onShove = { [weak self] urls, position in self?.shove(urls, at: position) }
        rugView.onMoveItem = { [weak self] id, position in
            self?.stash.move(id, to: position)
            self?.refreshItems()
        }
        rugView.onOpenItem = { [weak self] id in
            guard let item = self?.stash.items.first(where: { $0.id == id }) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: item.stashedPath))
        }
        rugView.onNeedsValidation = { [weak self] in
            guard let self, self.stash.pruneMissing() else { return }
            self.refreshItems()
        }
        rugView.onSettled = { center, angle in
            Settings.center = center
            Settings.angle = angle
        }
        rugView.menuProvider = { [weak self] in
            let menu = NSMenu()
            self?.populate(menu)
            return menu
        }
    }

    private func refreshItems() {
        rugView.items = stash.items
    }

    // MARK: - Click-through

    /// The window covers the whole screen but only takes clicks (and file drops) over the rug.
    private func startPassthrough() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.updatePassthrough() }
        RunLoop.main.add(timer, forMode: .common)
        passthroughTimer = timer
    }

    private func updatePassthrough() {
        let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let wants = rugView.wantsMouse(at: p)
        if window.ignoresMouseEvents == wants {
            window.ignoresMouseEvents = !wants
        }
    }

    @objc private func screensChanged() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
        rugView.frame = NSRect(origin: .zero, size: screen.frame.size)
        rugView.keepOnScreen()
    }

    // MARK: - Stash actions

    private func shove(_ urls: [URL], at position: SIMD2<Float>) {
        let size = SIMD2(rugView.sim.width, rugView.sim.height)
        let result = stash.shove(urls, positions: Stash.spiral(count: urls.count, around: position, rugSize: size))
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
        let result = stash.shove(urls, positions: Stash.scatter(count: urls.count, offset: stash.items.count))
        refreshItems()
        rugView.rippleEverything()
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

    // MARK: - Rug actions

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let style = RugStyle.named(id)
        Settings.style = style
        rugView.setStyle(style)
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = RugSize(rawValue: raw) else { return }
        Settings.size = size
        rugView.setSize(size)
    }

    @objc private func toggleLift() { rugView.toggleLift() }
    @objc private func straighten() { rugView.straighten() }
    @objc private func bringBack() { rugView.bringBack() }

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
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = stash.items
        let header = NSMenuItem(title: items.isEmpty ? "Nothing under the rug yet" : "Under the rug (\(items.count))", action: nil, keyEquivalent: "")
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

        menu.addItem(.separator())
        addItem(menu, rugView.isLifted ? "Lay the Rug Flat" : "Lift the Rug", #selector(toggleLift))
        addItem(menu, "Sweep the Desktop Under the Rug…", #selector(sweepDesktop))

        menu.addItem(.separator())
        let styleMenu = NSMenu()
        for style in RugStyle.all {
            let entry = NSMenuItem(title: style.name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.id
            entry.image = swatches[style.id]
            entry.state = style.id == rugView.style.id ? .on : .off
            styleMenu.addItem(entry)
        }
        let styleItem = NSMenuItem(title: "Rug", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let sizeMenu = NSMenu()
        for size in RugSize.allCases {
            let entry = NSMenuItem(title: size.title, action: #selector(chooseSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = size.rawValue
            entry.state = size == rugView.rugSize ? .on : .off
            sizeMenu.addItem(entry)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        addItem(menu, "Straighten the Rug", #selector(straighten))
        addItem(menu, "Bring the Rug Back", #selector(bringBack))

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
