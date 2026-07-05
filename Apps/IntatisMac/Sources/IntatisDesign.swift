//
//  IntatisDesign.swift
//  IntatisMac
//
//  The Intatis Mac design system: a deliberately restrained champagne-gold accent
//  (paler & lower-chroma than iPhone gold) over warm neutral surfaces, in a
//  liquid-glass material language. The token *shape* mirrors the Vela family
//  (Rokurics) so the apps feel related, but the palette is unique to Intatis —
//  gold is used only as a sparing accent; the large surfaces stay neutral + glass.
//

#if canImport(SwiftUI)
import SwiftUI
import IntatisSharedUI

// MARK: - Color tokens

enum IntatisTheme {
    // Champagne gold accent.
    static let gold     = Color(red: 0.788, green: 0.659, blue: 0.416) // #C9A86A
    static let goldSoft = Color(red: 0.847, green: 0.745, blue: 0.525) // #D8BE86 — gradient top / highlight
    static let goldDeep = Color(red: 0.710, green: 0.576, blue: 0.310) // #B5934F — pressed / emphasis
    static let sand     = Color(red: 0.937, green: 0.902, blue: 0.824) // #EFE6D2 — pale fill / user-bubble tint

    // Warm ink text, three weights, scheme-aware.
    static func deepText(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.925, green: 0.894, blue: 0.831)   // #ECE4D4
                   : Color(red: 0.169, green: 0.149, blue: 0.125)   // #2B2620
    }
    static func softText(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.678, green: 0.635, blue: 0.533)   // #ADA288
                   : Color(red: 0.478, green: 0.439, blue: 0.392)   // #7A7064
    }
    static func tertiaryText(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.431, green: 0.396, blue: 0.322)
                   : Color(red: 0.659, green: 0.620, blue: 0.549)
    }

    // Glass surfaces.
    static func glassSurface(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.105, green: 0.094, blue: 0.067) : .white
    }
    static func glassStroke(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.553, green: 0.463, blue: 0.282)  // muted gold edge
                   : Color(red: 0.945, green: 0.918, blue: 0.847)  // warm cream edge
    }
    static func shadow(_ s: ColorScheme) -> Color {
        s == .dark ? .black : Color(red: 0.710, green: 0.612, blue: 0.420)
    }

    // Gradients.
    static let accentGradient = LinearGradient(
        colors: [goldSoft, gold], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func pageGradient(_ s: ColorScheme) -> LinearGradient {
        if s == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.090, green: 0.082, blue: 0.059),   // #17150F
                    Color(red: 0.122, green: 0.110, blue: 0.078),   // #1F1C14
                    Color(red: 0.102, green: 0.090, blue: 0.063)],  // #1A1710
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(
            colors: [
                Color(red: 0.984, green: 0.976, blue: 0.957),       // #FBF9F4
                Color(red: 0.957, green: 0.937, blue: 0.890),       // #F4EFE3
                Color(red: 0.980, green: 0.965, blue: 0.933)],      // #FAF6EE
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Typography
//
// English brand & titles take a serif voice (an editorial nod shared with the
// Vela family); body / Chinese stay on the system font; code, paths and other
// technical tokens use a monospaced voice.

enum IntatisType {
    static func brand(_ size: CGFloat = 30, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .serif) }
    static func largeTitle(_ size: CGFloat = 30, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .serif) }
    static func title(_ size: CGFloat = 20, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .serif) }
    static func headline(_ size: CGFloat = 16, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w) }
    static func body(_ size: CGFloat = 14, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w) }
    static func caption(_ size: CGFloat = 12, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w) }
    static func mono(_ size: CGFloat = 13, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .monospaced) }
    static func chat(_ size: CGFloat = 15, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w) }
}

extension IntatisThreadStyle {
    static func intatisMac(_ scheme: ColorScheme) -> IntatisThreadStyle {
        IntatisThreadStyle(
            primaryText: IntatisTheme.deepText(scheme),
            secondaryText: IntatisTheme.softText(scheme),
            tertiaryText: IntatisTheme.tertiaryText(scheme),
            accent: IntatisTheme.goldDeep,
            accentSoft: IntatisTheme.goldSoft.opacity(scheme == .dark ? 0.24 : 0.45),
            surface: IntatisTheme.glassSurface(scheme),
            stroke: IntatisTheme.glassStroke(scheme).opacity(scheme == .dark ? 0.50 : 0.85),
            userBubble: IntatisTheme.sand.opacity(scheme == .dark ? 0.16 : 0.85),
            assistantBubble: IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.30 : 0.70),
            cardSurface: IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.28 : 0.64),
            cardStroke: IntatisTheme.glassStroke(scheme).opacity(scheme == .dark ? 0.40 : 0.70),
            warningSurface: IntatisTheme.goldSoft.opacity(scheme == .dark ? 0.16 : 0.20),
            warningStroke: IntatisTheme.gold.opacity(scheme == .dark ? 0.32 : 0.42),
            error: .red,
            material: .ultraThinMaterial)
    }
}

// MARK: - Liquid-glass material

private struct IntatisGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let cornerRadius: CGFloat
    let material: Material
    let fillOpacity: Double
    let strokeOpacity: Double
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill = scheme == .dark ? min(fillOpacity * 0.82, 0.40) : fillOpacity
        let stroke = scheme == .dark ? min(strokeOpacity * 0.72, 0.34) : strokeOpacity
        content
            .background { shape.fill(IntatisTheme.glassSurface(scheme).opacity(fill)) }
            .background(material, in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(stroke),
                            IntatisTheme.glassStroke(scheme).opacity(stroke * 0.62),
                            IntatisTheme.gold.opacity(scheme == .dark ? 0.22 : 0.15)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
            .shadow(
                color: IntatisTheme.shadow(scheme).opacity(scheme == .dark ? max(shadowOpacity * 0.5, 0.08) : shadowOpacity),
                radius: shadowRadius, x: 0, y: shadowY)
    }
}

private struct IntatisGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let material: Material
    let fillOpacity: Double
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        let fill = scheme == .dark ? min(fillOpacity * 0.82, 0.40) : fillOpacity
        let stroke = scheme == .dark ? min(strokeOpacity * 0.72, 0.34) : strokeOpacity
        content
            .background { Capsule(style: .continuous).fill(IntatisTheme.glassSurface(scheme).opacity(fill)) }
            .background(material, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous).stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(stroke), IntatisTheme.gold.opacity(stroke * 0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
    }
}

extension View {
    func intatisGlassCard(cornerRadius: CGFloat = 22,
                          material: Material = .ultraThinMaterial,
                          fillOpacity: Double = 0.50,
                          strokeOpacity: Double = 0.50,
                          shadowOpacity: Double = 0.10,
                          shadowRadius: CGFloat = 16,
                          shadowY: CGFloat = 9) -> some View {
        modifier(IntatisGlassCardModifier(
            cornerRadius: cornerRadius, material: material,
            fillOpacity: fillOpacity, strokeOpacity: strokeOpacity,
            shadowOpacity: shadowOpacity, shadowRadius: shadowRadius, shadowY: shadowY))
    }

    func intatisGlassCapsule(material: Material = .ultraThinMaterial,
                             fillOpacity: Double = 0.44,
                             strokeOpacity: Double = 0.40) -> some View {
        modifier(IntatisGlassCapsuleModifier(
            material: material, fillOpacity: fillOpacity, strokeOpacity: strokeOpacity))
    }
}

// MARK: - Shared header

/// Page header: a serif title + soft subtitle. Deliberately icon-free — the title
/// carries the screen on its own (matching the Vela family's title-only headers).
struct IntatisPageHeader: View {
    let title: String
    var subtitle: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(IntatisType.largeTitle(30))
                .foregroundStyle(IntatisTheme.deepText(scheme))
            if let subtitle {
                Text(subtitle)
                    .font(IntatisType.caption(13, .medium))
                    .foregroundStyle(IntatisTheme.softText(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
