import PerchCore
import SwiftUI

struct InsightsPage: View {
    @Environment(AppHub.self) private var hub

    var body: some View {
        let summary = hub.workspace.insights()
        let theme = hub.theme
        HStack(spacing: 8) {
            SummaryCard(summary: summary)
                .frame(width: 236)
                .paper(theme.card(.tasks), grain: !theme.bw)
            ChartCard(summary: summary)
                .frame(maxWidth: .infinity)
                .paper(theme.card(.focus), grain: !theme.bw)
            HistoryCard()
                .frame(width: 200)
                .paper(theme.card(.agenda), grain: !theme.bw)
        }
        .environment(\.colorScheme, theme.scheme)
        .foregroundStyle(theme.ink)
    }
}

private struct SummaryCard: View {
    @Environment(AppHub.self) private var hub
    let summary: InsightsSummary

    var body: some View {
        let theme = hub.theme
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.headline).font(.system(size: 15, weight: .semibold))
                Text(summary.sentence).font(.system(size: 11)).foregroundStyle(theme.ink2).fixedSize(horizontal: false, vertical: true)
                Text("Last 7 days").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.ink2).padding(.top, 4)
                Text("\(summary.completed)").font(.system(size: 38, weight: .semibold)).monospacedDigit()
                Text("Tasks completed").font(.system(size: 11, weight: .medium))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.washStrong)
                        Capsule().fill(theme.ink)
                            .frame(width: geometry.size.width * (summary.planned > 0 ? min(1, Double(summary.completed) / Double(summary.planned)) : 0))
                    }
                }
                .frame(height: 5)
                .accessibilityLabel("\(summary.completed) of \(summary.planned) planned tasks completed")
                Text("of \(summary.planned) planned").font(.system(size: 10)).foregroundStyle(theme.ink2)
                Rectangle().fill(theme.wash).frame(height: 1).padding(.vertical, 2)
                stat("timer", "Focus time", InsightsSummary.duration(summary.focusSeconds))
                stat("calendar", "Active days", "\(summary.activeDays) of 7")
                stat("sun.max", "Peak hour", peakLabel)
            }
            .padding(12)
        }
    }

    private var peakLabel: String {
        guard let hour = summary.peakHour else { return "–" }
        let cal = hub.workspace.calendar
        let start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return start.formatted(date: .omitted, time: .shortened)
    }

    private func stat(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
            Text(label).font(.system(size: 11))
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
    }
}

/// Bars for the last seven days. Tasks stacks what was completed under what was planned; Focus is a single series.
private struct ChartCard: View {
    @Environment(AppHub.self) private var hub
    let summary: InsightsSummary
    private enum Mode { case tasks, focus }
    @State private var mode = Mode.tasks
    @State private var hovered: String?

    var body: some View {
        let theme = hub.theme
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                modeButton("Tasks", .tasks)
                modeButton("Focus", .focus)
            }
            .padding(2)
            .background(theme.wash, in: Capsule())
            .fixedSize()

            GeometryReader { geometry in
                chart(height: geometry.size.height - 34)
            }

            if mode == .tasks {
                HStack(spacing: 12) {
                    legend(theme.ink, "Completed")
                    legend(theme.ink3, "Planned")
                    Spacer()
                }
            } else {
                Text("Active focus time").font(.system(size: 10)).foregroundStyle(theme.ink2)
            }
        }
        .padding(12)
    }

    private func modeButton(_ title: String, _ value: Mode) -> some View {
        let theme = hub.theme
        return Button { mode = value } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(mode == value ? theme.ink : theme.ink2)
                .padding(.horizontal, 12).padding(.vertical, 3)
                .background(mode == value ? theme.washStrong : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 10)).foregroundStyle(hub.theme.ink2)
        }
    }

    private func chart(height: CGFloat) -> some View {
        let theme = hub.theme
        let top = mode == .tasks
            ? Double(max(summary.days.map(\.planned).max() ?? 0, 1))
            : Double(max(summary.days.map(\.focusSeconds).max() ?? 0, 60))
        let cal = hub.workspace.calendar
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(summary.days, id: \.day) { day in
                VStack(spacing: 3) {
                    Spacer(minLength: 0)
                    if hovered == day.day {
                        Text(tooltip(day)).font(.system(size: 9, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    bars(day, top: top, height: height - 14)
                    Text(Day.format(day.day, "EEE", calendar: cal)).font(.system(size: 10)).foregroundStyle(theme.ink2)
                    Text(Day.format(day.day, "d", calendar: cal)).font(.system(size: 9)).foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        hovered = day.day
                    } else if hovered == day.day {
                        hovered = nil
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Day.format(day.day, "EEEE d MMMM", calendar: cal)): \(tooltip(day))")
            }
        }
    }

    private func bars(_ day: DayStat, top: Double, height: CGFloat) -> some View {
        let theme = hub.theme
        let barHeight = max(height - 16, 10)
        let rounded = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 4)
        return VStack(spacing: 2) {
            if mode == .tasks {
                let remaining = max(0, day.planned - day.completed)
                if remaining > 0 {
                    rounded.fill(theme.ink3).frame(height: barHeight * CGFloat(Double(remaining) / top))
                }
                if day.completed > 0 {
                    rounded.fill(theme.ink).frame(height: barHeight * CGFloat(Double(day.completed) / top))
                }
            } else if day.focusSeconds > 0 {
                rounded.fill(theme.ink).frame(height: max(2, barHeight * CGFloat(Double(day.focusSeconds) / top)))
            }
            Rectangle().fill(theme.washStrong).frame(height: 1)
        }
        .frame(maxWidth: 34)
    }

    private func tooltip(_ day: DayStat) -> String {
        mode == .tasks
            ? "\(day.completed) of \(day.planned)"
            : InsightsSummary.duration(day.focusSeconds)
    }
}

/// What actually got finished, by day.
private struct HistoryCard: View {
    @Environment(AppHub.self) private var hub

    var body: some View {
        let theme = hub.theme
        let ws = hub.workspace
        let cal = ws.calendar
        let days = (0..<14).map { Day.adding(-$0, to: ws.today, calendar: cal) }
        VStack(alignment: .leading, spacing: 6) {
            Text("History").font(.system(size: 14, weight: .semibold))
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        let done = ws.completed(on: day)
                        if !done.isEmpty {
                            Text(Day.label(day, today: ws.today, calendar: cal).uppercased())
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.ink2)
                            ForEach(done) { task in
                                HStack(alignment: .top, spacing: 5) {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).padding(.top, 2)
                                    Text(task.title).font(.system(size: 11)).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if days.allSatisfy({ ws.completed(on: $0).isEmpty }) {
                    Text("Finished tasks show up here.").font(.system(size: 11)).foregroundStyle(theme.ink2)
                }
            }
        }
        .padding(12)
    }
}
