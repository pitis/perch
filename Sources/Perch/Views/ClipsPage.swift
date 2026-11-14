import AppKit
import PerchCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Screenshots, recordings and copied items, hung on a line.
struct ClipsPage: View {
    @Environment(AppHub.self) private var hub

    var body: some View {
        let clips = hub.clips.clips
        VStack(spacing: 6) {
            if clips.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 24)).foregroundStyle(.white.opacity(0.4))
                    Text("Copy something and it hangs here.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    Text("You can also drag a file onto the notch.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    screenshotsButton.padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(clips) { ClipCard(clip: $0) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .background(alignment: .top) {
                        Rectangle().fill(.white.opacity(0.35)).frame(height: 1).padding(.top, 15)
                    }
                }
                .frame(maxHeight: .infinity)
                HStack {
                    screenshotsButton
                    Spacer()
                    Text("Click to copy · Double-click to open · Drag to move or share · ⌘V to paste")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("Clear all", action: hub.clips.removeAll)
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 10)
            }
        }
        .onAppear(perform: hub.clips.pruneMissing)
    }

    @ViewBuilder
    private var screenshotsButton: some View {
        if !hub.workspace.data.settings.captureScreenshots {
            Button {
                hub.workspace.data.settings.captureScreenshots = true
                hub.clips.updateScreenshotWatcher()
            } label: {
                Text("Show screenshots here")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("macOS asks once for access to your Desktop folder, where screenshots are saved")
        }
    }
}

private struct ClipCard: View {
    @Environment(AppHub.self) private var hub
    let clip: Clip
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private static let size = CGSize(width: 236, height: 158)

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                face
                    .frame(width: Self.size.width, height: Self.size.height)
                    .background(clip.text == nil ? Color(hex: 0xF2F2F2) : Color(hex: 0xFBF0A8))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.5)))
                if hovering {
                    Button { hub.clips.remove(clip) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Remove clip")
                }
            }
            .overlay(alignment: .top) {
                HStack {
                    pin
                    Spacer()
                    pin
                }
                .padding(.horizontal, 10)
                .offset(y: -6)
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .frame(width: Self.size.width)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { hub.clips.open(clip) }
        .onTapGesture { hub.clips.copy(clip) }
        .onDrag { hub.clips.dragProvider(for: clip) }
        .contextMenu {
            Button("Copy") { hub.clips.copy(clip) }
            Button("Open") { hub.clips.open(clip) }
            Divider()
            Button("Remove") { hub.clips.remove(clip) }
        }
        .task(id: clip.id) { await loadThumbnail() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clip.kind.rawValue) clip: \(clip.title)")
        .accessibilityAddTraits(.isButton)
    }

    private var pin: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: 0xC9A36A)).frame(width: 5, height: 14)
    }

    @ViewBuilder
    private var face: some View {
        if let text = clip.text {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x33302A))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
        } else if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if clip.kind == .recording {
                        Image(systemName: "play.circle.fill").font(.system(size: 22)).foregroundStyle(.white).shadow(radius: 3).padding(6)
                    }
                }
        } else {
            VStack(spacing: 4) {
                // The icon for the file's type, which macOS knows from the name alone, without reading the file.
                Image(nsImage: NSWorkspace.shared.icon(for: clip.url.flatMap { UTType(tag: $0.pathExtension, tagClass: .filenameExtension, conformingTo: nil) } ?? .data))
                    .resizable().frame(width: 48, height: 48)
                Text(clip.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.black.opacity(0.55))
            .padding(10)
        }
    }

    private var caption: String {
        let time = clip.createdAt.formatted(date: .omitted, time: .shortened)
        if let copied = clip.copiedAt, Date().timeIntervalSince(copied) < 60 { return "Copied · \(time)" }
        return time
    }

    private func loadThumbnail() async {
        // A file in a protected folder Perch hasn't been granted keeps its type icon: reading it could raise a prompt.
        guard thumbnail == nil, let url = clip.url, !hub.clips.mayPrompt(clip) else { return }
        // Off the main thread, so a slow volume or a protected place the list misses can't freeze the panel.
        let size = Self.size
        let image = await Task.detached {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .all)
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }.value
        if let image { thumbnail = image }
    }
}
