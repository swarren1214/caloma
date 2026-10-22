import SwiftData
import SwiftUI

/// Devices the family pinned to Home, as tiles on the Home tab. Shows only once something is
/// pinned, so Home never asks for Apple Home access on its own.
struct PinnedDevicesCard: View {
    @Query(filter: #Predicate<DeviceStyle> { $0.pinnedToHome }) private var pinned: [DeviceStyle]
    @Query private var styles: [DeviceStyle]
    @Environment(AppRouter.self) private var router
    private let home = HomeBridge.shared

    var body: some View {
        // Home Control is part of Caloma Plus and Hearth+.
        if !pinned.isEmpty && CalomaPlus.isUnlocked {
            let book = StyleBook(styles)
            let controls = home.allControls.filter { control in
                guard let style = book.style(serviceID: control.id.uuidString, matchKey: control.matchKey) else { return false }
                return style.pinnedToHome && !style.hidden
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Home Controls") {
                    Button("Control") { router.tab = .control }
                }
                if controls.isEmpty {
                    Text(home.authorized == false ? "Allow Caloma to use your Home data in Settings to see these." : "Looking for your devices…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    DeviceGrid {
                        ForEach(controls) { control in
                            DeviceTile(control: control, onAdjust: nil, onEdit: { router.tab = .control })
                        }
                    }
                }
            }
            .environment(\.styleBook, book)
            .task { home.start() }
        }
    }
}

/// In Kid View (and on the wall iPad, for a kid): the lights, plugs and fans parents said
/// this family's kids can use. Never locks, doors, windows, alarms, water, heat or sensors.
struct KidHomeStrip: View {
    var color: Color

    @Query(filter: #Predicate<DeviceStyle> { $0.kidsAllowed }) private var allowed: [DeviceStyle]
    @Query private var styles: [DeviceStyle]
    @Environment(\.accent) private var accent
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let home = HomeBridge.shared
    @State private var busy: Set<UUID> = []

    var body: some View {
        if !allowed.isEmpty {
            strip
                .task { home.start() }
        }
    }

    @ViewBuilder
    private var strip: some View {
        Group {
            let book = StyleBook(styles)
            let controls = home.allControls.filter { control in
                guard control.kind.isKidSafe,
                      let style = book.style(serviceID: control.id.uuidString, matchKey: control.matchKey) else { return false }
                return style.kidsAllowed && !style.hidden
            }
            if controls.isEmpty {
                // Something for .task to hang on while Apple Home loads.
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Lights & More")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4)
                    DuoAdaptiveGrid(minimum: sizeClass == .compact ? 140 : 180, spacing: 12) {
                        ForEach(controls) { control in
                            tile(control, look: DeviceLook(control: control, style: book.style(serviceID: control.id.uuidString, matchKey: control.matchKey), accent: accent))
                        }
                    }
                }
            }
        }
    }

    private func tile(_ control: HomeControl, look: DeviceLook) -> some View {
        let on = home.isOn(control)
        let text = TileText(on: on, look: look)
        return Button {
            guard control.reachable, !busy.contains(control.id) else { return }
            busy.insert(control.id)
            Task {
                await home.toggle(control)
                busy.remove(control.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                DeviceIcon(symbol: look.symbol(on), on: on, look: look, size: 52)
                Spacer(minLength: 0)
                Text(control.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(text.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(on ? "On" : "Off")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(text.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .tileSurface(on: on, look: look, cornerRadius: 28)
            .opacity(control.reachable ? 1 : 0.55)
        }
        .buttonStyle(KidPressStyle())
        .sensoryFeedback(.impact, trigger: on)
        .accessibilityLabel("\(control.name), \(on ? "on" : "off")")
    }
}
