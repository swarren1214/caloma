import SwiftUI
import UIKit

/// A window of its own for calls, above everything else in Caloma (the Family Board, Kid View,
/// any sheet), so a ring always comes through. Shown while a call is ringing, going or just
/// ended, and for a Find flash.
@MainActor
final class CallWindow {
    static let shared = CallWindow()
    private var window: UIWindow?

    private init() {}

    func update() {
        let center = CallCenter.shared
        if !center.state.isIdle || center.flash != nil {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: CallScreen().environment(\.accent, Brand.defaultAccent))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.alpha = 0
        window.isHidden = false
        self.window = window
        UIView.animate(withDuration: 0.25) { window.alpha = 1 }
    }

    private func hide() {
        guard let window else { return }
        self.window = nil
        UIView.animate(withDuration: 0.25) {
            window.alpha = 0
        } completion: { _ in
            window.isHidden = true
        }
    }
}

/// Everything a call shows: ringing, calling, the call itself, and how it ended.
struct CallScreen: View {
    @State private var center = CallCenter.shared

    var body: some View {
        ZStack {
            switch center.state.phase {
            case .idle:
                if let name = center.flash {
                    FindFlash(name: name) { center.dismissFlash() }
                        .transition(.opacity)
                }
            case .ringing:
                IncomingCallView(center: center)
                    .transition(.opacity)
            case .calling, .live:
                if center.state.isBroadcast {
                    BroadcastView(center: center)
                        .transition(.opacity)
                } else {
                    LiveCallView(center: center)
                        .transition(.opacity)
                }
            case let .ended(reason):
                CallEndedView(names: center.state.names.values.sorted(), reason: reason)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: center.state.phase)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Ringing

private struct IncomingCallView: View {
    let center: CallCenter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pulse = false

    private var name: String { center.state.caller.map { center.state.name($0) } ?? "Someone" }
    private var big: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: big ? 28 : 20) {
            Spacer()
            CallAvatar(name: name, size: big ? 180 : 120)
                .scaleEffect(pulse ? 1.04 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            VStack(spacing: 8) {
                Text(name)
                    .font(big ? .system(size: 48, weight: .bold) : .largeTitle.bold())
                Label(center.state.offeredVideo ? "Video Call" : "Intercom Call",
                      systemImage: center.state.offeredVideo ? "video.fill" : "phone.fill")
                    .font(big ? .title2 : .headline)
                    .foregroundStyle(.secondary)
                    // The icon in the text's color.
                    .tint(.secondary)
            }
            Spacer()
            HStack(spacing: big ? 64 : 36) {
                CallButton(title: "Decline", symbol: "phone.down.fill", tint: .red, size: big ? 96 : 72) {
                    center.decline()
                }
                CallButton(title: "Audio", symbol: "phone.fill", tint: Color(white: 0.3), size: big ? 96 : 72) {
                    Task { await center.answer(video: false) }
                }
                CallButton(title: "Video", symbol: "video.fill", tint: .green, size: big ? 96 : 72) {
                    Task { await center.answer(video: true) }
                }
            }
            .padding(.bottom, big ? 72 : 48)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
        .onAppear { pulse = true }
    }
}

// MARK: - Calling and on a call

private struct LiveCallView: View {
    let center: CallCenter
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var state: CallState { center.state }
    private var media: CallMedia { center.media }
    private var peers: [UUID] { state.peers.sorted { state.name($0) < state.name($1) } }
    private var big: Bool { sizeClass == .regular }
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    /// Their video fills the screen (edges cropped), or shows whole. Whole by default on iPad,
    /// where a phone's portrait video would otherwise lose most of the picture.
    @State private var fills = UIDevice.current.userInterfaceIdiom == .phone

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if peers.isEmpty {
                calling
            } else {
                grid
            }
        }
        .overlay(alignment: .topTrailing) {
            if !peers.isEmpty, media.cameraOn {
                media.localView()
                    .frame(width: big ? 200 : 110, height: big ? 150 : 160)
                    .clipShape(.rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(radius: 10)
                    .padding(16)
            }
        }
        .overlay(alignment: .top) {
            if !peers.isEmpty {
                header
            }
        }
        .overlay(alignment: isPhone ? .bottomTrailing : .bottom) {
            if isPhone { phoneControls } else { controls }
        }
        .foregroundStyle(.white)
    }

    /// Ringing out: our own camera (if on) behind who we're calling.
    private var calling: some View {
        ZStack {
            media.localView()
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.45).ignoresSafeArea())
            VStack(spacing: 14) {
                let names = state.ringingPeers.map { state.name($0) }.sorted()
                CallAvatar(name: names.count == 1 ? names[0] : "All", size: big ? 150 : 110, symbol: names.count > 1 ? "rectangle.3.group.fill" : nil)
                Text(names.count == 1 ? names[0] : "All Family Boards")
                    .font(big ? .system(size: 40, weight: .bold) : .title.bold())
                Text(names.count > 1 ? "Ringing \(names.count) boards…" : "Ringing…")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var grid: some View {
        let columns = peers.count <= 1 ? 1 : 2
        return GeometryReader { proxy in
            let rows = Int(ceil(Double(peers.count) / Double(columns)))
            let height = proxy.size.height / CGFloat(max(rows, 1))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(peers, id: \.self) { peer in
                    PeerTile(center: center, peer: peer, fills: fills)
                        .frame(height: height - (rows > 1 ? 4 : 0))
                }
            }
        }
        .ignoresSafeArea(edges: peers.count == 1 ? .all : [])
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(peers.count == 1 ? state.name(peers[0]) : "\(peers.count) Boards")
                .font(.headline)
            if let start = center.connectedAt {
                Text(start, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !state.ringingPeers.isEmpty {
                Text("Still ringing \(state.ringingPeers.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: .capsule)
        .padding(.top, 12)
    }

    /// Liquid Glass buttons, all one size, straight over the video (no bar behind them). End is
    /// the red one; a toggle that's on (muted, camera off) turns white.
    private var controls: some View {
        let size: CGFloat = big ? 64 : 56
        return GlassEffectContainer(spacing: big ? 22 : 16) {
            HStack(spacing: big ? 22 : 16) {
                CallControl(title: media.muted ? "Unmute" : "Mute", symbol: media.muted ? "mic.slash.fill" : "mic.fill", isOn: media.muted, size: size) {
                    center.toggleMute()
                }
                CallControl(title: media.cameraOn ? "Turn Camera Off" : "Turn Camera On", symbol: media.cameraOn ? "video.fill" : "video.slash.fill", isOn: !media.cameraOn, size: size) {
                    Task { await center.toggleCamera() }
                }
                if !peers.isEmpty {
                    CallControl(title: fills ? "Show Whole Video" : "Fill Screen", symbol: fillSymbol, size: size) {
                        withAnimation(.smooth) { fills.toggle() }
                    }
                }
                CallControl(title: "End Call", symbol: "phone.down.fill", tint: .red, size: size) {
                    center.hangUp()
                }
            }
        }
        .padding(.bottom, big ? 28 : 16)
    }

    private var fillSymbol: String {
        fills ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    /// On iPhone: a column down the right edge, out of the way of their face, with the less
    /// used controls (flip camera, speaker, fill) in a More menu at the top.
    private var phoneControls: some View {
        let size: CGFloat = 56
        return GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                Menu {
                    Button {
                        center.flipCamera()
                    } label: {
                        Label("Flip Camera", systemImage: "arrow.triangle.2.circlepath.camera")
                    }
                    .disabled(!media.cameraOn)
                    Toggle(isOn: Binding(get: { media.speakerOn }, set: { _ in center.toggleSpeaker() })) {
                        Label("Speaker", systemImage: "speaker.wave.3")
                    }
                    if !peers.isEmpty {
                        Button {
                            withAnimation(.smooth) { fills.toggle() }
                        } label: {
                            Label(fills ? "Show Whole Video" : "Fill Screen", systemImage: fillSymbol)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .frame(width: size, height: size)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More")
                CallControl(title: media.cameraOn ? "Turn Camera Off" : "Turn Camera On", symbol: media.cameraOn ? "video.fill" : "video.slash.fill", isOn: !media.cameraOn, size: size) {
                    Task { await center.toggleCamera() }
                }
                CallControl(title: media.muted ? "Unmute" : "Mute", symbol: media.muted ? "mic.slash.fill" : "mic.fill", isOn: media.muted, size: size) {
                    center.toggleMute()
                }
                CallControl(title: "End Call", symbol: "phone.down.fill", tint: .red, size: size) {
                    center.hangUp()
                }
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }
}

/// One device on the call: their video, or their name while the camera's off or connecting.
private struct PeerTile: View {
    let center: CallCenter
    let peer: UUID
    var fills = true

    var body: some View {
        let media = center.media
        let name = center.state.name(peer)
        ZStack {
            Color(white: 0.12)
            VStack(spacing: 12) {
                CallAvatar(name: name, size: 96)
                Text(name).font(.title3.bold())
                switch media.links[peer] {
                case .connecting?, nil:
                    Text(CallMedia.isAvailable ? "Connecting…" : "Connected (no sound or video in this build)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                case .failed?:
                    Text("Connection lost").font(.subheadline).foregroundStyle(.red)
                case .connected?:
                    if media.remoteCamera[peer] != true {
                        Label("Camera off", systemImage: "video.slash.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .tint(.white.opacity(0.7))
                    }
                }
            }
            media.remoteView(for: peer, fills: fills)
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }
}

// MARK: - Broadcasting

/// A broadcast: on the device talking, a big hold-to-talk button; everywhere else, who's talking.
private struct BroadcastView: View {
    let center: CallCenter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accent) private var accent
    @State private var holding = false

    private var state: CallState { center.state }
    private var big: Bool { sizeClass == .regular }
    private var listening: Int { state.peers.count }

    var body: some View {
        VStack(spacing: big ? 28 : 20) {
            Spacer()
            if state.isCaller { talker } else { listener }
            Spacer()
            GlassEffectContainer {
                if state.isCaller {
                    Button {
                        center.hangUp()
                    } label: {
                        Text("End Broadcast")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                } else {
                    Button {
                        center.hangUp()
                    } label: {
                        Text("Stop Listening")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.bottom, big ? 56 : 32)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }

    private var talker: some View {
        VStack(spacing: big ? 28 : 20) {
            VStack(spacing: 8) {
                Text("Broadcast")
                    .font(big ? .system(size: 44, weight: .bold) : .largeTitle.bold())
                Text(status)
                    .font(big ? .title3 : .headline)
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.numericText())
            }
            let size: CGFloat = big ? 240 : 180
            Circle()
                .fill(holding ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.clear))
                .frame(width: size, height: size)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: holding ? "waveform" : "mic.fill")
                            .font(.system(size: size * 0.26, weight: .semibold))
                            .symbolEffect(.variableColor.iterative, isActive: holding)
                        Text(holding ? "Talking" : "Hold to Talk")
                            .font(.headline)
                    }
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .scaleEffect(holding ? 1.06 : 1)
                .animation(.smooth(duration: 0.2), value: holding)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !holding else { return }
                            holding = true
                            center.talk(true)
                        }
                        .onEnded { _ in
                            holding = false
                            center.talk(false)
                        }
                )
                .sensoryFeedback(.impact, trigger: holding)
                .accessibilityElement()
                .accessibilityLabel(holding ? "Talking" : "Talk")
                .accessibilityHint("Turns your microphone on for everyone. Activate again to stop.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    holding.toggle()
                    center.talk(holding)
                }
        }
    }

    private var status: String {
        if listening == 0 { return "Reaching everyone…" }
        return listening == 1 ? "1 device listening" : "\(listening) devices listening"
    }

    private var listener: some View {
        let name = state.caller.map { state.name($0) } ?? "Someone"
        return VStack(spacing: 16) {
            CallAvatar(name: name, size: big ? 180 : 120, symbol: "megaphone.fill")
            Text(name)
                .font(big ? .system(size: 48, weight: .bold) : .largeTitle.bold())
            Label("Broadcasting", systemImage: "waveform")
                .font(big ? .title2 : .headline)
                .foregroundStyle(.white.opacity(0.7))
                .tint(.white.opacity(0.7))
                .symbolEffect(.variableColor.iterative)
        }
    }
}

// MARK: - Ended and Find

private struct CallEndedView: View {
    let names: [String]
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            CallAvatar(name: names.count == 1 ? names[0] : "All", size: 110, symbol: names.count > 1 ? "rectangle.3.group.fill" : nil)
            Text(reason)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }
}

/// "This is the Kitchen Board": Find from Family › Devices, on the board itself.
private struct FindFlash: View {
    let name: String
    var onDismiss: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 72, weight: .semibold))
            Text(name)
                .font(.system(size: 56, weight: .bold))
                .multilineTextAlignment(.center)
            Text("This is the device you picked in Family › Devices.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(40)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(accent.ignoresSafeArea())
        .contentShape(.rect)
        .onTapGesture(perform: onDismiss)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Closes")
    }
}

// MARK: - Pieces

struct CallAvatar: View {
    let name: String
    var size: CGFloat = 96
    var symbol: String?
    @Environment(\.accent) private var accent

    var body: some View {
        Circle()
            .fill(accent.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.4, weight: .semibold))
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

/// A round call button with its label underneath (Decline, Answer, End).
private struct CallButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var size: CGFloat = 72
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(tint, in: .circle)
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A round Liquid Glass button for the call controls: clear glass, white glass when it's on
/// (muted, camera off), or tinted glass (End, red). The name is for VoiceOver; nothing under it.
private struct CallControl: View {
    let title: String
    let symbol: String
    var isOn = false
    var tint: Color? = nil
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Group {
            if isOn || tint != nil {
                Button(action: action) { icon }
                    .buttonStyle(.glassProminent)
                    .tint(tint ?? .white)
            } else {
                Button(action: action) { icon }
                    .buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.36, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(isOn ? .black : .white)
    }
}
