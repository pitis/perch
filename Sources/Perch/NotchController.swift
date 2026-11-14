import AppKit
import Carbon.HIToolbox
import PerchCore
import SwiftUI

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // fullScreenAuxiliary keeps it reachable over full-screen apps, where the top edge still opens it.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // The default would push the window down below the menu bar and away from the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension EnvironmentValues {
    /// Set only on the notch panel's host, for what that non-activating panel needs. Snapshots render with false.
    @Entry var inNotch = false
}

/// Option-N. Carbon's hot keys need no Accessibility permission, unlike a key event monitor.
private final class HotKey {
    static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5052_4348), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class NotchController {
    private let hub: AppHub
    let panel = NotchPanel()
    private var screen = NSScreen.main ?? NSScreen.screens[0]
    private var hotKey: HotKey?
    private var monitors: [Any] = []
    /// Windows that join every Space except full-screen ones, so `isOnActiveSpace` reveals a full-screen app.
    private var probes: [(screen: CGDirectDisplayID, window: NSWindow)] = []
    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    /// Opened with the keyboard, so it stays until dismissed rather than closing when the pointer wanders off.
    private var stickyKeyboard = false
    private var dragCountAtMouseDown = 0
    private var swipeAccumulated: CGFloat = 0

    private var ui: NotchUI { hub.ui }
    private var settings: AppSettings { hub.workspace.data.settings }

    init(hub: AppHub) {
        self.hub = hub
    }

    func start() {
        let host = NSHostingView(rootView: NotchRootView().environment(hub).environment(\.inNotch, true))
        host.sizingOptions = []
        panel.contentView = host
        panel.ignoresMouseEvents = true
        rebuildProbes()
        relayout()
        panel.orderFrontRegardless()

        HotKey.action = { [weak self] in self?.toggleFromKeyboard() }
        hotKey = HotKey()
        installMonitors()
        installObservers()

        ui.greeting = true
        relayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.ui.greeting = false
            self?.relayoutSoon()
        }
    }

    // MARK: Geometry

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func geometry(for screen: NSScreen) -> NotchGeometry {
        var g = NotchGeometry()
        let frame = screen.frame
        g.openWidth = min(860, frame.width - 32)
        g.openHeight = min(400, frame.height - 80)
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 24)

        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // Measured every time: the point size of the notch changes with scaled resolutions such as More Space.
            g.style = .physical
            g.notchWidth = frame.width - left.width - right.width
            g.notchHeight = screen.safeAreaInsets.top
        } else if CGDisplayIsBuiltin(displayID(screen)) != 0 {
            g.style = .edge
            g.topInset = menuBar
            g.notchHeight = 28
        } else {
            g.style = settings.notchOnMonitors ? .drawn : .edge
            g.notchHeight = min(menuBar, 34)
        }
        return g
    }

    func relayout() {
        chooseScreen(at: NSEvent.mouseLocation)
        let g = geometry(for: screen)
        if ui.geometry != g { ui.geometry = g }
        updateFullscreen()
        applyFrame(for: ui.mode)
    }

    private func relayoutSoon() {
        shrinkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyFrame(for: self.ui.mode)
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
    }

    private func chooseScreen(at point: NSPoint) {
        var target = screen
        if let name = settings.showOnScreen, let pinned = NSScreen.screens.first(where: { $0.localizedName == name }) {
            target = pinned
        } else if !NSScreen.screens.contains(screen) || !NSMouseInRect(point, screen.frame, false) {
            target = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? screen
        }
        if target != screen { screen = target }
    }

    private func frame(for mode: NotchMode) -> NSRect {
        let g = ui.geometry
        let padding: CGFloat = 32
        let size: CGSize
        switch mode {
        case .closed:
            size = CGSize(width: g.notchWidth + 240, height: g.topInset + g.notchHeight + 6)
        case .activity:
            size = CGSize(width: max(g.notchWidth + 40, ActivityCard.width) + padding * 2, height: g.topInset + g.notchHeight + ActivityCard.height + padding)
        case .open:
            size = CGSize(width: g.openWidth + padding * 2, height: g.topInset + g.openHeight + padding)
        }
        let s = screen.frame
        return NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height, width: size.width, height: size.height)
    }

    private func applyFrame(for mode: NotchMode) {
        let target = frame(for: mode)
        if panel.frame != target { panel.setFrame(target, display: true) }
    }

    private func hotZone() -> NSRect {
        let g = ui.geometry
        let s = screen.frame
        if g.style == .edge || (g.style == .drawn && ui.fullscreen) {
            return NSRect(x: s.midX - 130, y: s.maxY - 3, width: 260, height: 3)
        }
        return NSRect(x: s.midX - g.notchWidth / 2 - 10, y: s.maxY - g.notchHeight - 1, width: g.notchWidth + 20, height: g.notchHeight + 1)
    }

    private func rebuildProbes() {
        probes.forEach { $0.window.orderOut(nil) }
        probes = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: NSRect(origin: screen.frame.origin, size: CGSize(width: 2, height: 2)),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return (displayID(screen), window)
        }
    }

    private func updateFullscreen() {
        let id = displayID(screen)
        let isFullscreen = probes.first { $0.screen == id }.map { !$0.window.isOnActiveSpace } ?? false
        if ui.fullscreen != isFullscreen { ui.fullscreen = isFullscreen }
    }

    // MARK: Opening and closing

    func open(page: Page? = nil, takeKeyboard: Bool) {
        closeWork?.cancel()
        hoverWork?.cancel()
        shrinkWork?.cancel()
        hoverWork = nil
        if let page { ui.page = page }
        if takeKeyboard { stickyKeyboard = true }
        applyFrame(for: .open)
        panel.ignoresMouseEvents = false
        ui.mode = .open
        hub.calendar.refresh()
        if takeKeyboard {
            panel.makeKeyAndOrderFront(nil)
            ui.wantsComposerFocus = true
        } else {
            panel.orderFrontRegardless()
        }
    }

    func close() {
        guard ui.mode == .open else { return }
        closeWork?.cancel()
        closeWork = nil
        stickyKeyboard = false
        ui.editingTask = nil
        ui.pickingDay = nil
        ui.wantsComposerFocus = false
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            // Ordering out hands the keyboard straight back to whatever had it before.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        let next: NotchMode = ui.activity == nil ? .closed : .activity
        ui.mode = next
        panel.ignoresMouseEvents = next == .closed
        relayoutSoon()
    }

    func toggleFromKeyboard() {
        if ui.mode == .open {
            close()
        } else {
            chooseScreen(at: NSEvent.mouseLocation)
            let g = geometry(for: screen)
            if ui.geometry != g { ui.geometry = g }
            updateFullscreen()
            open(page: .workspace, takeKeyboard: true)
        }
    }

    func presentActivity() {
        relayout()
        guard ui.mode != .open else { return } // the open panel shows it as a banner
        shrinkWork?.cancel()
        ui.mode = .activity
        applyFrame(for: .activity)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    func activityEnded() {
        guard ui.mode == .activity else { return }
        ui.mode = .closed
        panel.ignoresMouseEvents = true
        relayoutSoon()
    }

    // MARK: Pointer and keyboard

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        add(NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] event in
            self?.pointerMoved(dragging: event.type == .leftMouseDragged)
        })
        add(NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            self?.pointerMoved(dragging: event.type == .leftMouseDragged)
            return event
        })
        add(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            self.dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            if self.ui.mode == .open { self.close() }
        })
        add(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Escape), self.ui.mode == .open, event.window === self.panel else { return event }
            if self.ui.pickingDay != nil {
                self.ui.pickingDay = nil
            } else if self.ui.editingTask != nil {
                self.ui.editingTask = nil
            } else {
                self.close()
            }
            return nil
        })
        add(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleSwipe(event) ?? event
        })
    }

    private func add(_ monitor: Any?) {
        if let monitor { monitors.append(monitor) }
    }

    private func pointerMoved(dragging: Bool) {
        let point = NSEvent.mouseLocation
        if !dragging, NSEvent.pressedMouseButtons == 0 {
            // A cancelled drag never reaches a drop handler, so clear it here.
            if ui.draggingTask != nil { ui.draggingTask = nil }
            if ui.draggingCard != nil { ui.draggingCard = nil }
        }
        switch ui.mode {
        case .closed, .activity:
            let before = screen
            chooseScreen(at: point)
            if screen != before { relayout() }
            let zone = hotZone()
            guard point.x >= zone.minX, point.x <= zone.maxX, point.y >= zone.minY, point.y <= zone.maxY + 1 else {
                hoverWork?.cancel()
                hoverWork = nil
                return
            }
            if dragging {
                // Only a real drag session changes this pasteboard; dragging a window to the top doesn't.
                if NSPasteboard(name: .drag).changeCount != dragCountAtMouseDown {
                    open(page: .clips, takeKeyboard: false)
                }
                return
            }
            guard ui.mode == .closed, hoverWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.hoverWork = nil
                self?.open(takeKeyboard: false)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        case .open:
            let f = panel.frame
            let g = ui.geometry
            let shape = NSRect(x: f.midX - g.openWidth / 2 - 14, y: f.maxY - g.topInset - g.openHeight - 14,
                               width: g.openWidth + 28, height: g.topInset + g.openHeight + 15)
            if shape.contains(point) || (point.y >= shape.maxY - 1 && point.x >= shape.minX && point.x <= shape.maxX) {
                closeWork?.cancel()
                closeWork = nil
            } else if closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    if self.mayAutoClose { self.close() }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }
    }

    private var mayAutoClose: Bool {
        guard !stickyKeyboard, !ui.hasComposerDraft, ui.editingTask == nil, ui.pickingDay == nil, ui.draggingTask == nil,
              ui.draggingCard == nil,
              hub.speech.activeOwner == nil, NSEvent.pressedMouseButtons == 0,
              RunLoop.current.currentMode != .eventTracking else { return false }
        // Don't vanish mid-sentence just because the pointer moved.
        return !(panel.isKeyWindow && panel.firstResponder is NSTextView)
    }

    /// Two-finger swipe left on a task deletes it. Scroll events are watched here because SwiftUI has no swipe
    /// gesture on macOS, and a drag gesture would fight the row's drag-to-reorder.
    private func handleSwipe(_ event: NSEvent) -> NSEvent? {
        switch event.phase {
        case .began:
            swipeAccumulated = 0
            if ui.swipingTask != nil { endSwipe(delete: false) }
            return event
        case .changed:
            let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            if ui.swipingTask == nil {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5, let hovered = ui.hoveredTask else { return event }
                ui.swipingTask = hovered
            }
            swipeAccumulated += delta
            ui.swipeOffset = min(0, swipeAccumulated)
            return nil
        case .ended, .cancelled:
            guard ui.swipingTask != nil else { return event }
            endSwipe(delete: ui.swipeOffset < -90)
            return nil
        default:
            return ui.swipingTask == nil ? event : nil
        }
    }

    private func endSwipe(delete: Bool) {
        let id = ui.swipingTask
        withAnimation(.easeOut(duration: 0.18)) {
            ui.swipeOffset = 0
            ui.swipingTask = nil
        }
        if delete, let id { hub.deleteTask(id) }
    }

    private func installObservers() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildProbes()
            self?.relayout()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateFullscreen()
            // The new Space may not have settled yet when this fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.updateFullscreen() }
        }
    }
}
