import AppKit
import SwiftUI

extension View {
    /// Makes the hosting window's background Liquid Glass (the same system
    /// NSGlassEffectView the caption window uses). Lists, forms and the
    /// sidebar keep their own panels on top, so text stays readable.
    ///
    /// Uses SwiftUI's window container background. An earlier version made
    /// the window itself clear and put glass inside it: that blocked
    /// dragging the window by its title bar and left text straight on the
    /// glass, hard to read (2026-09-30).
    func glassWindowBackground() -> some View {
        containerBackground(for: .window) { WindowBackdrop() }
    }
}

/// Glass normally; the standard solid window colour when the user asks for
/// less transparency or more contrast.
private struct WindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                GlassBackdrop()
                GlassFrost()
            }
        }
    }
}

/// The system glass material as a plain background view.
private struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = 0
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

/// A theme-coloured frost laid between Liquid Glass and text.
///
/// Clear glass takes on whatever is behind it: light-theme dark text became
/// unreadable over dark content (and the reverse in dark theme), reported
/// 2026-09-30. NSGlassEffectView's tintColor was too weak to fix it (black
/// text on dark grey over a black background, measured the same day), so
/// every glass surface, including the caption window, puts this frost
/// behind its text. The glass still refracts through it.
struct GlassFrost: View {
    static let opacity = 0.74

    var body: some View {
        Color(nsColor: .windowBackgroundColor).opacity(Self.opacity)
    }
}

extension ShapeStyle where Self == Color {
    /// Supporting text for glass windows. The system `.secondary` grey drops
    /// to faint grey-on-lilac over light-theme glass (reported 2026-09-30);
    /// a strong tint of the primary colour stays clearly readable while
    /// still reading as secondary. With Increase Contrast, `Color.primary`
    /// already resolves to its high-contrast variant.
    static var glassSecondary: Color { Color.primary.opacity(0.78) }
}
