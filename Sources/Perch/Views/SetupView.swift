import SwiftUI

/// The one-screen setup a fresh install opens with, and Settings › General opens again.
/// Each row asks through the same path the feature itself uses, so nothing here asks macOS for anything new.
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
                    if hub.calendar.isConnected { allowed("Connected") } else { Button("Set up", action: hub.calendar.connect) }
                }
                Divider()
                row("bell", "Notifications", "Rings your reminders while Perch is quit.") {
                    switch hub.notificationStatus {
                    case .authorized, .provisional, .ephemeral: allowed("Allowed")
                    case .denied: Button("Open Settings", action: AppHub.openNotificationSettings)
                    default: Button("Set up", action: hub.requestNotifications)
                    }
                }
                Divider()
                row("camera.viewfinder", "Screenshots", "Keeps new screenshots and screen recordings in Clips. macOS asks for the folder they're saved in, usually the Desktop.") {
                    if hub.workspace.data.settings.captureScreenshots {
                        allowed("On")
                    } else {
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
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func allowed(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
    }
}
