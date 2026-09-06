import SwiftUI

/// How the window should follow (or override) the system appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Theme {
    static let corner: CGFloat = 10
    static let cardCorner: CGFloat = 14
    static let gutter: CGFloat = 20

    /// Every accent is defined for both appearances. A single fixed colour either
    /// glares against a dark background or washes out against a light one, so each
    /// resolves through the view's current appearance.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        return Color(nsColor: NSColor(name: nil) { appearance in
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let accent = adaptive(
        light: NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.90, alpha: 1),
        dark: NSColor(calibratedRed: 0.47, green: 0.65, blue: 1.00, alpha: 1)
    )
    static let danger = adaptive(
        light: NSColor(calibratedRed: 0.80, green: 0.19, blue: 0.19, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.45, alpha: 1)
    )
    static let caution = adaptive(
        light: NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.05, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.33, alpha: 1)
    )
    static let success = adaptive(
        light: NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.31, alpha: 1),
        dark: NSColor(calibratedRed: 0.35, green: 0.83, blue: 0.55, alpha: 1)
    )

    /// The log is a terminal well, so it stays dark in both appearances and its text
    /// colours are fixed — an adaptive palette would resolve to dark-on-dark in Light.
    static let consoleBackground = adaptive(
        light: NSColor(calibratedWhite: 0.13, alpha: 1.0),
        dark: NSColor(calibratedWhite: 0.06, alpha: 1.0)
    )
    static let consoleText = Color(nsColor: NSColor(calibratedWhite: 0.90, alpha: 1))
    static let consoleMuted = Color(nsColor: NSColor(calibratedWhite: 0.58, alpha: 1))
    static let consoleAccent = Color(nsColor: NSColor(calibratedRed: 0.47, green: 0.65, blue: 1.00, alpha: 1))
    static let consoleSuccess = Color(nsColor: NSColor(calibratedRed: 0.35, green: 0.83, blue: 0.55, alpha: 1))
    static let consoleDanger = Color(nsColor: NSColor(calibratedRed: 1.00, green: 0.48, blue: 0.48, alpha: 1))
}

/// Stand-in for `@State`.
///
/// In the macOS 27 SDK `@State` is implemented as a macro, and that macro's plugin
/// ships only inside Xcode — so it cannot expand under Command Line Tools alone.
/// `@StateObject` predates macros and works fine, so view-local state lives in one
/// of these holders instead. Swap back to `@State` if this ever builds under Xcode.
final class Local<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Convenience for handing this to SwiftUI controls that want a `Binding`.
    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

/// Makes the window itself translucent.
///
/// Liquid Glass refracts whatever sits behind it. Against a flat opaque window it has
/// nothing to work with and renders as plain grey — which is exactly what "the glass
/// doesn't work" looks like. Clearing the window background lets the desktop through so
/// the effect is actually visible.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Applies Liquid Glass where the system provides it.
///
/// `glassEffect` is macOS 26 and later, and the package targets macOS 13, so every use
/// is gated. On older systems the panel falls back to the solid control background it
/// always had, which keeps a single code path for both looks.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat
    var tinted: Bool = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    tinted ? .regular.tint(Theme.accent.opacity(0.10)) : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

/// Groups adjacent glass elements so the system can blend them as one surface.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = Theme.cardCorner, tinted: Bool = false) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tinted: tinted))
    }

    /// Prominent actions pick up the glass button style where available.
    @ViewBuilder
    func glassAction(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// A titled panel. Everything in the window sits in one of these so the three tabs
/// read as the same app rather than three separate screens.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var accessory: AnyView?
    @ViewBuilder var content: () -> Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let accessory {
                        accessory
                    }
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

/// A small status pill — used for device state and per-partition outcomes.
struct StatusPill: View {
    var text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(filled ? 0.9 : 0.14))
            )
            .foregroundStyle(filled ? Color.white : color)
    }
}

/// A pulsing dot for live connection state.
struct LiveDot: View {
    var color: Color
    var active: Bool
    @StateObject private var pulse = Local(false)

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 6)
                    .scaleEffect(pulse.value ? 1.9 : 1.0)
                    .opacity(pulse.value ? 0 : 0.8)
            )
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulse.value = true
                }
            }
    }
}

extension View {
    @ViewBuilder
    func cardBackground() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.corner))
        } else {
            background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }
}
