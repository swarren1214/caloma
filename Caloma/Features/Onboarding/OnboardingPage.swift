import SwiftUI

/// The size onboarding has to work with, measured once by `OnboardingView` and read by every
/// screen, so iPhone, iPad portrait, iPad landscape and Split View each get the right layout.
struct OnboardingLayout: Equatable {
    var size: CGSize

    /// iPad landscape (or a big window): the title on the left, the screen's content on the right.
    var isWide: Bool { size.width >= 900 && size.width > size.height * 1.15 }
    /// iPad portrait, or anything wider than a phone: one column, with more room around it.
    var isRegular: Bool { size.width >= 600 }
    /// iPhone SE and friends: tighter spacing so the buttons stay on screen.
    var isShort: Bool { size.height < 760 }

    /// The readable column width on iPhone and iPad portrait.
    static let columnWidth: CGFloat = 560
    /// The right-hand pane on a wide screen.
    var paneWidth: CGFloat { min(580, size.width * 0.5) }
    var sideMargin: CGFloat { isRegular ? 32 : 20 }
}

extension EnvironmentValues {
    @Entry var onboardingLayout = OnboardingLayout(size: CGSize(width: 390, height: 844))
}

/// The layout every onboarding screen shares.
///
/// On iPhone and iPad portrait: the art, a large title and a line of promise at the top, the
/// screen's content under them in a readable column, and the buttons pinned to the bottom. On a
/// wide iPad: the art and title fill the left half, and the content and buttons sit in a pane on
/// the right, so nothing is stretched across a 13-inch screen.
struct OnboardingScreen<Art: View, Content: View, Controls: View>: View {
    var title: String
    var subtitle: String
    /// The welcome and "all set" screens center their title; the rest read left to right.
    var centered = false
    @ViewBuilder var art: () -> Art
    @ViewBuilder var content: () -> Content
    @ViewBuilder var controls: () -> Controls

    @Environment(\.onboardingLayout) private var layout

    init(
        title: String,
        subtitle: String,
        centered: Bool = false,
        @ViewBuilder art: @escaping () -> Art,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder controls: @escaping () -> Controls
    ) {
        self.title = title
        self.subtitle = subtitle
        self.centered = centered
        self.art = art
        self.content = content
        self.controls = controls
    }

    var body: some View {
        if layout.isWide {
            wide
        } else {
            column
        }
    }

    // MARK: Header

    private func header(large: Bool) -> some View {
        let alignment: HorizontalAlignment = centered || large ? .center : .leading
        let textAlignment: TextAlignment = centered || large ? .center : .leading
        return VStack(alignment: alignment, spacing: layout.isShort ? 6 : 10) {
            art()
                .padding(.bottom, layout.isShort ? 4 : 10)
            Text(title)
                .font(large ? .system(size: 44, weight: .bold) : .largeTitle.bold())
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(large ? .title3 : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: large ? 420 : nil)
        }
        .frame(maxWidth: .infinity, alignment: centered || large ? .center : .leading)
    }

    // MARK: iPhone and iPad portrait

    private var column: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: layout.isShort ? 18 : 28) {
                    header(large: false)
                    content()
                }
                .padding(.horizontal, layout.sideMargin)
                .padding(.top, layout.isShort ? 6 : (layout.isRegular ? 48 : 14))
                .padding(.bottom, 24)
                .frame(maxWidth: OnboardingLayout.columnWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollDismissesKeyboard(.interactively)

            controlsBar
                .frame(maxWidth: OnboardingLayout.columnWidth)
        }
    }

    private var controlsBar: some View {
        VStack(spacing: 6) {
            controls()
        }
        .padding(.horizontal, layout.sideMargin)
        .padding(.top, 10)
        .padding(.bottom, layout.isRegular ? 28 : 8)
    }

    // MARK: iPad landscape

    private var wide: some View {
        HStack(spacing: 0) {
            header(large: true)
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ScrollView {
                        content()
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollEdgeEffectStyle(.soft, for: .bottom)
                    .scrollDismissesKeyboard(.interactively)
                }
                controlsBar
            }
            .frame(width: layout.paneWidth)
            .padding(.trailing, 24)
        }
    }
}

// MARK: - Pieces

/// The big accent button at the bottom of an onboarding screen.
struct OnboardingPrimaryButton: View {
    var title: String
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}

/// The quieter button under the primary one: "Not now", "Later".
struct OnboardingSecondaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// The app icon, from Icon Composer's light and dark PNG exports (CalomaMark in the asset
/// catalog; re-export them when the icon changes).
struct AppIconBadge: View {
    var size: CGFloat = 92
    @Environment(\.accent) private var accent

    var body: some View {
        Image("CalomaMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: accent.opacity(0.3), radius: 15, y: 10)
            .accessibilityHidden(true)
    }
}

/// An onboarding screen's icon: an SF Symbol on the accent, rounded-square shape.
struct OnboardingSymbolIcon: View {
    var symbol: String
    var size: CGFloat = 64
    var color: Color?
    @Environment(\.accent) private var accent

    var body: some View {
        let tint = color ?? accent
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint.mix(with: .white, by: 0.15), tint.mix(with: .black, by: 0.2)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: size * 0.2237, style: .continuous)
            )
            .shadow(color: tint.opacity(0.3), radius: 12, y: 8)
            .accessibilityHidden(true)
    }
}

/// A row in an onboarding list: a colored symbol tile, bold title, a line of detail.
struct OnboardingFeatureRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The small caps label over a group of cards: "PARENTS", "KIDS".
struct OnboardingSectionLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The white (or dark gray) rounded card onboarding groups things on.
    func onboardingCard(cornerRadius: CGFloat = 22) -> some View {
        background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A card that's picked: an accent outline.
    func onboardingSelection(_ selected: Bool, color: Color, cornerRadius: CGFloat = 22) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(selected ? 1 : 0), lineWidth: 2)
        }
        .animation(.smooth(duration: 0.2), value: selected)
    }
}

/// A round check that fills with the accent when on, for checklists.
struct OnboardingCheck: View {
    var isOn: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color(.systemGray3), lineWidth: 2)
                .opacity(isOn ? 0 : 1)
            Circle()
                .fill(accent)
                .opacity(isOn ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.5)
        }
        .frame(width: 26, height: 26)
        .animation(.snappy(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}

/// A switch card: a colored tile, a title, a line of detail, and a toggle. A green tag under
/// the detail says what turning it on did ("Calendars allowed").
struct OnboardingSwitchCard: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String
    @Binding var isOn: Bool
    var tag: String?
    var tagColor: Color = Color(hex: 0x1E9E6A)

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isOn ? .white : color)
                    .frame(width: 44, height: 44)
                    .background(isOn ? color : color.opacity(0.15), in: .rect(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isOn, let tag {
                        Text(tag)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tagColor)
                            .padding(.horizontal, 9)
                            .frame(minHeight: 22)
                            .background(tagColor.opacity(0.14), in: Capsule())
                            .padding(.top, 4)
                            .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                    }
                }
            }
        }
        .tint(color)
        .padding(16)
        .onboardingCard()
        .onboardingSelection(isOn, color: color.opacity(0.55))
        .animation(.smooth(duration: 0.25), value: isOn)
        .animation(.smooth(duration: 0.25), value: tag)
    }
}
