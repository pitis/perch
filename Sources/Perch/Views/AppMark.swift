import AppKit
import SwiftUI

/// Perch's mark: a small bird on a branch, drawn in a 100×100 box. The app icon (`make icon`), the
/// menu bar, the panel header and the reminder card all use it. It's drawn here because an SF Symbol can't be an
/// app icon or logo.
struct PerchedBird: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var bird = Path()
        bird.move(to: p(90, 33)) // beak tip
        bird.addLine(to: p(78, 29))
        bird.addCurve(to: p(60, 25), control1: p(75, 18), control2: p(64, 21)) // crown
        bird.addCurve(to: p(38, 56), control1: p(54, 31), control2: p(44, 44)) // back, at the crown's angle
        bird.addLine(to: p(14, 74)) // tail
        bird.addLine(to: p(18, 78))
        bird.addLine(to: p(40, 66))
        bird.addCurve(to: p(60, 71), control1: p(44, 70), control2: p(52, 72)) // belly
        bird.addCurve(to: p(80, 44), control1: p(72, 70), control2: p(80, 58)) // chest
        bird.addCurve(to: p(79, 36), control1: p(80, 40), control2: p(80, 38)) // throat
        bird.closeSubpath()
        for x in [50.0, 58.0] {
            bird = bird.union(Path(roundedRect: CGRect(origin: p(x, 66), size: CGSize(width: 3.2 * s, height: 11 * s)), cornerRadius: 1.6 * s))
        }
        var branch = Path()
        branch.move(to: p(8, 80))
        branch.addQuadCurve(to: p(93, 74), control: p(52, 78.5))
        branch.addArc(center: p(93, 77), radius: 3 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        branch.addQuadCurve(to: p(8, 81.4), control: p(52, 83))
        branch.addArc(center: p(8, 80.7), radius: 0.7 * s, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        branch.closeSubpath()
        return bird.union(branch)
    }

    /// The bird and branch without the square, 15 points tall and cropped to its outline, as a template image so macOS tints
    /// it for light and dark menu bars.
    static var menuBarImage: NSImage {
        let bird = PerchedBird().path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let box = bird.boundingRect
        let scale = 15 / box.height
        let fitted = bird.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -box.minX, y: -box.minY))
        let image = NSImage(size: NSSize(width: ceil(box.width * scale), height: 15), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: fitted.cgPath).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Perch"
        return image
    }
}

/// The bird on Perch's gradient square, `side` points wide.
struct AppBadge: View {
    var side: CGFloat
    var shadow = false

    var body: some View {
        let square = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
        let mark = side * (side < 40 ? 0.84 : 0.62) // bigger in small badges, where detail is lost anyway
        square
            .fill(LinearGradient(colors: [Color(hex: 0xF3C9A0), Color(hex: 0xE9973F)], startPoint: .top, endPoint: .bottom))
            .overlay(square.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: side * 0.006))
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(shadow ? 0.28 : 0), radius: side * 0.017, y: side * 0.012)
            .overlay(
                ZStack {
                    PerchedBird().fill(LinearGradient(colors: [Color(hex: 0x4A3A72), Color(hex: 0x2E2347)], startPoint: .top, endPoint: .bottom))
                    Circle() // the eye, cut out so the square shows through
                        .frame(width: mark * 0.038, height: mark * 0.038)
                        .offset(x: mark * (0.715 - 0.5), y: mark * (0.285 - 0.5))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(width: mark, height: mark)
                .offset(y: side * -0.01)
            )
    }
}

/// The app icon on the macOS grid: an 824-point badge in a 1024-point canvas.
struct AppIconArt: View {
    var body: some View {
        AppBadge(side: 824, shadow: true).frame(width: 1024, height: 1024)
    }
}
