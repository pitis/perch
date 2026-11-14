import SwiftUI

/// The one-screen setup a fresh install opens with, and Settings › General opens again.
/// Each row asks through the same path the feature itself uses, so it adds no new kind of permission.
struct SetupView: View {
    @Environment(AppHub.self) private var hub
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppBadge(side: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Perch").font(.title2.weight(.semibold))
                    Text("Hover the notch or press ⌥N to open it.").foregroundStyle(.secondary)
                }
            }

            Text("These need your Mac's permission. Set up any of them now, or skip them and do it later in Settings.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                row("calendar", "Calendar", "Shows today's events in the Events card. Perch only reads them.") {
                    if hub.calendar.isConnected {
                        allowed("Connected")
                    } else {
                        switch hub.calendar.status {
                        case .denied: refused(CalendarService.openPrivacySettings)
                        case .restricted: Text("Not allowed on this Mac").foregroundStyle(.secondary)
                        default: Button("Set up", action: hub.calendar.connect)
                        }
                    }
                }
                Divider()
                row("bell", "Notifications", "Rings your reminders while Perch is quit.") {
                    switch hub.notificationStatus {
                    case .authorized, .provisional, .ephemeral: allowed("Allowed")
                    case .denied: refused(AppHub.openNotificationSettings)
                    default: Button("Set up", action: hub.requestNotifications)
                    }
                }
                Divider()
                row("camera.viewfinder", "Screenshots", "Keeps new screenshots and screen recordings in Clips. macOS asks for the folder they're saved in, usually the Desktop.") {
                    switch hub.clips.screenshotWatch {
                    case .watching: allowed("On")
                    case .starting: ProgressView().controlSize(.small)
                    case .refused: refused(ClipsManager.openPrivacySettings)
                    case .off:
                        Button("Set up") {
                            hub.workspace.data.settings.captureScreenshots = true
                            hub.clips.updateScreenshotWatcher()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Reminders sync and the microphone ask when you first use them.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row<Trailing: View>(_ symbol: String, _ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title) // the group's name tells VoiceOver which feature its button is for
    }

    private func allowed(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
    }

    /// macOS won't ask a second time, so the way back is System Settings.
    private func refused(_ openSettings: @escaping () -> Void) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Access was refused").font(.caption).foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings)
        }
    }
}
