import AppKit
import PerchCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hub: AppHub!
    private var notch: NotchController!
    private var mcpSocket: MCPSocketServer?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = snapshotDirectory {
            Snapshot.run(to: dir)
            NSApp.terminate(nil)
            return
        }

        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if !bundleId.isEmpty, NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count > 1 {
            NSApp.terminate(nil)
            return
        }

        try? FileManager.default.createDirectory(at: Store.supportDirectory, withIntermediateDirectories: true)
        let store = Store(url: Store.supportDirectory.appendingPathComponent("store.json"))
        var recoveredFrom: URL?
        let data: AppData
        switch store.load() {
        case .fresh: data = AppData()
        case .loaded(let loaded): data = loaded
        case .recovered(let loaded, let aside):
            data = loaded
            recoveredFrom = aside
        }

        let workspace = Workspace(data: data)
        workspace.recoverFocusAfterLaunch()
        hub = AppHub(workspace: workspace, store: store)
        hub.openSettingsWindow = { [weak self] in self?.showSettings() }
        hub.openDashboardWindow = { [weak self] in self?.showDashboard() }

        notch = NotchController(hub: hub)
        hub.notch = notch
        notch.start()
        hub.start()

        let mcp = MCPServer(workspace: workspace)
        mcpSocket = MCPSocketServer(path: MCPSocket.path) { line in mcp.handle(line: line) }
        mcpSocket?.start()

        installStatusItem()

        if let recoveredFrom {
            let alert = NSAlert()
            alert.messageText = "Perch couldn't read its data file"
            alert.informativeText = "It restored the latest backup. The unreadable file was kept at \(recoveredFrom.path)."
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub?.prepareForQuit()
    }

    private var snapshotDirectory: String? {
        guard let i = arguments.firstIndex(of: "--snapshot"), arguments.count > i + 1 else { return nil }
        return arguments[i + 1]
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = PerchedBird.menuBarImage
        let menu = NSMenu()
        menu.addItem(item("Open Workspace", #selector(openWorkspace), key: ""))
        menu.addItem(item("Open Dashboard", #selector(openDashboard), key: "d"))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Perch", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openWorkspace() { notch.open(page: .workspace, takeKeyboard: true) }
    @objc private func openDashboard() { showDashboard() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showSettings() {
        notch.close()
        if settingsWindow == nil {
            let window = makeWindow(title: "Perch Settings", size: NSSize(width: 560, height: 680),
                                    view: SettingsView().environment(hub))
            settingsWindow = window
        }
        present(settingsWindow!)
    }

    private func showDashboard() {
        notch.close()
        if dashboardWindow == nil {
            let window = makeWindow(title: "Perch", size: NSSize(width: 1120, height: 680),
                                    view: DashboardView().environment(hub))
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            dashboardWindow = window
        }
        present(dashboardWindow!)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
