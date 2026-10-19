import SwiftUI

// MARK: - 1 · Welcome

struct WelcomeStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.accent) private var accent
    @Environment(\.onboardingLayout) private var layout

    var body: some View {
        OnboardingScreen(title: "Caloma", subtitle: "Run the house together, and make chores something kids want to do.", centered: true) {
            WelcomeArt(size: layout.isShort ? 150 : (layout.isRegular ? 230 : 190))
        } content: {
            VStack(alignment: .leading, spacing: layout.isShort ? 14 : 18) {
                OnboardingFeatureRow(symbol: "checklist", color: accent, title: "Chores kids love", detail: "Big buttons, confetti and a progress ring. You give the OK.")
                OnboardingFeatureRow(symbol: "gift.fill", color: Brand.star, title: "Rewards your way", detail: "Screen time, outings or allowance. You set the prices.")
                OnboardingFeatureRow(symbol: "house.fill", color: Color(hex: 0x0A84FF), title: "One calendar, one home", detail: "Everyone's week, home care and the lights, together.")
                OnboardingFeatureRow(symbol: "icloud.fill", color: Color(hex: 0x1E9E6A), title: "Private by design", detail: "Your family lives in your own iCloud. No ads, no servers.")
            }
            .padding(.horizontal, 4)
        } controls: {
            // Starting a household or joining the family's is the next step.
            OnboardingPrimaryButton(title: "Get Started", action: flow.next)
        }
    }
}

/// The app icon with the family floating around it: colored avatars, a star and a check.
private struct WelcomeArt: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Orbiter: Identifiable {
        var id: Int
        var symbol: String
        var color: Color
        /// Where it sits, as a fraction of the art's size from its center.
        var x: CGFloat
        var y: CGFloat
        var diameter: CGFloat
        var period: Double
    }

    private var orbiters: [Orbiter] {
        [
            Orbiter(id: 0, symbol: "person.fill", color: KidColor.teal.color, x: -0.40, y: 0.16, diameter: 0.22, period: 3.6),
            Orbiter(id: 1, symbol: "person.fill", color: KidColor.purple.color, x: 0.40, y: -0.04, diameter: 0.24, period: 4.2),
            Orbiter(id: 2, symbol: "person.fill", color: KidColor.blue.color, x: -0.30, y: -0.36, diameter: 0.18, period: 4.8),
            Orbiter(id: 3, symbol: "checkmark", color: Color(hex: 0x1E9E6A), x: 0.36, y: 0.38, diameter: 0.17, period: 3.9),
            Orbiter(id: 4, symbol: "star.fill", color: Brand.star, x: 0.30, y: -0.42, diameter: 0.12, period: 3.3),
        ]
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                AppIconBadge(size: size * 0.5)
                ForEach(orbiters) { orbiter in
                    let bob = reduceMotion ? 0 : sin(time * 2 * .pi / orbiter.period + Double(orbiter.id)) * 5
                    Image(systemName: orbiter.symbol)
                        .font(.system(size: size * orbiter.diameter * 0.45, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * orbiter.diameter, height: size * orbiter.diameter)
                        .background(orbiter.color.gradient, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2.5))
                        .shadow(color: orbiter.color.opacity(0.35), radius: 8, y: 4)
                        .offset(x: orbiter.x * size, y: orbiter.y * size + bob)
                }
            }
        }
        .frame(width: size * 1.15, height: size)
        .accessibilityHidden(true)
    }
}
