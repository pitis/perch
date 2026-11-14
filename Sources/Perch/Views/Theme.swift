import AppKit
import PerchCore
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: alpha)
    }
}

struct Theme {
    let bw: Bool

    static let accent = Color(hex: 0xE9973F)
    static let surface = Color(hex: Palette.surface)
    static let surfaceRaised = Color(hex: 0x333333)

    func card(_ kind: CardConfig.Kind) -> Color {
        Color(hex: bw ? Palette.surface : Palette.card(kind))
    }

    private var palette: Palette.Ink { bw ? Palette.onDark : Palette.onCards }
    private var inkBase: Color { Color(hex: palette.base) }
    var ink: Color { inkBase.opacity(palette.ink) }
    /// Secondary text.
    var ink2: Color { inkBase.opacity(palette.ink2) }
    /// Lines, handles and chart bars. Too light for text.
    var ink3: Color { inkBase.opacity(palette.ink3) }
    var wash: Color { inkBase.opacity(palette.wash) }
    var washStrong: Color { inkBase.opacity(palette.washStrong) }
    /// Missed dates.
    var alert: Color { Color(hex: palette.alert) }
    var scheme: ColorScheme { bw ? .dark : .light }
}

/// Fine noise so the cards read as paper instead of flat fills. Generated once and tiled.
private enum Grain {
    static let image: NSImage = {
        let size = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 2,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        var generator = SystemRandomNumberGenerator()
        for y in 0..<size {
            for x in 0..<size {
                let light = Bool.random(using: &generator)
                let alpha = CGFloat.random(in: 0...0.09, using: &generator)
                rep.setColor(NSColor(deviceWhite: light ? 1 : 0, alpha: alpha), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: size / 2, height: size / 2))
        image.addRepresentation(rep)
        return image
    }()
}

extension View {
    func paper(_ color: Color, grain: Bool = true, radius: CGFloat = 16) -> some View {
        background {
            ZStack {
                color
                if grain {
                    Image(nsImage: Grain.image).resizable(resizingMode: .tile)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    func dottedDivider(_ color: Color) -> some View {
        overlay(alignment: .bottom) {
            Line().stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 3.4])).frame(height: 1)
        }
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + topRadius, y: r.minY + topRadius), control: CGPoint(x: r.minX + topRadius, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + topRadius, y: r.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: r.minX + topRadius + bottomRadius, y: r.maxY), control: CGPoint(x: r.minX + topRadius, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topRadius - bottomRadius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - topRadius, y: r.maxY - bottomRadius), control: CGPoint(x: r.maxX - topRadius, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topRadius, y: r.minY + topRadius))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - topRadius, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Text drawn as a 5×7 dot matrix.
struct DotText: View {
    let text: String
    var pitch: CGFloat = 4
    var maxWidth: CGFloat?
    var color: Color = .white

    private static let glyphs: [Character: [String]] = [
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
        ":": [".", ".", "#", ".", "#", ".", "."],
        " ": ["..", "..", "..", "..", "..", "..", ".."],
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "##..#", "#.#.#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
    ]

    private var columns: Int {
        max(1, text.reduce(0) { $0 + (Self.glyphs[$1]?.first?.count ?? 0) + 1 } - 1)
    }

    var body: some View {
        let unit = maxWidth.map { min(pitch, $0 / CGFloat(columns)) } ?? pitch
        Canvas { context, _ in
            var x: CGFloat = 0
            for character in text {
                guard let glyph = Self.glyphs[character] else { continue }
                for (row, line) in glyph.enumerated() {
                    for (column, value) in line.enumerated() where value == "#" {
                        let dot = CGRect(x: x + CGFloat(column) * unit, y: CGFloat(row) * unit, width: unit * 0.74, height: unit * 0.74)
                        context.fill(Path(ellipseIn: dot), with: .color(color))
                    }
                }
                x += CGFloat((glyph.first?.count ?? 0) + 1) * unit
            }
        }
        .frame(width: CGFloat(columns) * unit, height: 7 * unit)
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

/// The large timer readout in whichever clock style is selected.
struct ClockFace: View {
    let text: String
    let style: ClockStyle
    let color: Color
    var maxWidth: CGFloat = 140

    var body: some View {
        switch style {
        case .dots:
            DotText(text: text, pitch: 4.4, maxWidth: maxWidth, color: color)
        case .mono:
            Text(text)
                .font(.system(size: 34, weight: .light, design: .monospaced))
                .minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(color)
        case .rounded:
            Text(text)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(color)
        }
    }
}

/// A small icon button with a hover state and a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    var color: Color
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .frame(width: size + 10, height: size + 10)
                .background(hovering ? color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// `< 7 Nov >`, shared by the tasks and Notepad. Clicking the date jumps back to today.
struct DayNavigator: View {
    @Environment(AppHub.self) private var hub

    var body: some View {
        let theme = hub.theme
        let cal = hub.workspace.calendar
        let day = hub.ui.selectedDay
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", help: "Previous day", color: theme.ink2, size: 10) {
                hub.ui.selectedDay = Day.adding(-1, to: day, calendar: cal)
            }
            Button {
                hub.ui.selectedDay = hub.workspace.today
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.system(size: 10))
                    Text(Day.format(day, "d MMM", calendar: cal)).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.ink2)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(theme.wash, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Go to today")
            IconButton(symbol: "chevron.right", help: "Next day", color: theme.ink2, size: 10) {
                hub.ui.selectedDay = Day.adding(1, to: day, calendar: cal)
            }
        }
    }
}
