import HomeKit
import SwiftUI

/// Control: the family's Apple Home in Caloma. Scenes along the top, cameras, then every room's
/// lights, switches, locks, garage doors, thermostats, shades and sensors. A tap flips a tile;
/// touch and hold (or the dimmer) for brightness, temperature or how far a shade is open.
struct ControlView: View {
    @Environment(\.accent) private var accent
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let home = HomeBridge.shared

    @State private var openCamera: HomeCamera?
    @State private var adjusting: HomeControl?
    @State private var ranScene: UUID?

    var body: some View {
        CalomaScreen(title: home.homeTitle ?? "Control", maxWidth: 1100) {
            if home.authorized == false {
                EmptyCard(symbol: "house.slash", title: "Caloma can't see your home", message: "Allow Caloma to use your Home data in Settings › Privacy & Security › HomeKit.")
            } else if home.authorized == true && home.homeNames.isEmpty {
                EmptyCard(symbol: "homekit", title: "No home set up yet", message: "Add your lights, locks and cameras in the Home app, and they'll show here.")
            } else {
                content
            }
        }
        .toolbar {
            if home.homeNames.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Home", selection: Binding(get: { home.home?.uniqueIdentifier ?? home.homeNames[0].id }, set: { home.chooseHome($0) })) {
                            ForEach(home.homeNames) { Text($0.name).tag($0.id) }
                        }
                    } label: {
                        Label("Choose Home", systemImage: "house")
                    }
                }
            }
        }
        .task {
            // Values are read as soon as Apple Home hands over the homes.
            home.start()
        }
        .refreshable {
            await home.refreshControls()
        }
        .fullScreenCover(item: $openCamera) { camera in
            CameraFullScreen(camera: camera)
        }
        .sheet(item: $adjusting) { control in
            ControlDetailSheet(control: control)
                .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var content: some View {
        let scenes = home.scenes
        if !scenes.isEmpty {
            SectionTitle("Scenes")
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(scenes) { scene in
                        Button {
                            Task {
                                if await home.run(scene) {
                                    withAnimation(.snappy) { ranScene = scene.id }
                                    try? await Task.sleep(for: .seconds(2))
                                    withAnimation(.snappy) { if ranScene == scene.id { ranScene = nil } }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                IconTile(symbol: ranScene == scene.id ? "checkmark" : scene.symbol, color: accent, size: 36, filled: ranScene == scene.id)
                                    .contentTransition(.symbolEffect(.replace))
                                Text(scene.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 16)
                            .frame(height: 54)
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                        }
                        .buttonStyle(KidPressStyle())
                        .sensoryFeedback(.success, trigger: ranScene) { _, new in new == scene.id }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }

        let cameras = home.cameras
        if !cameras.isEmpty {
            SectionTitle("Cameras")
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(cameras) { camera in
                        Button {
                            openCamera = camera
                        } label: {
                            CameraSnapshotTile(camera: camera)
                        }
                        .buttonStyle(KidPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }

        let rooms = home.roomControls
        if rooms.isEmpty && scenes.isEmpty && cameras.isEmpty {
            EmptyCard(symbol: "lightswitch.off", title: "Nothing to control yet", message: "Lights, locks, thermostats and cameras you add in the Home app show here.")
        }
        ForEach(rooms) { room in
            SectionTitle(room.name)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 150 : 180), spacing: 12)], spacing: 12) {
                ForEach(room.controls) { control in
                    ControlTile(control: control) {
                        adjusting = control
                    }
                }
            }
        }
    }
}

/// One accessory: its icon lit when it's on, its name and state. Tap to flip; the slider
/// button (or touch and hold) for brightness, temperature or shade position.
private struct ControlTile: View {
    var control: HomeControl
    var onMore: () -> Void

    @Environment(\.accent) private var accent
    private let home = HomeBridge.shared
    @State private var busy = false
    @State private var confirming = false

    var body: some View {
        let on = home.isOn(control)
        let color = tint(on)
        Button {
            guard !control.isSensor, control.reachable else { return }
            if control.kind == .thermostat {
                onMore()
            } else if (control.kind == .lock || control.kind == .garage) && on {
                // Unlocking a door or opening the garage asks first.
                confirming = true
            } else {
                flip()
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol(on))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(lit(on) ? Color.white : color)
                        .frame(width: 40, height: 40)
                        .background(lit(on) ? color : color.opacity(0.15), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    if busy {
                        ProgressView()
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(home.state(control))
                        .font(.footnote)
                        .foregroundStyle(control.reachable ? .secondary : Brand.late)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lit(on) ? color.opacity(0.12) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            .overlay {
                if lit(on) { RoundedRectangle(cornerRadius: 20).strokeBorder(color.opacity(0.35), lineWidth: 1.5) }
            }
            .opacity(control.reachable ? 1 : 0.6)
        }
        .buttonStyle(KidPressStyle())
        .disabled(control.isSensor)
        // Brightness, temperature or shade position.
        .overlay(alignment: .topTrailing) {
            if hasMore && !busy {
                Button(action: onMore) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Adjust \(control.name)")
            }
        }
        .contextMenu {
            if hasMore {
                Button("Adjust", systemImage: "slider.horizontal.3", action: onMore)
            }
        }
        .sensoryFeedback(.selection, trigger: on)
        .confirmationDialog(control.kind == .lock ? "Unlock \(control.name)?" : "Open \(control.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button(control.kind == .lock ? "Unlock" : "Open") { flip() }
        }
        .accessibilityLabel("\(control.name), \(home.state(control))")
        .accessibilityAddTraits(control.isSensor ? [] : .isButton)
    }

    private func flip() {
        busy = true
        Task {
            await home.toggle(control)
            busy = false
        }
    }

    private var hasMore: Bool {
        switch control.kind {
        case .light: home.brightness(control) != nil
        case .thermostat, .shade: true
        default: false
        }
    }

    /// Whether the tile is lit: lights and switches when on; locks and garage doors when they
    /// need attention (unlocked or open).
    private func lit(_ on: Bool) -> Bool {
        switch control.kind {
        case .lock, .garage: !on
        case .temperature, .humidity: false
        default: on
        }
    }

    private func tint(_ on: Bool) -> Color {
        switch control.kind {
        case .light: Color(hex: 0xF5A623)
        case .switchOrOutlet, .fan: accent
        case .lock, .garage: on ? Color(hex: 0x1E9E6A) : Brand.waiting
        case .thermostat: Color(hex: 0xE8650F)
        case .shade: Color(hex: 0x5E5CE6)
        case .temperature, .humidity: Color(hex: 0x0A84FF)
        case .contact, .motion: Brand.waiting
        }
    }

    private func symbol(_ on: Bool) -> String {
        switch control.kind {
        case .light: on ? "lightbulb.fill" : "lightbulb"
        case .switchOrOutlet: on ? "poweroutlet.type.b.fill" : "poweroutlet.type.b"
        case .fan: "fan.fill"
        case .lock: on ? "lock.fill" : "lock.open.fill"
        case .garage: on ? "door.garage.closed" : "door.garage.open"
        case .thermostat: "thermometer.medium"
        case .shade: on ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case .temperature: "thermometer.medium"
        case .humidity: "humidity.fill"
        case .contact: on ? "door.left.hand.open" : "door.left.hand.closed"
        case .motion: "figure.walk.motion"
        }
    }
}

/// Brightness, the thermostat's target, or how far a shade is open.
private struct ControlDetailSheet: View {
    var control: HomeControl

    @Environment(\.dismiss) private var dismiss
    private let home = HomeBridge.shared
    @State private var value: Double = 0
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(home.state(control))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                switch control.kind {
                case .light:
                    slider(range: 0...100, symbol: "sun.max.fill") { level in
                        await home.setBrightness(control, to: level)
                    }
                    Text("\(Int(value))%").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                case .shade:
                    slider(range: 0...100, symbol: "blinds.horizontal.open") { position in
                        await home.setShadePosition(control, to: position)
                    }
                    Text(value == 0 ? "Closed" : "\(Int(value))% open").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                case .thermostat:
                    HStack(spacing: 28) {
                        stepButton("minus") { value -= HomeBridge.temperatureStep }
                        Text(HomeBridge.temperatureText(value))
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 140)
                            .contentTransition(.numericText())
                        stepButton("plus") { value += HomeBridge.temperatureStep }
                    }
                    Text("Target temperature")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle(control.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            switch control.kind {
            case .light: value = home.brightness(control) ?? 100
            case .shade: value = home.shadePosition(control) ?? 0
            case .thermostat: value = home.targetTemperature(control) ?? 20
            default: break
            }
        }
    }

    private func slider(range: ClosedRange<Double>, symbol: String, apply: @escaping (Double) async -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Slider(value: $value, in: range, step: 1, onEditingChanged: { editing in
                guard !editing else { return }
                let level = value
                Task { await apply(level) }
            })
        }
        .padding(.horizontal, 8)
    }

    private func stepButton(_ symbol: String, change: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { change() }
            let target = value
            Task { await home.setTargetTemperature(control, to: target) }
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 60, height: 60)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A camera's latest snapshot, 16:9, with its name.
private struct CameraSnapshotTile: View {
    var camera: HomeCamera

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CameraSnapshotView(accessoryID: camera.id)
                .background(Color.black)
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 6) {
                Image(systemName: camera.isDoorbell ? "bell.fill" : "video.fill")
                    .font(.caption.weight(.bold))
                Text(camera.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(width: 260, height: 146)
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(camera.name) camera")
        .accessibilityAddTraits(.isButton)
    }
}

/// HomeKit's camera view showing the newest snapshot, refreshed every 15 seconds.
private struct CameraSnapshotView: UIViewRepresentable {
    var accessoryID: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        context.coordinator.attach(view, accessoryID: accessoryID)
        return view
    }

    func updateUIView(_ view: HMCameraView, context: Context) {}

    static func dismantleUIView(_ view: HMCameraView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, HMCameraSnapshotControlDelegate {
        private weak var view: HMCameraView?
        private var control: HMCameraSnapshotControl?
        private var refresh: Task<Void, Never>?

        func attach(_ view: HMCameraView, accessoryID: UUID) {
            self.view = view
            guard let control = HomeBridge.shared.cameraProfile(for: accessoryID)?.snapshotControl else { return }
            self.control = control
            if let snapshot = control.mostRecentSnapshot { view.cameraSource = snapshot }
            refresh = Task { [weak self] in
                while !Task.isCancelled {
                    self?.snap()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }

        /// The live view takes over the camera's snapshot delegate while it's open, so claim it
        /// back each time.
        private func snap() {
            guard let control, view?.window != nil else { return }
            control.delegate = self
            control.takeSnapshot()
        }

        func stop() {
            refresh?.cancel()
            refresh = nil
        }

        private func show(_ snapshot: HMCameraSnapshot?) {
            guard let snapshot else { return }
            view?.cameraSource = snapshot
        }

        nonisolated func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: Error?) {
            Task { @MainActor in self.show(snapshot) }
        }
    }
}

/// A camera full screen and live, with Talk and Mute.
private struct CameraFullScreen: View {
    var camera: HomeCamera

    @Environment(\.dismiss) private var dismiss
    @State private var talking = false
    @State private var muted = false

    private var audio: HMCameraAudioStreamSetting {
        if talking { return .bidirectionalAudioAllowed }
        return muted ? .muted : .incomingAudioAllowed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraLiveView(accessoryID: camera.id, audio: audio)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(camera.name).font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.black.opacity(0.5), in: Capsule())
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 16) {
                Button {
                    muted.toggle()
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel(muted ? "Unmute" : "Mute")
                Button {
                    talking.toggle()
                } label: {
                    Label(talking ? "Done" : "Talk", systemImage: "mic.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .frame(height: 56)
                        .background(talking ? Brand.late : Color(hex: 0x34C759), in: Capsule())
                }
                .sensoryFeedback(.impact, trigger: talking)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 30)
        }
        .statusBarHidden()
    }
}
