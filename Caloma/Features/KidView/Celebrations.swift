import SwiftUI

// The little celebrations in Kid View. All plain SwiftUI shapes animated with offsets (the way
// Hearken's ConfettiView works), so they render anywhere and never block touches or VoiceOver.
// Callers skip them when Reduce Motion is on.

/// The colors confetti comes in, led by the kid's own.
func confettiColors(_ kid: Color) -> [Color] {
    [kid, Brand.starBright, Color(hex: 0xFF375F), Color(hex: 0x30D158), Color(hex: 0x64D2FF), Color(hex: 0xFF9F0A), Color(hex: 0xBF5AF2)]
}

/// A burst of confetti flying out from the middle of its frame, then falling away.
struct ConfettiBurst: View {
    var colors: [Color]
    var count = 28

    private struct Piece: Identifiable {
        let id: Int
        let dx: CGFloat
        let dy: CGFloat
        let spin: Double
        let size: CGSize
        let isCircle: Bool
        let color: Color
        let delay: Double
    }

    @State private var pieces: [Piece] = []
    @State private var burst = false

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Group {
                    if piece.isCircle {
                        Circle().fill(piece.color)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(piece.color)
                    }
                }
                .frame(width: piece.size.width, height: piece.size.height)
                .rotationEffect(.degrees(burst ? piece.spin : 0))
                .offset(x: burst ? piece.dx : 0)
                .animation(.timingCurve(0.15, 0.75, 0.3, 1, duration: 1.0).delay(piece.delay), value: burst)
                // Out fast, then a little gravity.
                .offset(y: burst ? piece.dy + 70 : 0)
                .animation(.timingCurve(0.2, 0.6, 0.6, 1, duration: 1.1).delay(piece.delay), value: burst)
                .opacity(burst ? 0 : 1)
                .animation(.easeIn(duration: 0.35).delay(0.75 + piece.delay), value: burst)
                .scaleEffect(burst ? 1 : 0.4)
                .animation(.spring(duration: 0.4, bounce: 0.5).delay(piece.delay), value: burst)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            pieces = (0..<count).map { index in
                let angle = Double(index) / Double(count) * 2 * .pi + Double.random(in: -0.15...0.15)
                let distance = CGFloat.random(in: 100...190)
                let circle = index % 3 == 0
                let width = CGFloat.random(in: 8...12)
                return Piece(
                    id: index,
                    dx: cos(angle) * distance,
                    dy: sin(angle) * distance - 50,
                    spin: .random(in: -360...360),
                    size: circle ? CGSize(width: width, height: width) : CGSize(width: width * 0.75, height: width * 1.5),
                    isCircle: circle,
                    color: colors.randomElement() ?? .yellow,
                    delay: Double(index % 4) * 0.025
                )
            }
            try? await Task.sleep(for: .milliseconds(20))
            burst = true
        }
    }
}

/// Confetti falling over the whole screen, for finishing every chore.
struct ConfettiRain: View {
    var colors: [Color]
    var count = 120

    private struct Piece: Identifiable {
        let id: Int
        let x: CGFloat
        let drift: CGFloat
        let delay: Double
        let duration: Double
        let spin: Double
        let flips: Double
        let size: CGSize
        let isCircle: Bool
        let color: Color
    }

    @State private var pieces: [Piece] = []
    @State private var falling = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(pieces) { piece in
                    Group {
                        if piece.isCircle {
                            Circle().fill(piece.color)
                        } else {
                            RoundedRectangle(cornerRadius: 1.5).fill(piece.color)
                        }
                    }
                    .frame(width: piece.size.width, height: piece.size.height)
                    .rotation3DEffect(.degrees(falling ? piece.flips : 0), axis: (x: 1, y: 0.4, z: 0))
                    .rotationEffect(.degrees(falling ? piece.spin : 0))
                    .position(x: piece.x * proxy.size.width + (falling ? piece.drift : 0), y: falling ? proxy.size.height + 60 : -30)
                    .animation(.easeIn(duration: piece.duration).delay(piece.delay), value: falling)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            pieces = (0..<count).map { index in
                let circle = Double.random(in: 0...1) < 0.25
                let width = CGFloat.random(in: 7...12)
                return Piece(
                    id: index,
                    x: .random(in: 0...1),
                    drift: .random(in: -70...70),
                    delay: .random(in: 0...1.2),
                    duration: .random(in: 2.4...3.6),
                    spin: .random(in: -540...540),
                    flips: .random(in: 360...1080),
                    size: circle ? CGSize(width: width * 0.8, height: width * 0.8) : CGSize(width: width, height: width * 1.6),
                    isCircle: circle,
                    color: colors.randomElement() ?? .yellow
                )
            }
            try? await Task.sleep(for: .milliseconds(30))
            falling = true
        }
    }
}

/// "+15" with a star, popping up and floating away.
struct FloatingPoints: View {
    var points: Int
    var color: Color

    @State private var risen = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: PointWords.current().symbol)
                .foregroundStyle(Brand.starBright)
            Text("+\(points)")
        }
        .font(.system(size: 34, weight: .heavy, design: .rounded))
        .foregroundStyle(color)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .scaleEffect(risen ? 1 : 0.5)
        .animation(.spring(duration: 0.35, bounce: 0.6), value: risen)
        .offset(y: risen ? -110 : 0)
        .animation(.easeOut(duration: 1.2), value: risen)
        .opacity(risen ? 0 : 1)
        .animation(.easeIn(duration: 0.4).delay(0.8), value: risen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(20))
            risen = true
        }
    }
}

/// Stars flying in an arc from a finished chore up to the star counter.
struct FlyingStars: View {
    var from: CGPoint
    var to: CGPoint
    var count = 5

    @State private var flying = false

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                let spread = CGFloat(index - count / 2) * 16
                let delay = 0.15 + Double(index) * 0.08
                Image(systemName: "star.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Brand.starBright)
                    .shadow(color: .orange.opacity(0.4), radius: 4)
                    .rotationEffect(.degrees(flying ? 320 : 0))
                    .scaleEffect(flying ? 0.45 : 1.3)
                    .animation(.easeIn(duration: 0.8).delay(delay), value: flying)
                    // Sideways eases out and upward eases in, which draws an arc.
                    .offset(x: flying ? to.x - from.x - spread : 0)
                    .animation(.easeOut(duration: 0.8).delay(delay), value: flying)
                    .offset(y: flying ? to.y - from.y : 0)
                    .animation(.easeIn(duration: 0.8).delay(delay), value: flying)
                    .opacity(flying ? 0.3 : 1)
                    .animation(.easeIn(duration: 0.2).delay(delay + 0.65), value: flying)
                    .position(x: from.x + spread, y: from.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(20))
            flying = true
        }
    }
}

/// Slowly turning rays behind the trophy in the all-done party.
struct Sunburst: Shape {
    var rays = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let half = Double.pi / Double(rays) / 2
        for index in 0..<rays {
            let angle = Double(index) / Double(rays) * 2 * .pi
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(angle - half) * radius, y: center.y + sin(angle - half) * radius))
            path.addLine(to: CGPoint(x: center.x + cos(angle + half) * radius, y: center.y + sin(angle + half) * radius))
            path.closeSubpath()
        }
        return path
    }
}
