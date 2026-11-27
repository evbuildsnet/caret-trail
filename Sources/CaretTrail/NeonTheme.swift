import AppKit
import SwiftUI

/// The look of the app icon (a neon caret with a curved light trail on deep navy), applied to the
/// settings window in the user's trail colour.
enum NeonTheme {
    /// Deep navy tinted by the trail colour, darker towards the bottom.
    static func background(_ color: NSColor) -> some View {
        let tint = color.usingColorSpace(.sRGB) ?? color
        let top = tint.blended(withFraction: 0.91, of: NSColor(srgbRed: 0.02, green: 0.03, blue: 0.08, alpha: 1)) ?? .black
        let bottom = tint.blended(withFraction: 0.965, of: NSColor(srgbRed: 0.01, green: 0.01, blue: 0.03, alpha: 1)) ?? .black
        return ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(nsColor: top), Color(nsColor: bottom)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(nsColor: color).opacity(0.09), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

extension NeonTheme {
    /// Checkboxes and sliders: the user's colour, half greyed and darkened, so they stay discreet.
    static func controlTint(_ color: NSColor) -> Color {
        let muted = (color.usingColorSpace(.sRGB) ?? color).blended(withFraction: 0.55, of: NSColor(white: 0.32, alpha: 1)) ?? color
        return Color(nsColor: muted)
    }
}

/// The icon's motif: a glowing caret bar and the tapered light trail curving into its foot.
struct NeonMark: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let barX = w * 0.82
            ZStack {
                // The trail: a thin wedge from far bottom-left that widens as it curves into the bar.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.97))
                    p.addQuadCurve(to: CGPoint(x: barX, y: h * 0.38), control: CGPoint(x: w * 0.74, y: h * 0.88))
                    p.addLine(to: CGPoint(x: barX, y: h * 0.84))
                    p.addQuadCurve(to: CGPoint(x: 0, y: h * 0.97), control: CGPoint(x: w * 0.6, y: h * 0.9))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [.clear, color.opacity(0.7), color, Color.white.opacity(0.9)],
                                     startPoint: .leading, endPoint: .trailing))
                .shadow(color: color, radius: w * 0.05)

                // The caret: a white core in a coloured glow.
                RoundedRectangle(cornerRadius: w * 0.03)
                    .fill(Color.white)
                    .frame(width: w * 0.06, height: h * 0.78)
                    .position(x: barX + w * 0.03, y: h * 0.5)
                    // Glow radii scale with the mark, so a small one stays crisp.
                    .shadow(color: color, radius: w * 0.02)
                    .shadow(color: color, radius: w * 0.06)
                    .shadow(color: color, radius: w * 0.13)
            }
        }
    }
}

/// A section: a faint glass panel with a thin glowing edge and a neon title.
struct NeonSection<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: color.opacity(0.35), radius: 3)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.2), lineWidth: 1))
        .shadow(color: color.opacity(0.08), radius: 8)
    }
}
