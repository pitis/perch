import AppKit
import PerchCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspacePage: View {
    @Environment(AppHub.self) private var hub
    /// Weights while a gap is being dragged, saved once the drag ends so the store isn't rewritten every frame.
    /// Gesture state resets itself if the drag is cancelled, so stale weights never outlive it.
    @GestureState private var dragged: [Double]?
    private let gap: CGFloat = 8

    var body: some View {
        let cards = hub.workspace.data.settings.cards.filter(\.visible)
        GeometryReader { geometry in
            let available = geometry.size.width - gap * CGFloat(max(0, cards.count - 1))
            let minimums = cards.map(\.kind.minWidth)
            let widths = CardLayout.widths(dragged ?? cards.map(\.weight), minimums: minimums, in: available)
            if cards.isEmpty {
                ContentUnavailableView("All cards are hidden", systemImage: "eye.slash", description: Text("Turn them back on in Customize."))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        CardFrame(kind: card.kind) { body(of: card.kind) }
                            .frame(width: widths[index])
                        if index < cards.count - 1 {
                            resizeHandle(after: index, cards: cards, minimums: minimums, available: available)
                        }
                    }
                }
            }
        }
    }

    /// The gap between two cards: dragging it widens one and narrows the other.
    private func resizeHandle(after index: Int, cards: [CardConfig], minimums: [Double], available: Double) -> some View {
        Color.clear
            .frame(width: gap)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                // Set, not pushed: a pushed cursor stays stuck if the panel closes before the pointer leaves.
                if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            // Global, because the handle itself moves as the cards resize. The stored weights don't change during the
            // drag, so each frame resizes from them.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($dragged) { drag, dragged, _ in
                    dragged = CardLayout.resize(cards.map(\.weight), at: index, by: drag.translation.width, minimums: minimums, in: available)
                }
                .onEnded { drag in
                    let weights = CardLayout.resize(cards.map(\.weight), at: index, by: drag.translation.width, minimums: minimums, in: available)
                    var all = hub.workspace.data.settings.cards
                    for (card, weight) in zip(cards, weights) {
                        if let i = all.firstIndex(where: { $0.kind == card.kind }) { all[i].weight = weight }
                    }
                    hub.workspace.data.settings.cards = all // one change, so one save
                })
            .help("Drag to resize the cards on either side")
    }

    @ViewBuilder
    private func body(of kind: CardConfig.Kind) -> some View {
        switch kind {
        case .tasks: TasksCard()
        case .focus: FocusCard()
        case .notes: NotesCard()
        case .agenda: EventsCard()
        }
    }
}

/// A coloured paper card with a handle on top that you can drag to reorder it.
struct CardFrame<Content: View>: View {
    @Environment(AppHub.self) private var hub
    let kind: CardConfig.Kind
    @ViewBuilder let content: () -> Content

    var body: some View {
        let theme = hub.theme
        VStack(spacing: 0) {
            Capsule()
                .fill(theme.ink3)
                .frame(width: 24, height: 3)
                .frame(maxWidth: .infinity, minHeight: 13)
                .contentShape(Rectangle())
                .onDrag {
                    hub.ui.draggingCard = kind
                    return NSItemProvider(item: Data(kind.rawValue.utf8) as NSData, typeIdentifier: UTType.perchCard.identifier)
                }
                .help("Drag to move this card")
            content()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .paper(theme.card(kind), grain: !theme.bw)
        .environment(\.colorScheme, theme.scheme)
        .foregroundStyle(theme.ink)
        .onDrop(of: [.perchCard], isTargeted: nil) { _ in hub.dropCard(on: kind) }
    }
}

// MARK: Focus

struct FocusCard: View {
    @Environment(AppHub.self) private var hub
    @State private var showingSetTime = false
    @State private var customMinutes = ""

    var body: some View {
        let focus = hub.workspace.data.focus
        Group {
            if focus.phase == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    face(focus, now: context.date)
                }
            } else {
                face(focus, now: Date())
            }
        }
        .onChange(of: focus.phase) { showingSetTime = false }
    }

    private func face(_ focus: FocusTimer, now: Date) -> some View {
        let theme = hub.theme
        let settings = hub.workspace.data.settings
        return VStack(spacing: 6) {
            taskPicker(focus)
            Spacer(minLength: 0)
            if showingSetTime {
                setTime(focus)
            } else {
                let seconds = focus.phase == .idle && focus.mode == .stopwatch ? 0 : displaySeconds(focus, now: now)
                VStack(spacing: 6) {
                    ClockFace(text: FocusTimer.clock(seconds), style: settings.clockStyle, color: theme.ink)
                    Text(caption(focus)).font(.system(size: 11)).foregroundStyle(theme.ink2)
                    progress(focus, now: now)
                }
                // "Remaining, 24 minutes 13 seconds" rather than the digits one by one.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(caption(focus))
                .accessibilityValue(NotchRootView.spoken(seconds))
                .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer(minLength: 0)
            controls(focus)
        }
    }

    private func displaySeconds(_ focus: FocusTimer, now: Date) -> TimeInterval {
        focus.phase == .idle && focus.mode == .countdown ? TimeInterval(focus.targetSeconds) : focus.display(at: now)
    }

    private func caption(_ focus: FocusTimer) -> String {
        switch focus.phase {
        case .idle: "Ready"
        case .running: focus.mode == .countdown ? "Remaining" : "Elapsed"
        case .paused: "Paused"
        case .done: "Done"
        }
    }

    private func progress(_ focus: FocusTimer, now: Date) -> some View {
        let theme = hub.theme
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.washStrong)
                Capsule().fill(theme.ink2).frame(width: geometry.size.width * focus.progress(at: now))
            }
        }
        .frame(width: 96, height: 3)
        .opacity(focus.mode == .countdown ? 1 : 0)
    }

    private func taskPicker(_ focus: FocusTimer) -> some View {
        let theme = hub.theme
        let current = focus.taskId.flatMap { hub.workspace.task($0)?.title }
        return Menu {
            Button("No task") { hub.workspace.focusSetTask(nil) }
            Divider()
            ForEach(hub.workspace.open(on: hub.workspace.today)) { task in
                Button(task.title) { hub.workspace.focusSetTask(task.id) }
            }
        } label: {
            Text(current ?? "No task").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(theme.ink2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Choose a task to focus on")
        .accessibilityLabel("Task to focus on")
        .accessibilityValue(current ?? "No task")
    }

    private func setTime(_ focus: FocusTimer) -> some View {
        let theme = hub.theme
        return VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach([5, 15, 25, 45, 60, 90], id: \.self) { minutes in
                    Button {
                        hub.workspace.focusSetTarget(minutes: minutes)
                        showingSetTime = false
                    } label: {
                        Text("\(minutes)")
                            .font(.system(size: 11, weight: focus.targetSeconds == minutes * 60 ? .bold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                            .background(theme.wash, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 4) {
                TextField("", text: $customMinutes, prompt: Text("Minutes").foregroundColor(theme.ink2))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(theme.wash, in: RoundedRectangle(cornerRadius: 6))
                    .onSubmit {
                        if let minutes = Int(customMinutes), (1...1440).contains(minutes) {
                            hub.workspace.focusSetTarget(minutes: minutes)
                            showingSetTime = false
                        }
                        customMinutes = ""
                    }
                Button {
                    hub.workspace.focusSetStopwatch()
                    showingSetTime = false
                } label: {
                    Image(systemName: "stopwatch")
                        .font(.system(size: 12))
                        .padding(4)
                        .background(focus.mode == .stopwatch ? theme.washStrong : theme.wash, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Stopwatch: no time limit")
                .accessibilityLabel("Stopwatch")
            }
        }
    }

    private func controls(_ focus: FocusTimer) -> some View {
        let theme = hub.theme
        let ws = hub.workspace
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                primaryButton(focus)
                Button {
                    let id = focus.taskId
                    ws.focusStop()
                    if let id { ws.setCompleted(id, true) }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(theme.washStrong, in: Circle())
                }
                .buttonStyle(.plain)
                .help(focus.taskId == nil ? "Finish" : "Finish and complete the task")
                .accessibilityLabel(focus.taskId == nil ? "Finish" : "Finish and complete the task")
            }
            HStack(spacing: 6) {
                if focus.phase == .idle {
                    Button {
                        showingSetTime.toggle()
                    } label: {
                        Label("Set time", systemImage: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(theme.ink2)
                    }
                    .buttonStyle(.plain)
                } else if focus.mode == .countdown {
                    Button(action: ws.focusAddFive) {
                        Text("Add 5 min").font(.system(size: 11)).foregroundStyle(theme.ink2).lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    Picker("Clock style", selection: Binding(get: { ws.data.settings.clockStyle }, set: { ws.data.settings.clockStyle = $0 })) {
                        ForEach(ClockStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if focus.isActive {
                        Divider()
                        Button("Stop timer", action: ws.focusStop)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.ink2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Timer options")
            }
        }
    }

    @ViewBuilder
    private func primaryButton(_ focus: FocusTimer) -> some View {
        let ws = hub.workspace
        switch focus.phase {
        case .idle:
            bigButton("Start", "play.fill") {
                ws.focusStart(taskId: focus.taskId, minutes: focus.targetSeconds / 60, stopwatch: focus.mode == .stopwatch)
            }
        case .running:
            bigButton("Pause", "pause.fill", action: ws.focusPause)
        case .paused:
            bigButton("Resume", "play.fill", action: ws.focusResume)
        case .done:
            bigButton("Reset", "arrow.counterclockwise", action: ws.focusStop)
        }
    }

    private func bigButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        let theme = hub.theme
        return Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.bw ? Color.black : Color.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(theme.bw ? Color.white : Color(hex: 0x1B1E1A, alpha: 0.5), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Notepad

struct NotesCard: View {
    @Environment(AppHub.self) private var hub
    @State private var voiceOwner = UUID()
    @State private var voiceBase = ""

    var body: some View {
        let theme = hub.theme
        let day = hub.ui.selectedDay
        let binding = Binding(get: { hub.workspace.note(on: day) }, set: { hub.workspace.setNote($0, on: day) })
        let listening = hub.speech.activeOwner == voiceOwner
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
                Text("Notepad").font(.system(size: 14, weight: .semibold))
            }
            Text(Day.format(day, "d MMM yyyy", calendar: hub.workspace.calendar)).font(.system(size: 10)).foregroundStyle(theme.ink2)
            Rectangle().fill(theme.wash).frame(height: 1)
            NoteEditor(text: binding, ink: theme.bw ? .white : NSColor(red: 0.105, green: 0.118, blue: 0.102, alpha: 1)) { line in
                hub.workspace.taskFromNoteLine(line, day: day).map { hub.classify($0, defaultDay: day); return true } ?? false
            }
            HStack(spacing: 5) {
                Image(systemName: "text.alignleft").font(.system(size: 10))
                Text(wordCount(binding.wrappedValue)).font(.system(size: 10))
                Spacer()
                IconButton(symbol: listening ? "stop.circle.fill" : "mic", help: listening ? "Stop dictating" : "Dictate", color: theme.ink2, size: 12) {
                    if !listening { voiceBase = binding.wrappedValue }
                    hub.speech.toggle(owner: voiceOwner) { spoken in
                        binding.wrappedValue = voiceBase.isEmpty ? spoken : voiceBase + "\n" + spoken
                    }
                }
            }
            .foregroundStyle(theme.ink2)
        }
    }

    private func wordCount(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return count == 1 ? "1 word" : "\(count) words"
    }
}

private final class NoteTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommandReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A plain text view, because SwiftUI's TextEditor doesn't expose the cursor and Command-Return needs its line.
private struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    let ink: NSColor
    /// Returns whether the line became a task, in which case it leaves the note.
    let onLineToTask: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let view = NoteTextView(frame: .zero)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 12)
        view.string = text
        view.delegate = context.coordinator
        view.onCommandReturn = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.convertCurrentLine(in: view)
        }
        scroll.documentView = view
        apply(ink, to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        apply(ink, to: view)
    }

    private func apply(_ color: NSColor, to view: NSTextView) {
        view.textColor = color
        view.insertionPointColor = color
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor

        init(_ parent: NoteEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func convertCurrentLine(in view: NSTextView) {
            let text = view.string as NSString
            let range = text.lineRange(for: NSRange(location: view.selectedRange().location, length: 0))
            guard parent.onLineToTask(text.substring(with: range)) else { return }
            if view.shouldChangeText(in: range, replacementString: "") {
                view.replaceCharacters(in: range, with: "")
                view.didChangeText()
            }
        }
    }
}

// MARK: Events

struct EventsCard: View {
    @Environment(AppHub.self) private var hub

    var body: some View {
        let theme = hub.theme
        let cal = hub.workspace.calendar
        let today = hub.workspace.today
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 13))
                Text("Events").font(.system(size: 14, weight: .semibold))
                Spacer()
                if hub.calendar.isConnected {
                    Menu {
                        Button("Open Calendar", action: CalendarService.openCalendarApp)
                        Divider()
                        Button("Disconnect", action: hub.calendar.disconnect)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.ink2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Calendar options")
                }
            }
            if hub.calendar.isConnected {
                HStack {
                    Text("TODAY").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text(Day.format(today, "EEE d", calendar: cal)).font(.system(size: 10))
                }
                .foregroundStyle(theme.ink2)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(hub.calendar.events) { event in
                            EventRowView(event: event)
                        }
                    }
                }
                .overlay {
                    if hub.calendar.events.isEmpty {
                        Text("Nothing else today").font(.system(size: 11)).foregroundStyle(theme.ink2)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle").font(.system(size: 10))
                    Text("Connected").font(.system(size: 10))
                    Spacer()
                    IconButton(symbol: "arrow.clockwise", help: "Refresh", color: theme.ink2, size: 10, action: hub.calendar.refresh)
                }
                .foregroundStyle(theme.ink2)
            } else {
                Spacer()
                Text("See today's events here. Perch only reads them.")
                    .font(.system(size: 11)).foregroundStyle(theme.ink2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Button(action: hub.calendar.connect) {
                    Text("Connect Calendar").font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(theme.washStrong, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }
}

private struct EventRowView: View {
    @Environment(AppHub.self) private var hub
    let event: EventRow

    private var key: String { "\(event.id)@\(hub.workspace.today)" }

    var body: some View {
        let theme = hub.theme
        let checked = hub.workspace.data.checkedEvents.contains(key)
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).strikethrough(checked)
                Text(time).font(.system(size: 10)).foregroundStyle(theme.ink2).lineLimit(1)
                if let location = event.location, !location.isEmpty {
                    Text(location).font(.system(size: 10)).foregroundStyle(theme.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                if checked {
                    hub.workspace.data.checkedEvents.removeAll { $0 == key }
                } else {
                    hub.workspace.data.checkedEvents.append(key)
                }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.system(size: 14)).foregroundStyle(theme.ink2)
            }
            .buttonStyle(.plain)
            .help("Tick off here. Your calendar isn't changed.")
            .accessibilityLabel(checked ? "Untick \(event.title)" : "Tick off \(event.title)")
        }
        .opacity(checked ? 0.55 : 1)
        .padding(8)
        .background(theme.washStrong, in: RoundedRectangle(cornerRadius: 9))
    }

    private var time: String {
        if event.isAllDay { return "All day" }
        return "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
    }
}
