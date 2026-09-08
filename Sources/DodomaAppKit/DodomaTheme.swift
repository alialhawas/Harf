import SwiftUI

/// The app's visual language, in one place.
///
/// The default SwiftUI `Form` on macOS reads as a system preferences pane, which
/// is fine and anonymous. These values give the windows an identity of their
/// own: a near-black canvas, one teal accent, and glass cards that let the
/// starfield show through instead of covering it.
enum DodomaTheme {
    static let canvas = Color(red: 0.043, green: 0.055, blue: 0.075)
    static let accent = Color(red: 0.357, green: 0.761, blue: 0.671)
    static let cardFill = Color.white.opacity(0.025)
    static let cardStroke = Color.white.opacity(0.08)
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.60)
    static let muted = Color.white.opacity(0.38)
}

/// A translucent panel that sits over the starfield.
struct GlassCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(1.6)
                    .foregroundStyle(DodomaTheme.accent.opacity(0.9))
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DodomaTheme.cardFill)
                .background(.ultraThinMaterial.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DodomaTheme.cardStroke, lineWidth: 1))
    }
}
