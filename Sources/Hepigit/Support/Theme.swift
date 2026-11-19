import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

enum Theme {
    // Surfaces: aubergine-black, layered by lightness, never by borders alone.
    static let bg = Color(hex: 0x120F12)
    static let panel = Color(hex: 0x17131A)
    static let raised = Color(hex: 0x211B22)
    static let hover = Color(hex: 0x2A222B)
    static let line = Color(hex: 0x2C242C)

    // Ink: bone and stone.
    static let text = Color(hex: 0xEDE6DD)
    static let text2 = Color(hex: 0xA99E97)
    static let text3 = Color(hex: 0x6F6560)

    // Accents, used sparingly.
    static let accent = Color(hex: 0xB0466A)       // burgundy rose
    static let accentDeep = Color(hex: 0x5C1E36)
    static let olive = Color(hex: 0x9AA56A)
    static let gold = Color(hex: 0xC9A35F)
    static let danger = Color(hex: 0xD0596B)
    static let info = Color(hex: 0x8C9FC4)

    /// Lane colours: muted jewel tones, distinct but quiet.
    static let lanes: [Color] = [
        Color(hex: 0xC25B7C), Color(hex: 0x9AA66B), Color(hex: 0xC9A35F), Color(hex: 0x6FA3A6),
        Color(hex: 0x9B87C4), Color(hex: 0xC47A5A), Color(hex: 0x7FA68A), Color(hex: 0x7C93C2),
    ]
    static func lane(_ i: Int) -> Color { lanes[i % lanes.count] }

    static func statusColor(_ code: Character) -> Color {
        switch code {
        case "A", "?": return olive
        case "D": return danger
        case "R", "C": return info
        case "U": return gold
        default: return gold.opacity(0.85)
        }
    }

    static func statusGlyph(_ code: Character) -> String {
        switch code {
        case "A", "?": return "plus"
        case "D": return "minus"
        case "R", "C": return "arrow.right"
        case "U": return "exclamationmark"
        default: return "pencil"
        }
    }

    static let serif = Font.system(size: 15, weight: .medium, design: .serif)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

// MARK: - Small shared components

/// Press feedback: a soft squash, the same everywhere.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Icon button with a hover plate. Always has a tooltip, since it has no label.
struct IconButton: View {
    let icon: String
    let help: String
    var tint: Color = Theme.text2
    var size: CGFloat = 22
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.hover : .clear))
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(help)
    }
}

/// Primary / secondary text button.
struct PillButton: View {
    let title: String
    var icon: String? = nil
    var primary = false
    var destructive = false
    var busy = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini).tint(Theme.text) }
                else if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14).frame(height: 30)
            .foregroundStyle(primary || destructive ? Color.white : Theme.text)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary || destructive ? .clear : Theme.line))
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PressStyle())
        .disabled(disabled || busy)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }

    private var fill: Color {
        if destructive { return hover ? Theme.danger : Theme.danger.opacity(0.85) }
        if primary { return hover ? Theme.accent : Theme.accent.opacity(0.88) }
        return hover ? Theme.hover : Theme.raised
    }
}

struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 18

    var body: some View {
        let seed = email.lowercased().unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        let hue = Double(seed % 360) / 360
        Circle()
            .fill(Color(hue: hue, saturation: 0.32, brightness: 0.48))
            .overlay(Text(initials).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(Theme.text))
            .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)) }.joined().uppercased()
    }
}

struct SectionLabel: View {
    let text: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.1)
            if let count { Text(verbatim: "\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3) }
        }
        .foregroundStyle(Theme.text3)
    }
}

/// Hover background for list rows.
struct HoverRow: ViewModifier {
    var selected = false
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.accentDeep.opacity(0.75) : hover ? Theme.hover.opacity(0.7) : .clear))
            .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
    }
}

extension View {
    func hoverRow(selected: Bool = false) -> some View { modifier(HoverRow(selected: selected)) }
}

enum RelTime {
    static func short(_ d: Date) -> String {
        let s = -d.timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 30 { return "\(Int(s / 86400))d" }
        if s < 86400 * 365 { return "\(Int(s / (86400 * 30)))mo" }
        return "\(Int(s / (86400 * 365)))y"
    }
    static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}
