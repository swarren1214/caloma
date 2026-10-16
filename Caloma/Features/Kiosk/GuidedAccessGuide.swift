import SwiftUI

/// Family › Family Board › Lock This iPad to Caloma: how to set up Guided Access, so the wall
/// stays on Caloma with no Home swipe, Control Center, notifications or Siri. Two parts: the
/// one-time setup in Settings, then the triple-click each time. A green banner shows while
/// Guided Access is running.
struct GuidedAccessGuide: View {
    /// A Guided Access session is running right now.
    var isRunning: Bool

    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if isRunning {
                Label("Guided Access is running. Triple-click the top button and enter its passcode to end it.", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x1E9E6A))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0x1E9E6A).opacity(0.12), in: .rect(cornerRadius: 14))
            }

            phase("ONCE, IN SETTINGS", symbol: "gearshape.fill") {
                step(1, "Open Guided Access") {
                    SettingsPath(parts: [
                        ("Settings", "gearshape.fill", Color(hex: 0x8E8E93)),
                        ("Accessibility", "accessibility", Color(hex: 0x0A84FF)),
                        ("Guided Access", "lock.fill", Color(hex: 0x0A84FF)),
                    ])
                }
                step(2, "Turn on Guided Access") {
                    detail("Then Passcode Settings › Set Guided Access Passcode. Pick one the kids don't know; it's separate from the parent PIN.")
                }
                step(3, "Turn on Accessibility Shortcut") {
                    detail("So a triple-click of the top button starts and ends it.")
                }
                step(4, "Set Display Auto-Lock to Never", isLast: true) {
                    detail("On the same screen, so the wall never goes to sleep mid-week.")
                }
            }

            phase("EACH TIME", symbol: "rectangle.inset.filled.and.person.filled") {
                step(5, "Start the Family Board") {
                    detail("With the button at the top of this page.")
                }
                step(6, "Triple-click the top button, then tap Start", isLast: true) {
                    TripleClick(accent: accent)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("To take the iPad back")
                        .font(.subheadline.weight(.semibold))
                    Text("Triple-click again and enter the Guided Access passcode. On an iPad with a Home button, triple-click that instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
        }
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(accent.gradient, in: .rect(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep the wall on Caloma")
                    .font(.headline)
                Text("Guided Access is built into iPadOS. While it's on, nobody can swipe home, pull down Control Center or notifications, or ask Siri, so little hands stay on the Family Board.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Pieces

    private func phase<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
            content()
        }
    }

    /// A numbered step on a line that runs down to the next one.
    private func step<Content: View>(_ number: Int, _ title: String, isLast: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(number.formatted())
                    .font(.footnote.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(accent, in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(accent.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 3)
                content()
            }
            .padding(.bottom, isLast ? 0 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)")
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Settings › Accessibility › Guided Access" as the Settings app shows it: small icon tiles.
private struct SettingsPath: View {
    var parts: [(name: String, symbol: String, color: Color)]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                HStack(spacing: 6) {
                    Image(systemName: part.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(part.color, in: .rect(cornerRadius: 5, style: .continuous))
                    Text(part.name)
                        .font(.footnote.weight(.semibold))
                    if index < parts.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map(\.name).joined(separator: ", then "))
    }
}

/// Three quick presses of the top button, drawn.
private struct TripleClick: View {
    var accent: Color

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(accent)
                        .frame(width: 18, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(accent.opacity(0.12), in: Capsule())
            Text("Click, click, click: then Start in the top right.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Press the top button three times quickly, then tap Start in the top right corner.")
    }
}
