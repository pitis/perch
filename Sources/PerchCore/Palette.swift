import Foundation

/// Perch's colours as numbers, so a test can check their contrast. `Theme` turns them into SwiftUI colours.
public enum Palette {
    public static let surface: UInt32 = 0x252525

    public static func card(_ kind: CardConfig.Kind) -> UInt32 {
        switch kind {
        case .tasks: 0x93B59C
        case .focus: 0xA39DC4
        case .notes: 0xBFB66E
        case .agenda: 0x98B5CF
        }
    }

    /// Text, lines and washes: one base colour at several opacities, plus the red for missed dates.
    public struct Ink: Sendable {
        public let base: UInt32
        public let ink, ink2, ink3, wash, washStrong: Double
        public let alert: UInt32
    }

    /// The cards are mid-tones, so secondary text needs 86% ink for 4.5:1 on them and their washes. `PaletteTests`
    /// checks every place text sits.
    public static let onCards = Ink(base: 0x1B1E1A, ink: 1, ink2: 0.86, ink3: 0.6, wash: 0.09, washStrong: 0.16, alert: 0x661509)
    /// Black & white mode and the Week columns.
    public static let onDark = Ink(base: 0xFFFFFF, ink: 0.92, ink2: 0.64, ink3: 0.36, wash: 0.1, washStrong: 0.18, alert: 0xFF8A7A)

    /// `color` drawn at `alpha` over `background`.
    public static func blend(_ color: UInt32, _ alpha: Double, over background: UInt32) -> UInt32 {
        [16, 8, 0].reduce(0) { result, shift in
            let top = Double((color >> shift) & 255), bottom = Double((background >> shift) & 255)
            return result | UInt32((top * alpha + bottom * (1 - alpha)).rounded()) << shift
        }
    }

    /// The WCAG 2 contrast ratio, from 1 to 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ c: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let v = Double((c >> shift) & 255) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
