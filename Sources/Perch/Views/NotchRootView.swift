import PerchCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything inside the notch panel: the idle notch, the compact timer, the reminder card and the open workspace.
struct NotchRootView: View {
    @Environment(AppHub.self) private var hub

    private static let wing: CGFloat = 92

    private var ui: NotchUI { hub.ui }
    private var focus: FocusTimer { hub.workspace.data.focus }
    private var showsWings: Bool { ui.greeting || focus.isActive }

    private var isInvisibleWhenIdle: Bool {
        ui.geometry.style == .edge || (ui.geometry.style == .drawn && ui.fullscreen)
    }

    private var size: CGSize {
        let g = ui.geometry
        switch ui.mode {
        case .open:
            return CGSize(width: g.openWidth, height: g.openHeight)
        case .activity:
            return CGSize(width: max(g.notchWidth + 40, ActivityCard.width), height: g.notchHeight + ActivityCard.height)
        case .closed:
            let wings = showsWings ? Self.wing * 2 : 0
            return CGSize(width: g.notchWidth + wings + radii.top * 2, height: g.notchHeight)
        }
    }

    private var radii: (top: CGFloat, bottom: CGFloat) {
        switch ui.mode {
        case .open: (12, 20)
        case .activity: (12, 22)
        case .closed: (5, 9)
        }
    }

    private var isHidden: Bool {
        ui.mode == .closed && !showsWings && isInvisibleWhenIdle
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: ui.geometry.topInset)
            ZStack(alignment: .top) {
                NotchShape(topRadius: radii.top, bottomRadius: radii.bottom).fill(.black)
                content
                    .padding(.horizontal, radii.top)
                    .clipShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
            }
            .frame(width: size.width, height: size.height)
            .opacity(isHidden ? 0 : 1)
            .shadow(color: .black.opacity(ui.mode == .closed ? 0 : 0.42), radius: 16, y: 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.87), value: ui.mode)
        .animation(.spring(response: 0.34, dampingFraction: 0.87), value: showsWings)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            hub.clips.addDropped(providers)
            ui.page = .clips
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch ui.mode {
        case .open:
            VStack(spacing: 6) {
                PageHeader(page: Binding(get: { ui.page }, set: { ui.page = $0 }),
                           notchGap: ui.geometry.style == .edge ? 0 : ui.geometry.notchWidth,
                           headerHeight: max(ui.geometry.notchHeight, 32),
                           showsClose: true)
                PageContent(page: ui.page)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 10)
            }
            .overlay(alignment: .top) {
                if ui.activity != nil {
                    ActivityCard()
                        .padding(10)
                        .background(.black, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15)))
                        .padding(.top, ui.geometry.notchHeight + 8)
                }
            }
            .transition(.opacity)
        case .activity:
            ActivityCard()
                .padding(.top, ui.geometry.notchHeight + 4)
                .transition(.opacity)
        case .closed:
            compact.frame(height: ui.geometry.notchHeight).transition(.opacity)
        }
    }

    @ViewBuilder
    private var compact: some View {
        if ui.greeting {
            wings(left: AnyView(DotText(text: "WELCOME", pitch: 1.7, maxWidth: Self.wing - 12)),
                  right: AnyView(DotText(text: "BACK", pitch: 1.7, maxWidth: Self.wing - 12)))
        } else if focus.isActive {
            switch focus.phase {
            case .running:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = context.date
                    wings(left: AnyView(ProgressRing(progress: focus.progress(at: now), isStopwatch: focus.mode == .stopwatch)),
                          right: AnyView(DotText(text: FocusTimer.clock(focus.display(at: now)), pitch: 1.9, maxWidth: Self.wing - 12)))
                }
            case .paused:
                wings(left: AnyView(DotText(text: FocusTimer.clock(focus.display(at: Date())), pitch: 1.9, maxWidth: Self.wing - 12, color: .white.opacity(0.5))),
                      right: AnyView(DotText(text: "PAUSED", pitch: 1.7, maxWidth: Self.wing - 12)))
            default:
                wings(left: AnyView(ProgressRing(progress: 1, isStopwatch: false)),
                      right: AnyView(DotText(text: "DONE", pitch: 1.9, maxWidth: Self.wing - 12, color: Theme.accent)))
            }
        }
    }

    private func wings(left: AnyView, right: AnyView) -> some View {
        HStack(spacing: 0) {
            left.frame(width: Self.wing)
            Spacer(minLength: ui.geometry.style == .edge ? 8 : ui.geometry.notchWidth)
            right.frame(width: Self.wing)
        }
    }
}

private struct ProgressRing: View {
    let progress: Double
    let isStopwatch: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
            if !isStopwatch {
                Circle().trim(from: 0, to: progress).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// The nudge when a reminder comes due: what it is, snooze five minutes, or done.
struct ActivityCard: View {
    static let width: CGFloat = 340
    static let height: CGFloat = 92

    @Environment(AppHub.self) private var hub

    var body: some View {
        if let task = hub.ui.activity {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AppBadge(side: 60)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Image(systemName: "bell.fill")
                        .font(.system(size: 10)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                }
                .frame(width: 67, height: 67)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let at = task.effectiveReminder {
                        Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                    HStack(spacing: 8) {
                        Button(action: hub.snoozeActivity) {
                            Label("5 min", systemImage: "zzz")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(Color(hex: 0x2B2B2B), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button(action: hub.completeActivity) {
                            Label("Done", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(Theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: Self.width - 16)
        }
    }
}

/// The name, Clips and tabs row. The two sides leave a gap in the middle where the physical notch sits.
struct PageHeader: View {
    @Environment(AppHub.self) private var hub
    @Binding var page: Page
    var notchGap: CGFloat
    var headerHeight: CGFloat
    var showsClose: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                AppBadge(side: 22)
                Text("Perch").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Button { page = .clips } label: {
                    Label("Clips", systemImage: "paperclip")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(page == .clips ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(page == .clips ? Color.white : Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 6)

            Color.clear.frame(width: notchGap)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    ForEach(Page.tabs) { tab in
                        Button { page = tab } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(page == tab ? .white : .white.opacity(0.55))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(page == tab ? Color.white.opacity(0.16) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(.white.opacity(0.07), in: Capsule())
                IconButton(symbol: "gearshape", help: "Settings", color: .white.opacity(0.7), size: 12, action: hub.openSettingsWindow)
                if showsClose {
                    IconButton(symbol: "xmark", help: "Close", color: .white.opacity(0.7), size: 11) { hub.notch?.close() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 4)
        }
        .frame(height: headerHeight)
    }
}

/// One page plus the overlays every page shares: the task editor, the date picker and the Undo toast.
struct PageContent: View {
    @Environment(AppHub.self) private var hub
    let page: Page

    var body: some View {
        Group {
            switch page {
            case .workspace: WorkspacePage()
            case .week: WeekPage()
            case .insights: InsightsPage()
            case .customize: CustomizePage()
            case .clips: ClipsPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let id = hub.ui.editingTask, hub.workspace.task(id) != nil {
                TaskEditor(id: id)
            }
        }
        .overlay {
            if let pick = hub.ui.pickingDay { DayPicker(pick: pick) }
        }
        .overlay(alignment: .bottom) {
            if let toast = hub.ui.toast {
                HStack(spacing: 10) {
                    Text(toast.text).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                    if let id = toast.undoTask {
                        Button("Undo") {
                            hub.workspace.undoDelete(id)
                            hub.ui.toast = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(hex: 0x1A1A1A), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.15)))
                .padding(.bottom, 8)
            } else if let error = hub.speech.errorText {
                Button { hub.speech.errorText = nil } label: {
                    Text(error).font(.system(size: 12)).foregroundStyle(.white).lineLimit(2)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color(hex: 0x1A1A1A), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
    }
}

/// The same pages in an ordinary resizable window.
struct DashboardView: View {
    @Environment(AppHub.self) private var hub
    @State private var page = Page.workspace

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(page: $page, notchGap: 0, headerHeight: 36, showsClose: false)
            PageContent(page: page)
        }
        .padding(12)
        .frame(minWidth: 860, minHeight: 480)
        .background(.black)
    }
}
