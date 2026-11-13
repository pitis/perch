import AppKit
import PerchCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppHub.self) private var hub
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var backupMessage: String?

    var body: some View {
        @Bindable var ws = hub.workspace
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                Toggle("Chime for reminders and timers", isOn: $ws.data.settings.chime)
                LabeledContent("Open with") { Text("Hover the notch or press ⌥N").foregroundStyle(.secondary) }
            }

            Section {
                Picker("Show on", selection: $ws.data.settings.showOnScreen) {
                    Text("Follow the pointer").tag(String?.none)
                    ForEach(NSScreen.screens, id: \.localizedName) { screen in
                        Text(screen.localizedName).tag(String?.some(screen.localizedName))
                    }
                }
                Toggle("Notch on monitors", isOn: $ws.data.settings.notchOnMonitors)
            } header: {
                Text("Displays")
            } footer: {
                Text("With the monitor notch off, push the pointer to the middle of the screen's top edge to open Perch.")
            }

            Section {
                Toggle("Sync with Apple Reminders", isOn: Binding(get: { ws.data.settings.remindersSync }, set: hub.sync.setEnabled))
                if ws.data.settings.remindersSync {
                    LabeledContent("Status") {
                        HStack {
                            if let last = hub.sync.lastSync {
                                Text("Synced \(last.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                            }
                            Button("Sync now", action: hub.sync.syncNow).controlSize(.small)
                        }
                    }
                }
                if !hub.sync.statusText.isEmpty { Text(hub.sync.statusText).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("iPhone and Apple Watch")
            } footer: {
                Text("Keeps a Perch list in Reminders in step with your open tasks, both ways. iCloud carries it to your other devices, and reminders with a time ring there too.")
            }

            Section("Calendar") {
                if hub.calendar.isConnected {
                    LabeledContent("Apple Calendar") {
                        HStack {
                            Text("Connected, read-only").foregroundStyle(.secondary)
                            Button("Disconnect", action: hub.calendar.disconnect).controlSize(.small)
                        }
                    }
                } else {
                    LabeledContent("Apple Calendar") {
                        Button("Connect", action: hub.calendar.connect).controlSize(.small)
                    }
                }
            }

            Section {
                ForEach(AgentClient.all) { client in
                    AgentRow(client: client)
                }
                TryAsking()
            } header: {
                Text("AI agents")
            } footer: {
                Text("A local MCP server lets Claude add and update tasks, set reminders, write in your Notepad, read Insights and run the focus timer. It only listens on this Mac.")
            }

            Section("Clips") {
                Toggle("Keep copied items", isOn: $ws.data.settings.captureCopied)
                Toggle("Keep screenshots and screen recordings", isOn: Binding(
                    get: { ws.data.settings.captureScreenshots },
                    set: { value in
                        ws.data.settings.captureScreenshots = value
                        hub.clips.updateScreenshotWatcher()
                    }
                ))
                Text("Items that password managers mark as private are never kept. Turning on screenshots makes macOS ask once for access to your Desktop folder.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Fill in priority, project and dates", isOn: $ws.data.settings.autoClassify)
                    .disabled(!AutoClassifier.isAvailable)
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text(AutoClassifier.isAvailable
                    ? "New tasks get a priority and project from Apple's on-device model. When a task's date is in a language Perch doesn't read itself, such as German or Japanese, the model fills it in and takes those words out of the title. Anything you set yourself is left alone."
                    : "Needs macOS 26 with Apple Intelligence turned on.")
            }

            Section("Your data") {
                LabeledContent("Backup") {
                    HStack {
                        Button("Export JSON…", action: exportBackup).controlSize(.small)
                        Button("Restore…", action: restoreBackup).controlSize(.small)
                    }
                }
                if let backupMessage { Text(backupMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button("Allow notifications while Perch is closed…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 500)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Perch backup \(hub.workspace.today).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try hub.workspace.exportJSON().write(to: url, options: .atomic)
                backupMessage = "Saved to \(url.lastPathComponent)."
            } catch {
                backupMessage = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.lastPathComponent
            let backup: AppData
            do {
                backup = try Store.decoder.decode(AppData.self, from: Data(contentsOf: url))
            } catch is DecodingError {
                backupMessage = "Perch can't read \(name) as a backup. Nothing was changed."
                return
            } catch {
                backupMessage = "Couldn't open \(name). Nothing was changed. \(error.localizedDescription)"
                return
            }

            let alert = NSAlert()
            alert.messageText = "Replace your Perch data with this backup?"
            let now = hub.workspace.data
            alert.informativeText = """
                \(name) has \(backup.tasks.count) tasks and notes on \(backup.notes.count) days. You have \(now.tasks.count) tasks and notes on \(now.notes.count) days now.

                Your tasks, notes, focus history and settings will be replaced. Clips, Launch at login and Reminders sync aren't affected. If you sync with Reminders, the Perch list there is changed to match the backup. A copy of your current data is saved first.
                """
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            do {
                let copy = try hub.restoreBackup(backup)
                backupMessage = "Restored \(name). Your previous data is in \((copy.path as NSString).abbreviatingWithTildeInPath)."
            } catch {
                backupMessage = "Couldn't restore \(name), so nothing was changed. \(error.localizedDescription)"
            }
        }
    }
}

private struct AgentRow: View {
    let client: AgentClient
    @State private var connected = false
    @State private var errorText: String?
    @State private var restarting = false

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var running: NSRunningApplication? {
        client.bundleId.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(client.name) {
                HStack {
                    if connected, running != nil {
                        Button(restarting ? "Restarting…" : "Restart", action: restart)
                            .controlSize(.small).disabled(restarting)
                            .help("Reopens \(client.name) so it picks up Perch")
                    }
                    Button(connected ? "Disconnect" : "Connect", action: toggle).controlSize(.small)
                }
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { connected = AgentConfig.isConnected(client, home: home) }
    }

    private func toggle() {
        do {
            if connected {
                try AgentConfig.disconnect(client, home: home)
            } else {
                guard let executable = Bundle.main.executablePath else { return }
                try AgentConfig.connect(client, executable: executable, home: home)
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        connected = AgentConfig.isConnected(client, home: home)
    }

    private func restart() {
        guard let running, let path = client.appPath else { return }
        restarting = true
        running.terminate()
        let bundle = URL(fileURLWithPath: path)
        func reopenWhenGone(_ attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if running.isTerminated || attempts == 0 {
                    NSWorkspace.shared.openApplication(at: bundle, configuration: .init())
                    restarting = false
                } else {
                    reopenWhenGone(attempts - 1)
                }
            }
        }
        reopenWhenGone(20)
    }
}

private struct TryAsking: View {
    private static let prompts = [
        "Plan my afternoon: call mom at 5pm, gym after work !high",
        "What's overdue in Perch? Move it all to tomorrow",
        "Start a 25 minute focus timer on my top task",
        "How did my week go in Perch?",
    ]
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Try asking").font(.caption).foregroundStyle(.secondary)
            ForEach(Self.prompts, id: \.self) { prompt in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = prompt
                } label: {
                    HStack {
                        Text(prompt).font(.callout).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: copied == prompt ? "checkmark" : "doc.on.doc").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
