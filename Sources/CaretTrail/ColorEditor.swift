import AppKit
import SwiftUI

/// The trail colour being edited, as hue, saturation and brightness so the hue survives a trip
/// through grey, plus the hex text as typed.
final class ColorEditor: ObservableObject {
    @Published private(set) var hue: Double = 0
    @Published private(set) var saturation: Double = 1
    @Published private(set) var brightness: Double = 1
    @Published private(set) var hex = "#FFFFFF"
    var onChange: (NSColor) -> Void = { _ in }

    var color: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB) ?? .white
    }

    func load(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        if c.saturationComponent > 0 { hue = c.hueComponent }
        saturation = c.saturationComponent
        brightness = c.brightnessComponent
        hex = Self.hex(of: c)
    }

    func set(hue: Double? = nil, saturation: Double? = nil, brightness: Double? = nil) {
        if let hue { self.hue = min(max(hue, 0), 1) }
        if let saturation { self.saturation = min(max(saturation, 0), 1) }
        if let brightness { self.brightness = min(max(brightness, 0), 1) }
        hex = Self.hex(of: color)
        onChange(color)
    }

    /// Keeps the text as typed; applies it as soon as it reads as a colour (#RGB or #RRGGBB).
    func setHex(_ text: String) {
        hex = text
        guard let parsed = Self.parse(text) else { return }
        let keep = hue
        load(parsed)
        if parsed.saturationComponent == 0 { hue = keep }
        hex = text
        onChange(parsed)
    }

    static func hex(of color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    static func parse(_ text: String) -> NSColor? {
        var digits = text.trimmingCharacters(in: .whitespaces).uppercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// A web-editor style picker: saturation and brightness square, hue bar, hex field, swatches.
struct ColorEditorView: View {
    @ObservedObject var editor: ColorEditor

    private static let width: CGFloat = 228
    private static let presets = ["#FF2D95", "#B44CFF", "#6A5BFF", "#00A8FF", "#00E5FF",
                                  "#00FFA3", "#7CFF00", "#FFE600", "#FF8A00", "#FFFFFF"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            square
            hueBar
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: editor.color))
                    .frame(width: 28, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.25), lineWidth: 1))
                TextField("#RRGGBB", text: Binding(get: { editor.hex }, set: { editor.setHex($0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 96)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.self) { code in
                    let c = ColorEditor.parse(code)!
                    Button { editor.setHex(code) } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: c))
                            .frame(width: 19, height: 19)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(code)
                }
            }
        }
        .padding(12)
        .frame(width: Self.width + 24)
    }

    private var square: some View {
        let h = Self.width * 0.66
        return ZStack {
            Color(nsColor: NSColor(hue: editor.hue, saturation: 1, brightness: 1, alpha: 1))
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
            Circle()
                .stroke(.white, lineWidth: 2)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .frame(width: 12, height: 12)
                .position(x: editor.saturation * Self.width, y: (1 - editor.brightness) * h)
        }
        .frame(width: Self.width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            editor.set(saturation: g.location.x / Self.width, brightness: 1 - g.location.y / h)
        })
    }

    private var hueBar: some View {
        let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            Color(nsColor: NSColor(hue: $0, saturation: 1, brightness: 1, alpha: 1))
        }
        return ZStack(alignment: .leading) {
            LinearGradient(colors: hues, startPoint: .leading, endPoint: .trailing)
                .clipShape(Capsule())
            Circle()
                .fill(Color(nsColor: NSColor(hue: editor.hue, saturation: 1, brightness: 1, alpha: 1)))
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.6), radius: 1)
                .frame(width: 14, height: 14)
                .offset(x: editor.hue * (Self.width - 14))
        }
        .frame(width: Self.width, height: 14)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            editor.set(hue: (g.location.x - 7) / (Self.width - 14))
        })
    }
}
