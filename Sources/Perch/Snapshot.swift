import AppKit
import PerchCore
import SwiftUI

/// `Perch --snapshot <folder>` renders each screen to a PNG using sample data and writes nothing else to disk.
/// It's how the UI gets looked at without Screen Recording permission.
enum Snapshot {
    @MainActor static func run(to folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        for bw in [false, true] {
            let hub = sampleHub(blackAndWhite: bw)
            let suffix = bw ? "-bw" : ""
            for page in Page.allCases {
                hub.ui.mode = .open
                hub.ui.page = page
                render(hub, name: "\(page.rawValue.lowercased())\(suffix)", folder: folder)
            }
        }

        let hub = sampleHub(blackAndWhite: false)
        hub.ui.mode = .open
        hub.ui.editingTask = hub.workspace.open(on: hub.workspace.today).first?.id
        render(hub, name: "editor", folder: folder)
        hub.ui.editingTask = nil

        hub.ui.mode = .activity
        hub.ui.activity = hub.workspace.data.tasks.first { $0.reminderAt != nil }
        render(hub, name: "activity", folder: folder, size: CGSize(width: 480, height: 170))
        hub.ui.activity = nil

        hub.ui.mode = .closed
        render(hub, name: "compact-timer", folder: folder, size: CGSize(width: 480, height: 50))
        hub.workspace.focusPause()
        render(hub, name: "compact-paused", folder: folder, size: CGSize(width: 480, height: 50))
        hub.workspace.focusStop()
        hub.ui.greeting = true
        render(hub, name: "compact-greeting", folder: folder, size: CGSize(width: 480, height: 50))

        renderView(SettingsView().environment(hub), name: "settings", folder: folder, size: CGSize(width: 560, height: 1400))
        renderView(Image(nsImage: PerchedBird.menuBarImage).renderingMode(.template).foregroundStyle(.white)
                       .frame(width: 60, height: 24).background(.black),
                   name: "menubar", folder: folder, size: CGSize(width: 60, height: 24))

        // Exactly 1024 pixels whatever the screen's scale, for `make icon`.
        let icon = ImageRenderer(content: AppIconArt())
        icon.scale = 1
        if let image = icon.cgImage {
            let file = URL(fileURLWithPath: folder).appendingPathComponent("app-icon.png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
        }
    }

    private static func render(_ hub: AppHub, name: String, folder: String, size: CGSize = CGSize(width: 924, height: 440)) {
        renderView(NotchRootView().environment(hub).background(Color(hex: 0x4C7FA8)), name: name, folder: folder, size: size)
    }

    private static func renderView<V: View>(_ view: V, name: String, folder: String, size: CGSize) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let file = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    private static func sampleHub(blackAndWhite: Bool) -> AppHub {
        let ws = Workspace()
        ws.data.settings.blackAndWhite = blackAndWhite
        ws.data.settings.calendarEnabled = true
        let today = ws.today
        let cal = ws.calendar

        let prep = ws.add("Prep slides for design review #work !high", defaultDay: today)!
        ws.update(prep.id) {
            $0.focusedSeconds = 45 * 60
            $0.steps = [Step(title: "Outline", done: true), Step(title: "Charts"), Step(title: "Rehearse")]
        }
        ws.add("Pay electricity bill at 6:30pm #home", defaultDay: today)
        ws.add("Call mom at 5pm", defaultDay: today)
        ws.add("Gym every weekday #health", defaultDay: today)
        ws.add("Send invoice by friday", defaultDay: today)
        let done = ws.add("Reply to Sam", defaultDay: today)!
        ws.setCompleted(done.id, true)
        ws.add("Old thing", defaultDay: Day.adding(-2, to: today, calendar: cal))
        ws.add("Plan team offsite", defaultDay: nil)
        ws.add("Book flights", defaultDay: nil)
        ws.add("Water the plants", defaultDay: Day.adding(1, to: today, calendar: cal))
        ws.setNote("Lead the landing page with the notch\nIdea: a weekly review every Friday\nAsk Sam about the API", on: today)

        // Seven days of history so Insights has something to show.
        let counts = [(4, 5), (6, 7), (2, 4), (7, 8), (3, 3), (5, 6)]
        let titles = ["Answer email", "Review the PR", "Grocery run", "Draft the blog post", "Fix the login bug", "Call the bank", "Stretch", "Plan the sprint"]
        for (offset, count) in counts.enumerated() {
            let day = Day.adding(offset - 6, to: today, calendar: cal)
            for i in 0..<count.1 {
                let task = ws.add(titles[(offset + i) % titles.count], defaultDay: day)!
                if i < count.0 {
                    ws.update(task.id) { $0.completedAt = Day.at(day, hour: 10 + i, minute: 0, calendar: cal) }
                } else {
                    ws.update(task.id) { $0.completedAt = Day.at(day, hour: 20, minute: 0, calendar: cal) }
                }
            }
            let start = Day.at(day, hour: 9, minute: 30, calendar: cal)
            ws.data.sessions.append(FocusSession(taskId: nil, taskTitle: nil, segments: [FocusSegment(start: start, end: start.addingTimeInterval(TimeInterval(1800 + offset * 900)))]))
        }

        ws.focusStart(taskId: prep.id, minutes: 45)

        let hub = AppHub(workspace: ws, store: nil)
        hub.calendar.events = [
            EventRow(id: "1", title: "Design review", start: Day.at(today, hour: 15, minute: 0, calendar: cal), end: Day.at(today, hour: 15, minute: 30, calendar: cal), isAllDay: false, location: nil, calendarName: "Work"),
            EventRow(id: "2", title: "1:1 with Sam", start: Day.at(today, hour: 16, minute: 30, calendar: cal), end: Day.at(today, hour: 17, minute: 0, calendar: cal), isAllDay: false, location: "Room 3", calendarName: "Work"),
        ]
        hub.clips.loadSample()
        return hub
    }
}

extension ClipsManager {
    fileprivate func loadSample() {
        addSampleText("Launch email\n• Lead with the notch\n• Add the demo video")
        addSampleText("https://example.com/a-link-someone-copied")
    }
}
