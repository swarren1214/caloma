import SwiftUI

/// Family › Kiosk Mode: turn this iPad into the family's wall screen, and how it behaves.
struct KioskSettingsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @AppStorage(SettingsKey.kioskIdleSeconds) private var idleSeconds = 30
    @AppStorage(SettingsKey.kioskShowsFamily) private var showsFamily = true
    @AppStorage(SettingsKey.kioskKeepAwake) private var keepAwake = true
    @AppStorage(SettingsKey.kioskFaces) private var facesOn = false
    @AppStorage(SettingsKey.kioskDoorbell) private var doorbellOn = true
    @AppStorage(SettingsKey.kioskDoorbellMotion) private var doorbellMotion = false
    @AppStorage(SettingsKey.kioskChime) private var chime = true
    private let home = HomeBridge.shared

    @State private var pinIsSet = ParentPIN.isSet
    @State private var settingPIN = false
    @State private var startsAfterPIN = false
    @State private var guidedAccess = false

    private let idleChoices = [15, 30, 60, 120]

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 34))
                        .foregroundStyle(accent)
                    Text("For an iPad on the wall: the family calendar all day, and a tap on a face for that person's chores or tasks.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Button {
                    start()
                } label: {
                    Text("Start Kiosk Mode")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                Picker("Back to the Calendar After", selection: $idleSeconds) {
                    ForEach(idleChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) seconds" : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")).tag(seconds)
                    }
                }
                Toggle(isOn: $showsFamily) {
                    settingLabel("Family Down the Side", "Tap a face for their chores, or a parent's own tasks")
                }
                Toggle(isOn: $keepAwake) {
                    settingLabel("Keep the Screen On", "So the wall never goes dark")
                }
            } header: {
                Text("On the Wall")
            }

            Section {
                NavigationLink {
                    FacesSettingsView()
                } label: {
                    LabeledContent {
                        Text(facesOn ? "On" : "Off")
                    } label: {
                        Label("Faces", systemImage: "faceid")
                    }
                }
            } footer: {
                Text("The wall says hi and opens someone's screen when they walk up. Set up on this iPad only.")
            }

            Section {
                Toggle(isOn: $doorbellOn) {
                    settingLabel("Show the Doorbell", "Live video on the wall when someone rings")
                }
                Toggle(isOn: $doorbellMotion) {
                    settingLabel("When Someone's at the Door", "Also show it when the doorbell sees a person")
                }
                .disabled(!doorbellOn)
                Toggle("Chime on the Wall", isOn: $chime)
                    .disabled(!doorbellOn)
                if home.homeNames.count > 1 {
                    Picker("Home", selection: Binding(get: { home.home?.uniqueIdentifier ?? home.homeNames[0].id }, set: { home.chooseHome($0) })) {
                        ForEach(home.homeNames) { entry in
                            Text(entry.name).tag(entry.id)
                        }
                    }
                }
            } header: {
                Text("Doorbell")
            } footer: {
                Text(doorbellFooter)
            }

            Section {
                Button(pinIsSet ? "Change Parent PIN" : "Set Parent PIN") {
                    startsAfterPIN = false
                    settingPIN = true
                }
            } header: {
                Text("Parent PIN")
            } footer: {
                Text("The PIN unlocks approvals on the wall and leaving Kiosk Mode, so kids can't OK their own chores. It's kept on this iPad only.")
            }

            Section {
                LabeledContent("Guided Access") {
                    Text(guidedAccess ? "On" : "Not on yet")
                        .foregroundStyle(guidedAccess ? Color(hex: 0x1E9E6A) : Brand.waiting)
                }
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Settings › Accessibility › Guided Access: turn it on, set a passcode, and turn on Accessibility Shortcut.")
                    step(2, "Same screen: Display Auto-Lock › Never.")
                    step(3, "Start Kiosk Mode here, then triple-click the top button and tap Start.")
                    step(4, "To leave: triple-click again and enter the Guided Access passcode.")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Lock This iPad to Caloma")
            } footer: {
                Text("iPadOS keeps the Home swipe, Control Center, Notification Center and Siri for itself. Guided Access turns them all off while Caloma is open.")
            }
        }
        .navigationTitle("Kiosk Mode")
        .onAppear {
            guidedAccess = UIAccessibility.isGuidedAccessEnabled
            pinIsSet = ParentPIN.isSet
            home.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            guidedAccess = UIAccessibility.isGuidedAccessEnabled
        }
        .sheet(isPresented: $settingPIN) {
            PINSetupSheet {
                pinIsSet = true
                if startsAfterPIN {
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        router.openKiosk()
                    }
                }
            }
            .tint(accent)
        }
    }

    private var doorbellFooter: String {
        if home.authorized == false {
            return "Caloma can't see your home yet. Allow it in Settings › Privacy & Security › HomeKit."
        }
        let names = home.doorbellNames
        if names.isEmpty {
            return "No Apple Home doorbell found. Doorbells that work with Apple Home show here; Ring and Nest need their own apps."
        }
        return "Watching \(names.formatted(.list(type: .and))). Unlocking a door from the wall takes the parent PIN."
    }

    /// Kiosk Mode needs a PIN first, so there's always a way back out.
    private func start() {
        if ParentPIN.isSet {
            router.openKiosk()
        } else {
            startsAfterPIN = true
            settingPIN = true
        }
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number.formatted())
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(accent, in: Circle())
            Text(text)
                .font(.subheadline)
        }
    }
}
