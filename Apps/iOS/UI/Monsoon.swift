import SwiftUI

/// The Monsoon look: rain-dark slate, wet-leaf teal, a flash of violet,
/// and Liquid Glass with enough frost under every word to read it over
/// anything. Every iPhone screen takes its colours and surfaces from here.
enum Monsoon {
    static let ground = Color(hex: 0x0A1E28)
    static let ink = Color(hex: 0xF1FBFA)
    static let ink2 = ink.opacity(0.74)
    static let ink3 = ink.opacity(0.66)   // 4.5:1 on ground and band (measured)
    static let accent = Color(hex: 0x7FE0D0)
    /// Text and symbols on `accent`.
    static let accentInk = Color(hex: 0x06231F)
    static let accentSoft = accent.opacity(0.18)
    /// Small capitals above a section ("NOW").
    static let label = Color(hex: 0x9FEBDF)
    /// The frost under the band's glass.
    static let bandFrost = Color(hex: 0x0C2E38).opacity(0.62)
    /// Specular edges of glass.
    static let edge = Color(hex: 0xAAFFF0).opacity(0.5)
    static let shadow = Color.black.opacity(0.5)
    static let lightning = Color(hex: 0x6C5CE7)
    static let leaf = Color(hex: 0x1F8A8A)
    /// A second light, for things that are not speech (alerts, a shout's echo).
    static let violet = Color(hex: 0xA99BFF)
    /// Decorative strokes only (rulers, threads); never for words.
    static let dim = ink.opacity(0.28)

    /// Caption sizes the user can pinch between (points).
    static let captionSizes: ClosedRange<Double> = 22...48
    static let defaultCaptionSize = 31.0
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The ground every screen sits on: slate with soft light from leaf, rain
/// and lightning behind the glass. With Reduce Transparency, plain slate.
struct MonsoonBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Monsoon.ground
            if !reduceTransparency {
                GeometryReader { proxy in
                    let size = proxy.size
                    Circle().fill(Monsoon.leaf).frame(width: 380, height: 300)
                        .blur(radius: 80).opacity(0.5)
                        .position(x: 50, y: size.height * 0.28)
                    Circle().fill(Monsoon.accent).frame(width: 300, height: 220)
                        .blur(radius: 70).opacity(0.5)
                        .position(x: size.width - 40, y: size.height * 0.52)
                    Circle().fill(Monsoon.lightning).frame(width: 320, height: 300)
                        .blur(radius: 90).opacity(0.5)
                        .position(x: size.width * 0.55, y: size.height + 20)
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// The reading band's surface: full-width frosted Liquid Glass with lit
    /// top and bottom edges. Opaque slate when Reduce Transparency is on.
    func monsoonBand() -> some View {
        modifier(BandSurface())
    }

    /// A small glass control (chip, round button) on the Monsoon ground.
    func monsoonChip<S: InsettableShape>(in shape: S) -> some View {
        modifier(ChipSurface(shape: shape))
    }

    /// Small spaced capitals used for section labels ("NOW", "EARLIER").
    func monsoonLabel() -> some View {
        font(.system(size: 12, weight: .heavy)).tracking(2).foregroundStyle(Monsoon.label)
    }
}

private struct BandSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Color(hex: 0x123540)
                } else {
                    Monsoon.bandFrost
                        .glassEffect(.regular.tint(Monsoon.bandFrost), in: Rectangle())
                }
            }
            .overlay(alignment: .top) { Monsoon.edge.frame(height: 1) }
            .overlay(alignment: .bottom) { Monsoon.edge.frame(height: 1) }
            .shadow(color: Monsoon.shadow, radius: 35, y: 30)
    }
}

private struct ChipSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Monsoon.ink)
            .background {
                if reduceTransparency {
                    shape.fill(Color(hex: 0x1A3C48))
                } else {
                    shape.fill(.white.opacity(0.1))
                        .glassEffect(.regular.interactive(), in: shape)
                }
            }
            .overlay { shape.strokeBorder(Monsoon.edge.opacity(0.6), lineWidth: 1) }
    }
}

// MARK: Light, line and letter
//
// The iPhone app draws no pills, tiles or round buttons. A control is its
// glyph — a letter, a line icon, a streak of light — lit when on, with an
// invisible 44 pt hit area. These are the pieces every screen builds from.

extension View {
    /// The accent glow that marks something as lit (on, chosen, live).
    func monsoonGlow(_ colour: Color = Monsoon.accent, radius: CGFloat = 8) -> some View {
        shadow(color: colour.opacity(0.85), radius: radius).shadow(color: colour, radius: 1)
    }
}

/// A control drawn as nothing but its content: no shape behind it.
/// Always at least 44 × 44 points to touch.
struct GlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlyphButtonStyle {
    static var glyph: GlyphButtonStyle { GlyphButtonStyle() }
}

/// A thin horizontal rule of light that fades out at both ends.
struct LightRule: View {
    var colour: Color = Monsoon.edge

    var body: some View {
        LinearGradient(colors: [.clear, colour, .clear], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The bar of light under a lit glyph (a chosen language, a sound that is on).
struct LitBar: View {
    let isLit: Bool
    var width: CGFloat = 24

    var body: some View {
        Rectangle()
            .fill(isLit ? Monsoon.accent : .clear)
            .frame(width: width, height: 2)
            .monsoonGlow(isLit ? Monsoon.accent : .clear, radius: 6)
            .accessibilityHidden(true)
    }
}

/// A line icon that is either lit (accent, glowing, bar beneath) or dark.
struct LitGlyph: View {
    let systemImage: String
    let isLit: Bool
    var size: CGFloat = 28

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isLit ? Monsoon.accent : Monsoon.ink3)
                .monsoonGlow(isLit ? Monsoon.accent : .clear, radius: 6)
            LitBar(isLit: isLit, width: size)
        }
    }
}
