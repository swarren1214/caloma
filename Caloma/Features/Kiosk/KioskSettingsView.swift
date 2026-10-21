import SwiftData
import SwiftUI

/// Family › Kiosk Mode: turn this iPad into the family's wall screen, and how it behaves.
struct KioskSettingsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @AppStorage(SettingsKey.kioskIdleSeconds) private var idleSeconds = KioskSession.defaultIdleSeconds
    @AppStorage(SettingsKey.kioskShowsFamily) private var showsFamily = true
    @AppStorage(SettingsKey.kioskKeepAwake) private var keepAwake = true
    @AppStorage(SettingsKey.kioskFaces) private var facesOn = false
    @AppStorage(SettingsKey.kioskDims) private var dims = true
    @AppStorage(SettingsKey.kioskDimMinutes) private var dimMinutes = 5
    @AppStorage(SettingsKey.kioskMatchLight) private var matchLight = true
    @AppStorage(SettingsKey.kioskScreensaver) private var screensaverOn = true
    @AppStorage(SettingsKey.kioskScreensaverMinutes) private var screensaverMinutes = 5
    @AppStorage(SettingsKey.kioskDoorbell) private var doorbellOn = true
    @AppStorage(SettingsKey.kioskChime) private var chime = true
    @AppStorage(SettingsKey.kioskLockBiometrics) private var lockBiometrics = true
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var passcodeFor: Member?
    /// Bumps when a lock changes, so the toggles redraw.
    @State private var lockRevision = 0
    private let home = HomeBridge.shared

    @State private var pinIsSet = ParentPIN.isSet
    @State private var settingPIN = false
    @State private var startsAfterPIN = false
    @State private var guidedAccess = false
    /// Starting the Family Board without Caloma Plus or Hearth+.
    @State private var showsPaywall = false

    private let idleChoices = [15, 20, 30, 60, 120]

    init() {
        // Before the picker reads it: the old 30-second default becomes 20.
        KioskSession.moveIdleTimeToTwentySeconds()
    }

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
            }

            // The Family Board is part of Caloma Plus and Hearth+.
            if !CalomaPlus.isUnlocked {
                Section {
                    HearthLockedCard(feature: CalomaPlus.familyBoard)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Button {
                    start()
                } label: {
                    Text("Start the Family Board")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            }

            Section {
                Picker("Back to the Calendar After", selection: $idleSeconds) {
                    ForEach(idleChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) seconds" : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")).tag(seconds)
                    }
                }
                .tint(.primary)
                Toggle(isOn: $showsFamily) {
                    settingLabel("Family Down the Side", "Tap a face for their chores, or a parent's own tasks")
                }
                Toggle(isOn: $keepAwake) {
                    settingLabel("Keep the Screen On", "So the wall never goes dark")
                }
                Toggle(isOn: $dims) {
                    settingLabel("Dim When No One's Around", "Fades right down, and wakes when the camera sees someone move")
                }
                if dims {
                    Picker(screensaverOn ? "Dim After the Screensaver Starts" : "Dim After", selection: $dimMinutes) {
                        ForEach([2, 5, 10, 15], id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    .tint(.primary)
                }
                Toggle(isOn: $matchLight) {
                    settingLabel("Match the Room's Light", "About 50% in a dark room, up to 100% in a bright one")
                }
            } header: {
                Text("On the Wall")
            } footer: {
                if dims || matchLight {
                    Text("Uses the front camera to notice movement and light; nothing is recorded. The camera light stays on while the Family Board is showing.")
                }
            }

            Section {
                NavigationLink {
                    ScreensaverSettingsView()
                } label: {
                    LabeledContent {
                        Text(screensaverOn ? "After \(screensaverMinutes) min" : "Off")
                    } label: {
                        Label("Screensaver", systemImage: "photo.on.rectangle.angled")
                            // The row's icon in its text color, not the app's.
                            .tint(.primary)
                    }
                }
            } footer: {
                Text("Family photos and cards that take turns when no one's around. A tap or someone walking up wakes it.")
            }

            Section {
                NavigationLink {
                    FacesSettingsView()
                } label: {
                    LabeledContent {
                        Text(facesOn ? "On" : "Off")
                    } label: {
                        Label("Faces", systemImage: "faceid")
                            .tint(.primary)
                    }
                }
            } footer: {
                Text("The wall says hi and opens someone's screen when they walk up. Set up on this iPad only.")
            }

            Section {
                Toggle(isOn: $doorbellOn) {
                    settingLabel("Show the Doorbell", "Live video on the wall when someone rings")
                }
                Toggle("Chime on the Wall", isOn: $chime)
                if home.homeNames.count > 1 {
                    Picker("Home", selection: Binding(get: { home.home?.uniqueIdentifier ?? home.homeNames[0].id }, set: { home.chooseHome($0) })) {
                        ForEach(home.homeNames) { entry in
                            Text(entry.name).tag(entry.id)
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Doorbell")
            } footer: {
                Text(doorbellFooter)
            }

            if !home.cameras.isEmpty {
                Section {
                    ForEach(home.cameras) { camera in
                        Toggle(isOn: Binding(
                            get: { home.motionCameraIDs.contains(camera.id) },
                            set: { on in
                                var ids = home.motionCameraIDs
                                if on { ids.insert(camera.id) } else { ids.remove(camera.id) }
                                home.motionCameraIDs = ids
                            }
                        )) {
                            settingLabel(camera.name, camera.room.isEmpty ? (camera.isDoorbell ? "Doorbell" : "Camera") : camera.room)
                        }
                    }
                } header: {
                    Text("Show When They See Motion")
                } footer: {
                    Text("The camera's live view slides onto the wall, at most every two minutes per camera. Apple doesn't share Secure Video's person, animal and package alerts with other apps, so any motion the camera reports counts.")
                }
            }

            Section {
                ForEach(members.filter { !$0.isArchived }) { person in
                    let locked = lockRevision >= 0 && ProfileLock.isLocked(person.id)
                    HStack(spacing: 12) {
                        MemberAvatar(person, size: 32)
                        Text(person.name)
                        Spacer()
                        if locked {
                            Button("Change Passcode") { passcodeFor = person }
                                .buttonStyle(.borderless)
                                .tint(.primary)
                                .font(.subheadline)
                        }
                        Toggle("Lock \(person.name)'s screen", isOn: Binding(get: { locked }, set: { on in
                            if on {
                                passcodeFor = person
                            } else {
                                ProfileLock.setLocked(false, for: person.id)
                                lockRevision += 1
                            }
                        }))
                        .labelsHidden()
                    }
                }
                if let name = ProfileLock.biometryName {
                    Toggle("Allow \(name)", isOn: $lockBiometrics)
                }
            } header: {
                Text("Profile Locks")
            } footer: {
                Text("A locked screen asks for that person's passcode before it opens, whether they tap their picture or their face is recognized. " + (ProfileLock.biometryName.map { "\($0) on this iPad can unlock any locked screen instead." } ?? ""))
            }

            Section {
                Button(pinIsSet ? "Change Parent PIN" : "Set Parent PIN") {
                    startsAfterPIN = false
                    settingPIN = true
                }
                .tint(.primary)
            } header: {
                Text("Parent PIN")
            } footer: {
                Text("The PIN unlocks approvals on the wall and leaving the Family Board, so kids can't OK their own chores. It's kept on this iPad only.")
            }

            Section {
                GuidedAccessGuide(isRunning: guidedAccess)
            } header: {
                Text("Lock This iPad to Caloma")
            }
        }
        .navigationTitle("Family Board")
        .hearthPaywall(isPresented: $showsPaywall, feature: CalomaPlus.familyBoard)
        .onAppear {
            guidedAccess = UIAccessibility.isGuidedAccessEnabled
            pinIsSet = ParentPIN.isSet
            home.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            guidedAccess = UIAccessibility.isGuidedAccessEnabled
        }
        .sheet(item: $passcodeFor) { person in
            PINSetupSheet(title: "\(person.name)'s Passcode", prompt: "Choose a 4-digit passcode for \(person.name)'s screen on the wall.", save: { pin in
                ProfileLock.setPasscode(pin, for: person.id)
                ProfileLock.setLocked(true, for: person.id)
            }) {
                lockRevision += 1
            }
            .tint(accent)
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
        guard CalomaPlus.isUnlocked else {
            showsPaywall = true
            return
        }
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
}
