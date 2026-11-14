import AppKit
import NaturalLanguage
import Observation
import PerchCore
import UniformTypeIdentifiers
import UserNotifications

enum NotchMode { case closed, open, activity }

enum Page: String, CaseIterable, Identifiable {
    case workspace = "Workspace", week = "Week", insights = "Insights", customize = "Customize", clips = "Clips"
    var id: String { rawValue }
    static let tabs: [Page] = [.workspace, .week, .insights, .customize]
}

struct NotchGeometry: Equatable {
    enum Style {
        /// A real notch: the shape sits over it.
        case physical
        /// A monitor without one: Perch draws its own at the top of the menu bar.
        case drawn
        /// Nothing drawn while idle. The middle of the top edge opens the workspace.
        case edge
    }

    var style = Style.physical
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32
    /// Macs without a notch open below the menu bar.
    var topInset: CGFloat = 0
    var openWidth: CGFloat = 860
    var openHeight: CGFloat = 400
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var undoTask: UUID?
}

extension UTType {
    static let perchCard = UTType(exportedAs: "dev.pitis.perch.card")
}

/// View state shared by the notch and the dashboard.
@Observable
final class NotchUI {
    var mode = NotchMode.closed
    var page = Page.workspace
    var geometry = NotchGeometry()
    /// The current screen is showing a full-screen app.
    var fullscreen = false
    var greeting = false
    var activity: TaskItem?
    var selectedDay: String
    /// Option-N asked for the cursor. The composer takes it as soon as it exists, which may be after this is set.
    var wantsComposerFocus = false
    var toast: Toast?
    var editingTask: UUID?
    var hoveredTask: UUID?
    var swipingTask: UUID?
    var swipeOffset: CGFloat = 0
    var draggingTask: UUID?
    var draggingCard: CardConfig.Kind?

    init(today: String) {
        selectedDay = today
    }
}

@Observable
final class AppHub {
    let workspace: Workspace
    let ui: NotchUI
    let clips = ClipsManager()
    let calendar = CalendarService()
    let speech = SpeechService()
    let sync: RemindersSync
    /// nil until first read. Only re-read by `refreshPermissions` and after asking, so it can be out of date otherwise.
    var notificationStatus: UNAuthorizationStatus?

    @ObservationIgnored weak var notch: NotchController?
    @ObservationIgnored var openSettingsWindow: () -> Void = {}
    @ObservationIgnored var openSetupWindow: () -> Void = {}
    @ObservationIgnored var openDashboardWindow: () -> Void = {}

    @ObservationIgnored private let store: Store?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var activityQueue: [UUID] = []
    @ObservationIgnored private var lastSyncedTasks: [TaskItem] = []
    @ObservationIgnored private var lastLayoutSettings: (String?, Bool)?
    @ObservationIgnored private var askedForNotifications = UserDefaults.standard.bool(forKey: "askedForNotifications")

    /// A nil store never touches the disk. Snapshot mode uses that.
    init(workspace: Workspace, store: Store?) {
        self.workspace = workspace
        self.store = store
        ui = NotchUI(today: workspace.today)
        sync = RemindersSync(workspace: workspace)
    }

    var theme: Theme { Theme(bw: workspace.data.settings.blackAndWhite) }

    func start() {
        workspace.onChange = { [weak self] in self?.dataChanged() }
        lastSyncedTasks = workspace.data.tasks
        lastLayoutSettings = (workspace.data.settings.showOnScreen, workspace.data.settings.notchOnMonitors)
        clearSystemNotifications()

        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.ui.selectedDay = self.workspace.today
            self.calendar.refresh()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.workspace.focusPause()
            self?.saveNow()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notch?.relayout()
            self?.handleWake()
        }

        clips.start(workspace: workspace)
        clips.onGone = { [weak self] clip in self?.show(Toast(text: "“\(clip.title)” was moved or deleted, so its clip is gone.")) }
        calendar.start(workspace: workspace)
        sync.start()
        handleWake()
    }

    private func dataChanged() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)

        rearmWake()

        let settings = workspace.data.settings
        if lastLayoutSettings?.0 != settings.showOnScreen || lastLayoutSettings?.1 != settings.notchOnMonitors {
            lastLayoutSettings = (settings.showOnScreen, settings.notchOnMonitors)
            notch?.relayout()
        }

        if workspace.data.tasks != lastSyncedTasks {
            lastSyncedTasks = workspace.data.tasks
            sync.schedule()
        }

        if !askedForNotifications, workspace.data.tasks.contains(where: { $0.reminderAt != nil }) {
            requestNotifications()
        }
    }

    /// macOS only shows its prompt the first time. After that this just reports what's already set.
    func requestNotifications() {
        askedForNotifications = true
        UserDefaults.standard.set(true, forKey: "askedForNotifications")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error { NSLog("Perch: asking for notifications failed: %@", "\(error)") }
            self?.refreshNotificationStatus()
        }
    }

    /// What the setup window shows, which can change in System Settings. It calls this when it opens and when
    /// Perch comes back to the front with it open.
    func refreshPermissions() {
        calendar.refresh()
        if clips.screenshotWatch == .refused { clips.updateScreenshotWatcher() }
        refreshNotificationStatus()
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.notificationStatus = settings.authorizationStatus }
        }
    }

    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func saveNow() {
        saveWork?.cancel()
        guard let store else { return }
        do {
            try store.save(workspace.data)
        } catch {
            show(Toast(text: "Couldn't save: \(error.localizedDescription)"))
        }
    }

    /// Replaces all planner data with `backup`. Returns where the data it replaced was kept.
    func restoreBackup(_ backup: AppData) throws -> URL {
        guard let store else { throw CocoaError(.featureUnsupported) }
        let copy = try workspace.restore(backup, keepingCopyIn: store)
        ui.editingTask = nil // the task may not exist in the backup, and an open editor keeps the panel from closing
        clips.updateScreenshotWatcher() // the restored settings take effect now, not at the next launch
        calendar.refresh()
        return copy
    }

    func prepareForQuit() {
        workspace.focusPause()
        saveNow()
        clips.save()
        scheduleSystemNotifications()
    }

    // MARK: Wake-ups

    /// One timer aimed at the next thing due, so nothing polls while the notch sits idle.
    private func rearmWake() {
        wakeTimer?.invalidate()
        guard let next = workspace.nextWake() else { return }
        let timer = Timer(fire: max(next, Date().addingTimeInterval(0.1)), interval: 0, repeats: false) { [weak self] _ in
            self?.handleWake()
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    private func handleWake() {
        if workspace.focusTick(), workspace.data.settings.chime {
            NSSound(named: "Hero")?.play()
        }
        let due = workspace.takeDueReminders()
        if !due.isEmpty {
            activityQueue.append(contentsOf: due.map(\.id))
            if workspace.data.settings.chime { NSSound(named: "Glass")?.play() }
            presentNextActivity()
        }
        rearmWake()
    }

    private func presentNextActivity() {
        guard ui.activity == nil else { return }
        while !activityQueue.isEmpty {
            let id = activityQueue.removeFirst()
            if let task = workspace.task(id), !task.isCompleted {
                ui.activity = task
                notch?.presentActivity()
                return
            }
        }
        notch?.activityEnded()
    }

    func snoozeActivity() {
        guard let task = ui.activity else { return }
        workspace.snooze(task.id)
        ui.activity = nil
        presentNextActivity()
    }

    func completeActivity() {
        guard let task = ui.activity else { return }
        workspace.setCompleted(task.id, true)
        ui.activity = nil
        presentNextActivity()
    }

    // MARK: Actions

    /// Adds a task, then lets the on-device model fill in what the parser couldn't get from the text (see `classify`).
    @discardableResult
    func addTask(_ text: String, day: String?) -> TaskItem? {
        guard let task = workspace.add(text, defaultDay: day) else { return nil }
        classify(task, defaultDay: day)
        return task
    }

    /// On Apple Intelligence Macs, a new task without a priority or project gets them from the on-device model. One in a
    /// language the parser doesn't read, such as German or Japanese, and with no date the parser found, also gets the
    /// model's reading of its date, with those words taken out of the title (see `Workspace.applySchedule`).
    func classify(_ task: TaskItem, defaultDay: String?) {
        let suggest = task.priority == .none || task.project == nil
        let foreign = ![NLLanguage.english, .romanian].contains(NLLanguageRecognizer.dominantLanguage(for: task.title))
        let undated = foreign && task.day == defaultDay && task.reminderAt == nil && task.deadline == nil && task.repeatRule == nil
        guard workspace.data.settings.autoClassify, suggest || undated, AutoClassifier.isAvailable else { return }
        let projects = workspace.projects
        Task { @MainActor [workspace] in
            guard let guess = await AutoClassifier.classify(task.title, projects: projects) else { return }
            workspace.update(task.id) { current in
                if current.priority == .none, let priority = guess.priority { current.priority = priority }
                if current.project == nil, let project = guess.project { current.project = project }
            }
            if undated { workspace.applySchedule(task.id, title: guess.title, when: guess.when, ifUnchangedSince: task) }
        }
    }

    func deleteTask(_ id: UUID) {
        guard let title = workspace.task(id)?.title else { return }
        if ui.editingTask == id { ui.editingTask = nil }
        workspace.delete(id)
        show(Toast(text: "Deleted “\(title)”", undoTask: id))
    }

    func show(_ toast: Toast) {
        ui.toast = toast
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.ui.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func dropTask(on day: String?, before target: UUID?) -> Bool {
        guard let id = ui.draggingTask else { return false }
        workspace.move(id, to: day, before: target)
        ui.draggingTask = nil
        return true
    }

    func dropCard(on target: CardConfig.Kind) -> Bool {
        guard let kind = ui.draggingCard else { return false }
        ui.draggingCard = nil
        var cards = workspace.data.settings.cards
        guard let from = cards.firstIndex(where: { $0.kind == kind }),
              let to = cards.firstIndex(where: { $0.kind == target }), from != to else { return true }
        let card = cards.remove(at: from)
        cards.insert(card, at: to)
        workspace.data.settings.cards = cards
        return true
    }

    // MARK: Reminders while quit

    /// The notch can't ring if the app isn't running, so upcoming reminders go to macOS when it quits.
    /// They're withdrawn on launch, so nothing ever rings twice.
    private func scheduleSystemNotifications() {
        let center = UNUserNotificationCenter.current()
        let cal = workspace.calendar
        let group = DispatchGroup()
        for task in workspace.upcomingReminders.prefix(60) {
            guard let at = task.effectiveReminder else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.sound = .default
            let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            group.enter()
            center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)) { _ in group.leave() }
        }
        _ = group.wait(timeout: .now() + 1)
    }

    private func clearSystemNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
