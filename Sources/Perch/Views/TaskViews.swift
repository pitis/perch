import AppKit
import PerchCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Tasks card

struct TasksCard: View {
    @Environment(AppHub.self) private var hub
    private enum Tab { case todo, completed, overdue }
    @State private var tab = Tab.todo
    @State private var selected: UUID?
    @FocusState private var listFocused: Bool
    /// Down from the composer let the list take focus.
    @State private var listEntered = false

    var body: some View {
        let theme = hub.theme
        let ws = hub.workspace
        let day = hub.ui.selectedDay
        let todo = ws.open(on: day)
        let done = ws.completed(on: day)
        let overdue = ws.overdue
        let current = tab == .overdue && overdue.isEmpty ? Tab.todo : tab
        let shown = current == .todo ? todo : current == .completed ? done : overdue

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title(day)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                DayNavigator()
            }
            HStack(spacing: 2) {
                tabButton("To do", todo.count, .todo, current)
                tabButton("Completed", done.count, .completed, current)
                if !overdue.isEmpty { tabButton("Overdue", overdue.count, .overdue, current) }
            }
            .padding(2)
            .background(theme.wash, in: RoundedRectangle(cornerRadius: 8))

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    switch current {
                    case .todo, .completed:
                        ForEach(shown) { TaskRow(task: $0, selected: selected == $0.id) }
                    case .overdue:
                        HStack {
                            Text("Carry unfinished work forward").font(.system(size: 11)).foregroundStyle(theme.ink2)
                            Spacer()
                            Button("Move all to today", action: ws.carryOverdueToToday)
                                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.vertical, 4)
                        ForEach(overdue) { TaskRow(task: $0, showsDay: true, selected: selected == $0.id) }
                    }
                }
            }
            .modifier(TaskListKeys(ids: shown.map(\.id), selected: $selected, focused: $listFocused, entered: listEntered,
                                   onExitUp: { hub.ui.wantsComposerFocus = true }))
            .onChange(of: listFocused) { if !listFocused { listEntered = false } }
            .frame(maxHeight: .infinity)
            .overlay {
                if current == .todo, todo.isEmpty {
                    Text(day == ws.today ? "Nothing planned yet.\nWhat's on your mind?" : "Nothing planned for this day.")
                        .font(.system(size: 12)).foregroundStyle(theme.ink2).multilineTextAlignment(.center)
                } else if current == .completed, done.isEmpty {
                    Text("Nothing finished yet.").font(.system(size: 12)).foregroundStyle(theme.ink2)
                }
            }
            .onDrop(of: [.plainText], isTargeted: nil) { _ in hub.dropTask(on: day, before: nil) }

            HStack(alignment: .bottom, spacing: 8) {
                Composer(defaultDay: day, autofocus: true, onDownArrow: shown.isEmpty ? nil : enterList)
                if current == .todo, todo.count > 1 {
                    Text("Drag to reorder").font(.system(size: 10)).foregroundStyle(theme.ink2).fixedSize().padding(.bottom, 7)
                }
            }
        }
    }

    /// Down in the empty composer moves into the list, so the arrow keys work without Keyboard navigation.
    private func enterList() {
        listEntered = true
        DispatchQueue.main.async { listFocused = true } // once the list has become focusable
        // If focus didn't move, a click must still not take it from the composer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !listFocused { listEntered = false } }
    }

    private func title(_ day: String) -> String {
        let ws = hub.workspace
        if day == ws.today { return "Today's tasks" }
        if day == Day.adding(1, to: ws.today, calendar: ws.calendar) { return "Tomorrow's tasks" }
        if day == Day.adding(-1, to: ws.today, calendar: ws.calendar) { return "Yesterday's tasks" }
        return Day.format(day, "EEE d MMM", calendar: ws.calendar)
    }

    private func tabButton(_ label: String, _ count: Int, _ value: Tab, _ current: Tab) -> some View {
        let theme = hub.theme
        return Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11, weight: current == value ? .semibold : .regular))
                Text("\(count)").font(.system(size: 11)).foregroundStyle(current == value ? theme.ink : theme.ink2)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            // A wash on the bar's wash, as dark as text on it can sit (PaletteTests).
            .background(current == value ? theme.wash : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current == value ? .isSelected : [])
    }
}

/// Keyboard use of a task list: Up and Down select, Space completes or reopens, Delete deletes with Undo.
/// One focus stop for the list, so the composer outside it never gets these keys. Fields inside the list (a rename,
/// the Week composer) and the open task editor are handled by `isTyping`.
private struct TaskListKeys: ViewModifier {
    @Environment(AppHub.self) private var hub
    let ids: [UUID]
    @Binding var selected: UUID?
    var focused: FocusState<Bool>.Binding
    /// Entered with Down from the composer. Otherwise a click mustn't take focus from the composer, so the list joins
    /// Tab only with Keyboard navigation on, like a button.
    var entered = false
    /// Up from the first task. Without it, Up stops there.
    var onExitUp: (() -> Void)?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .focusable(!ids.isEmpty, interactions: entered ? .edit : .activate)
                .focused(focused)
                // The selected row's outline shows where the keys act.
                .focusEffectDisabled()
                .onChange(of: focused.wrappedValue) {
                    // Clicks don't focus the list, so it only gets focus from the keyboard, and then selects a task.
                    selected = focused.wrappedValue ? selected ?? ids.first : nil
                }
                .onChange(of: selected) {
                    if let selected { proxy.scrollTo(selected) }
                }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.space) { act { hub.workspace.setCompleted($0.id, !$0.isCompleted) } }
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in act { hub.deleteTask($0.id) } }
        }
    }

    /// A rename, a field inside the list and the open task editor keep their keys.
    private var isTyping: Bool {
        hub.ui.editingTask != nil || NSApp.keyWindow?.firstResponder is NSTextView
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard !isTyping else { return .ignored }
        if offset < 0, selected == ids.first, let onExitUp {
            onExitUp()
            return .handled
        }
        selected = ListSelection.move(selected, by: offset, in: ids)
        return .handled
    }

    /// Completing, reopening or deleting takes the task out of this list, so the selection moves to its neighbour.
    private func act(_ action: (TaskItem) -> Void) -> KeyPress.Result {
        guard !isTyping, let id = selected, ids.contains(id), let task = hub.workspace.task(id) else { return .ignored }
        selected = ListSelection.afterRemoving(id, from: ids)
        action(task)
        return .handled
    }
}

// MARK: Row

struct TaskRow: View {
    @Environment(AppHub.self) private var hub
    let task: TaskItem
    var showsDay = false
    var compact = false
    /// Picked with the arrow keys.
    var selected = false

    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var dropTargeted = false
    @FocusState private var renameFocused: Bool

    // Week columns are dark whichever theme the coloured cards use.
    private var theme: Theme { compact ? Theme(bw: true) : hub.theme }
    private var focus: FocusTimer { hub.workspace.data.focus }
    private var isFocusing: Bool { focus.taskId == task.id && (focus.phase == .running || focus.phase == .paused) }
    private var isSwiping: Bool { hub.ui.swipingTask == task.id }

    var body: some View {
        ZStack(alignment: .trailing) {
            if isSwiping {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .background(hub.ui.swipeOffset < -90 ? Color.red : Color.red.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
            content
                .background(isFocusing ? theme.wash : .clear, in: RoundedRectangle(cornerRadius: 9))
                // An outline, not a fill, so the row's text keeps its contrast.
                .overlay { if selected { RoundedRectangle(cornerRadius: 9).stroke(theme.ink2, lineWidth: 1.5) } }
                .offset(x: isSwiping ? hub.ui.swipeOffset : 0)
        }
        .overlay(alignment: .top) {
            if dropTargeted { Rectangle().fill(theme.ink).frame(height: 2) }
        }
        .dottedDivider(theme.ink3)
        .contentShape(Rectangle())
        // One stop for VoiceOver that says what the task is. Its buttons stay inside, and the two common ones are actions.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(([task.title] + (task.isCompleted ? ["Done"] : []) + metaItems.map(\.spoken)).joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: task.isCompleted ? "Mark not done" : "Mark done") { hub.workspace.setCompleted(task.id, !task.isCompleted) }
        .accessibilityAction(named: "Delete") { hub.deleteTask(task.id) }
        .onHover { inside in
            hovering = inside
            if inside {
                hub.ui.hoveredTask = task.id
            } else if hub.ui.hoveredTask == task.id {
                hub.ui.hoveredTask = nil
            }
        }
        .onDrag {
            hub.ui.draggingTask = task.id
            return NSItemProvider(object: task.title as NSString)
        }
        .onDrop(of: [.plainText], isTargeted: $dropTargeted) { _ in
            hub.dropTask(on: task.isCompleted ? hub.ui.selectedDay : task.day, before: task.id)
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                hub.workspace.setCompleted(task.id, !task.isCompleted)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 15 : 17, weight: .light))
                    .foregroundStyle(task.isCompleted ? theme.ink2 : theme.ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onChange(of: renameFocused) { if !renameFocused { commitRename() } }
                } else {
                    Text(task.title)
                        .font(.system(size: 13))
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? theme.ink2 : theme.ink)
                        .lineLimit(2)
                        .onTapGesture(count: 2) { beginRename() }
                }
                meta
            }
            Spacer(minLength: 4)
            if !task.isCompleted, !compact || hovering || selected { actions }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func beginRename() {
        guard !task.isCompleted else { return }
        draft = task.title
        renaming = true
        DispatchQueue.main.async {
            hub.notch?.panel.makeKey()
            renameFocused = true
        }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != task.title {
            hub.workspace.update(task.id) { $0.title = title }
        }
    }

    private var meta: some View {
        let items = metaItems
        return Group {
            if !items.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 2) {
                    ForEach(items, id: \.text) { item in
                        HStack(spacing: 3) {
                            if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 9)) }
                            Text(item.text).font(.system(size: 10, weight: item.bold ? .semibold : .regular)).lineLimit(1)
                        }
                        .foregroundStyle(item.alert ? theme.alert : theme.ink2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.spoken)
                    }
                }
            }
        }
    }

    private struct Meta {
        var symbol: String?
        var text: String
        /// What VoiceOver says, since the symbol that tells a reminder from a deadline isn't read.
        var spoken: String
        var bold = false
        var alert = false
    }

    private var metaItems: [Meta] {
        var items: [Meta] = []
        let ws = hub.workspace
        if showsDay, let day = task.day {
            let label = Day.label(day, today: ws.today, calendar: ws.calendar)
            items.append(Meta(symbol: nil, text: label, spoken: "Planned for \(label)", alert: true))
        }
        if isFocusing {
            let state = focus.phase == .running ? "Focusing" : "Paused"
            items.append(Meta(symbol: nil, text: state, spoken: state))
        }
        if task.focusedSeconds >= 60 {
            items.append(Meta(symbol: nil, text: "Focused · \(task.focusedSeconds / 60) min", spoken: "Focused \(task.focusedSeconds / 60) minutes"))
        } else if let minutes = task.plannedMinutes {
            items.append(Meta(symbol: nil, text: "\(minutes) min", spoken: "\(minutes) minutes planned"))
        }
        if task.priority != .none {
            items.append(Meta(symbol: "flag.fill", text: task.priority.label, spoken: "\(task.priority.label) priority", bold: task.priority == .high))
        }
        if let project = task.project { items.append(Meta(symbol: Self.symbol(project: project), text: project, spoken: "Project \(project)")) }
        if !task.steps.isEmpty {
            let done = task.steps.filter(\.done).count
            items.append(Meta(symbol: "checklist", text: "\(done)/\(task.steps.count)", spoken: "\(done) of \(task.steps.count) steps done"))
        }
        if let at = task.effectiveReminder {
            let day = Day.key(at, calendar: ws.calendar)
            let time = at.formatted(date: .omitted, time: .shortened)
            let text = day == (task.day ?? ws.today) ? time : "\(Day.label(day, today: ws.today, calendar: ws.calendar)) \(time)"
            items.append(Meta(symbol: "bell", text: text, spoken: "Reminder \(text)"))
        }
        if let rule = task.repeatRule { items.append(Meta(symbol: "repeat", text: rule.label, spoken: "Repeats \(rule.label)")) }
        if let deadline = task.deadline {
            let label = Day.label(deadline, today: ws.today, calendar: ws.calendar)
            let late = deadline < ws.today && !task.isCompleted
            items.append(Meta(symbol: "flag.checkered", text: label, spoken: "Deadline \(label)\(late ? ", missed" : "")", alert: late))
        }
        return items
    }

    private static func symbol(project: String) -> String {
        switch project.lowercased() {
        case "work", "job", "office": "briefcase"
        case "home", "house", "family": "house"
        case "health", "fitness", "gym": "heart"
        case "money", "finance", "bills": "banknote"
        case "study", "school", "learning": "book"
        default: "folder"
        }
    }

    private var actions: some View {
        HStack(spacing: 1) {
            if isFocusing {
                IconButton(symbol: focus.phase == .running ? "pause.fill" : "play.fill", help: focus.phase == .running ? "Pause" : "Resume", color: theme.ink2, size: 10) {
                    if focus.phase == .running {
                        hub.workspace.focusPause()
                    } else {
                        hub.workspace.focusResume()
                    }
                }
            } else {
                IconButton(symbol: "play.fill", help: "Start focusing on this", color: theme.ink2, size: 10) {
                    hub.workspace.focusStart(taskId: task.id)
                }
            }
            IconButton(symbol: "square.and.pencil", help: "Edit details", color: theme.ink2, size: 11) {
                hub.ui.editingTask = task.id
            }
            Menu {
                Button("Today") { hub.workspace.move(task.id, to: hub.workspace.today) }
                Button("Tomorrow") { hub.workspace.move(task.id, to: Day.adding(1, to: hub.workspace.today, calendar: hub.workspace.calendar)) }
                Button("Next week") { hub.workspace.move(task.id, to: Day.adding(7, to: hub.workspace.today, calendar: hub.workspace.calendar)) }
                Button("Inbox") { hub.workspace.move(task.id, to: nil) }
                Divider()
                Button("Rename") { beginRename() }
                Button("Delete", role: .destructive) { hub.deleteTask(task.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.ink2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(showsDay ? "Reschedule" : "More")
            .accessibilityLabel(showsDay ? "Reschedule" : "More")
        }
    }
}

/// Lays children out left to right, wrapping to a new line when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map { row in row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: min(used, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

// MARK: Composer

/// Add a task by typing or speaking. "call mom tomorrow at 5pm" previews its day and reminder as you go.
struct Composer: View {
    @Environment(AppHub.self) private var hub
    var defaultDay: String?
    var autofocus = false
    var placeholder = "Add a task…"
    var dark = false
    var onFinish: (() -> Void)?
    /// Down with nothing typed.
    var onDownArrow: (() -> Void)?

    @State private var text = ""
    @State private var voiceOwner = UUID()
    @FocusState private var focused: Bool

    private var parsed: ParsedTask { NLParser.parse(text, now: hub.workspace.now, calendar: hub.workspace.calendar) }
    private var theme: Theme { dark ? Theme(bw: true) : hub.theme }

    var body: some View {
        let listening = hub.speech.activeOwner == voiceOwner
        VStack(alignment: .leading, spacing: 3) {
            if !text.isEmpty, parsed.hasDetails { preview }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.ink2)
                TextField("", text: $text, prompt: Text(placeholder).foregroundColor(theme.ink2))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { onFinish?() }
                    .onKeyPress(.downArrow) {
                        guard text.isEmpty, let onDownArrow else { return .ignored }
                        onDownArrow()
                        return .handled
                    }
                IconButton(symbol: listening ? "stop.circle.fill" : "mic", help: listening ? "Stop dictating" : "Dictate", color: theme.ink2, size: 12) {
                    hub.speech.toggle(owner: voiceOwner) { text = $0 }
                }
                if !text.isEmpty {
                    IconButton(symbol: "arrow.up", help: "Add", color: theme.ink, size: 11, action: submit)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(theme.wash, in: RoundedRectangle(cornerRadius: 9))
        }
        .onChange(of: hub.ui.wantsComposerFocus, initial: true) {
            guard autofocus, hub.ui.wantsComposerFocus else { return }
            hub.ui.wantsComposerFocus = false
            DispatchQueue.main.async { focused = true }
        }
        .onAppear {
            if onFinish != nil { focused = true }
        }
        .onChange(of: text) { hub.ui.hasComposerDraft = !text.isEmpty }
        .onDisappear { hub.ui.hasComposerDraft = false }
    }

    private var preview: some View {
        let ws = hub.workspace
        var parts: [String] = []
        if let when = parsed.whenLabel(today: ws.today, calendar: ws.calendar) { parts.append(when) }
        if let rule = parsed.repeatRule { parts.append(rule.label) }
        if let deadline = parsed.deadline { parts.append("by \(Day.label(deadline, today: ws.today, calendar: ws.calendar))") }
        if parsed.priority != .none { parts.append(parsed.priority.label) }
        if let project = parsed.project { parts.append(project) }
        return HStack(spacing: 4) {
            Image(systemName: parsed.reminderAt == nil ? "calendar" : "bell").font(.system(size: 9))
            Text(parsed.title).font(.system(size: 10)).lineLimit(1)
            Text("· " + parts.joined(separator: " · ")).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(theme.ink2)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onFinish?()
            return
        }
        if hub.speech.activeOwner == voiceOwner { hub.speech.stop() }
        hub.addTask(trimmed, day: defaultDay)
        text = ""
    }
}

// MARK: Editor

struct TaskEditor: View {
    @Environment(AppHub.self) private var hub
    let id: UUID
    @State private var newStep = ""

    private var ws: Workspace { hub.workspace }

    private func field<T>(_ keyPath: WritableKeyPath<TaskItem, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { ws.task(id)?[keyPath: keyPath] ?? fallback },
            set: { value in ws.update(id) { $0[keyPath: keyPath] = value } }
        )
    }

    var body: some View {
        if let task = ws.task(id) {
            let cal = ws.calendar
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Title", text: field(\.title, "")).textFieldStyle(.plain).font(.system(size: 16, weight: .semibold))
                    Button("Done") { hub.ui.editingTask = nil }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Day") {
                            Toggle("Inbox", isOn: Binding(
                                get: { task.day == nil },
                                set: { ws.move(id, to: $0 ? nil : ws.today) }
                            )).toggleStyle(.checkbox)
                            if let day = task.day {
                                DatePicker("", selection: Binding(
                                    get: { Day.date(day, calendar: cal) },
                                    set: { ws.move(id, to: Day.key($0, calendar: cal)) }
                                ), displayedComponents: .date)
                                .labelsHidden().datePickerStyle(.stepperField)
                            }
                        }
                        row("Reminder") {
                            Toggle("", isOn: Binding(
                                get: { task.reminderAt != nil },
                                set: { on in
                                    ws.update(id) { t in
                                        if on {
                                            let day = t.day ?? ws.today
                                            t.day = day
                                            t.reminderAt = Day.at(day, hour: 9, minute: 0, calendar: cal)
                                        } else {
                                            t.reminderAt = nil
                                        }
                                    }
                                }
                            )).labelsHidden().toggleStyle(.checkbox)
                            if let at = task.reminderAt {
                                DatePicker("", selection: Binding(
                                    get: { at },
                                    set: { value in
                                        ws.update(id) { t in
                                            t.reminderAt = value
                                            t.day = Day.key(value, calendar: cal)
                                        }
                                    }
                                ), displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden().datePickerStyle(.stepperField)
                            }
                        }
                        row("Deadline") {
                            Toggle("", isOn: Binding(
                                get: { task.deadline != nil },
                                set: { on in ws.update(id) { $0.deadline = on ? ($0.day ?? ws.today) : nil } }
                            )).labelsHidden().toggleStyle(.checkbox)
                            if let deadline = task.deadline {
                                DatePicker("", selection: Binding(
                                    get: { Day.date(deadline, calendar: cal) },
                                    set: { value in ws.update(id) { $0.deadline = Day.key(value, calendar: cal) } }
                                ), displayedComponents: .date)
                                .labelsHidden().datePickerStyle(.stepperField)
                            }
                        }
                        row("Priority") {
                            Picker("", selection: field(\.priority, .none)) {
                                ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                        }
                        row("Project") {
                            TextField("None", text: Binding(
                                get: { task.project ?? "" },
                                set: { value in ws.update(id) { $0.project = value.isEmpty ? nil : value } }
                            ))
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                            if !ws.projects.isEmpty {
                                Menu("Existing") {
                                    ForEach(ws.projects, id: \.self) { project in
                                        Button(project) { ws.update(id) { $0.project = project } }
                                    }
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                        row("Repeat") {
                            Picker("", selection: Binding(
                                get: { task.repeatRule?.kind },
                                set: { kind in ws.update(id) { $0.repeatRule = kind.map { RepeatRule(kind: $0) } } }
                            )) {
                                Text("Never").tag(RepeatRule.Kind?.none)
                                Text("Daily").tag(RepeatRule.Kind?.some(.daily))
                                Text("Weekdays").tag(RepeatRule.Kind?.some(.weekdays))
                                Text("Weekly").tag(RepeatRule.Kind?.some(.weekly))
                                Text("Monthly").tag(RepeatRule.Kind?.some(.monthly))
                                Text("Yearly").tag(RepeatRule.Kind?.some(.yearly))
                            }
                            .labelsHidden().frame(width: 120)
                        }
                        row("Focus for") {
                            Stepper(value: Binding(
                                get: { task.plannedMinutes ?? ws.data.settings.defaultFocusMinutes },
                                set: { value in ws.update(id) { $0.plannedMinutes = max(1, value) } }
                            ), in: 1...600, step: 5) {
                                Text("\(task.plannedMinutes ?? ws.data.settings.defaultFocusMinutes) min").font(.system(size: 12))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        TextEditor(text: field(\.notes, ""))
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .frame(height: 70)
                        Text("Steps").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(task.steps) { step in
                                    HStack(spacing: 6) {
                                        Button {
                                            ws.update(id) { t in
                                                if let i = t.steps.firstIndex(where: { $0.id == step.id }) { t.steps[i].done.toggle() }
                                            }
                                        } label: {
                                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(step.done ? "Mark step not done" : "Mark step done")
                                        Text(step.title).font(.system(size: 12)).strikethrough(step.done).lineLimit(1)
                                        Spacer()
                                        IconButton(symbol: "xmark", help: "Remove step", color: .white.opacity(0.5), size: 8) {
                                            ws.update(id) { t in t.steps.removeAll { $0.id == step.id } }
                                        }
                                    }
                                }
                            }
                        }
                        TextField("Add a step…", text: $newStep)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit {
                                let title = newStep.trimmingCharacters(in: .whitespaces)
                                if !title.isEmpty {
                                    ws.update(id) { $0.steps.append(Step(title: title)) }
                                }
                                newStep = ""
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).frame(width: 56, alignment: .leading)
            content()
        }
    }
}

// MARK: Week

/// The days ahead beside an Inbox for tasks without a day. Drag a task to any day, or back to the Inbox.
struct WeekPage: View {
    @Environment(AppHub.self) private var hub

    var body: some View {
        let ws = hub.workspace
        let cal = ws.calendar
        let days = (0..<14).map { Day.adding($0, to: ws.today, calendar: cal) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Upcoming").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("\(Day.format(days[0], "d MMM", calendar: cal)) – \(Day.format(days[13], "d MMM", calendar: cal))")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.leading, 6)
            HStack(spacing: 8) {
                WeekColumn(day: nil).frame(width: 208)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days, id: \.self) { WeekColumn(day: $0).frame(width: 208) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

private struct WeekColumn: View {
    @Environment(AppHub.self) private var hub
    let day: String?
    @State private var adding = false
    @State private var targeted = false
    @State private var selected: UUID?
    @FocusState private var listFocused: Bool

    var body: some View {
        let ws = hub.workspace
        let cal = ws.calendar
        let tasks = ws.open(on: day)
        let theme = Theme(bw: true)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                header(ws: ws, cal: cal)
                Spacer()
                Text("\(tasks.count)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { TaskRow(task: $0, compact: true, selected: selected == $0.id) }
                }
                if adding {
                    Composer(defaultDay: day, placeholder: "Task…", dark: true, onFinish: { adding = false })
                } else {
                    Button { adding = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 11))
                            Text("Add task").font(.system(size: 12))
                            Spacer()
                        }
                        .foregroundStyle(theme.ink2)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .modifier(TaskListKeys(ids: tasks.map(\.id), selected: $selected, focused: $listFocused))
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .foregroundStyle(theme.ink)
        .onDrop(of: [.plainText], isTargeted: $targeted) { _ in hub.dropTask(on: day, before: nil) }
    }

    @ViewBuilder
    private func header(ws: Workspace, cal: Calendar) -> some View {
        if let day {
            if day == ws.today {
                Text("Today").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(.white, in: Capsule())
            } else {
                Text(day == Day.adding(1, to: ws.today, calendar: cal) ? "Tomorrow" : Day.format(day, "EEEE", calendar: cal))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(Day.format(day, "d MMM", calendar: cal)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        } else {
            Image(systemName: "tray").font(.system(size: 12))
            Text("Inbox").font(.system(size: 13, weight: .semibold))
        }
    }
}
