import SwiftData
import SwiftUI

/// Family › Kiosk Mode › Faces: turn recognition on, set up each person, and the promises.
struct FacesSettingsView: View {
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.kioskFaces) private var facesOn = false

    @State private var settingUp: Member?
    @State private var confirmsOff = false
    private let store = FaceStore.shared

    private var people: [Member] { members.filter { !$0.isArchived } }

    var body: some View {
        Form {
            Section {
                Toggle("Recognize Faces", isOn: Binding(get: { facesOn }, set: { on in
                    if on { facesOn = true } else if store.isEmpty { facesOn = false } else { confirmsOff = true }
                }))
            } footer: {
                Text("When someone walks up to the wall, Caloma says hi and opens their screen. The camera is only on while the Family Board is showing.")
            }

            if facesOn {
                Section("Family") {
                    ForEach(people) { person in
                        HStack(spacing: 12) {
                            MemberAvatar(person, size: 40)
                                .overlay(Circle().strokeBorder(person.color.color, lineWidth: 3))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name)
                                Text(store.isEnrolled(person.id) ? "Set up" : "Not set up")
                                    .font(.footnote.weight(store.isEnrolled(person.id) ? .semibold : .regular))
                                    .foregroundStyle(store.isEnrolled(person.id) ? Color(hex: 0x1E9E6A) : .secondary)
                            }
                            Spacer()
                            if store.isEnrolled(person.id) {
                                Menu("Redo") {
                                    Button("Set Up Again", systemImage: "faceid") { settingUp = person }
                                    Button("Forget \(person.name)'s Face", systemImage: "trash", role: .destructive) {
                                        store.erase(person.id)
                                    }
                                }
                            } else {
                                Button("Set Up") { settingUp = person }
                                    .buttonStyle(.borderedProminent)
                                    .tint(accent)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("Test Recognition") { FaceTestView() }
                } footer: {
                    Text("Shows who Caloma thinks is in front of the camera, and how sure it is.")
                }
            }

            Section {
                promise("lock.iphone", "On this iPad only", "Face data stays in this iPad's protected storage. It isn't synced, uploaded, backed up or shared, and photos are never kept.")
                promise("key.slash", "Convenience, not a key", "Approvals, doors, the garage and leaving the Family Board always need the parent PIN.")
                promise("trash", "Easy to remove", "Turn off Recognize Faces, or redo someone, and what was learned is erased.")
            }
        }
        .navigationTitle("Faces")
        .fullScreenCover(item: $settingUp) { person in
            FaceEnrollmentView(member: person) { nextID in
                // The cover swaps straight to the next person.
                settingUp = people.first { $0.id == nextID }
            }
        }
        .confirmationDialog("Turn off Recognize Faces?", isPresented: $confirmsOff, titleVisibility: .visible) {
            Button("Turn Off and Erase Faces", role: .destructive) {
                store.eraseAll()
                facesOn = false
            }
        } message: {
            Text("Everyone's face is erased from this iPad. You can set them up again later.")
        }
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(accent)
        }
        .padding(.vertical, 2)
    }
}

/// The camera and everyone's match score, live, for checking recognition works in this room.
private struct FaceTestView: View {
    @Query(sort: \Member.sortOrder) private var members: [Member]
    private let recognizer = FaceRecognizer.shared

    var body: some View {
        let embedder = FaceEmbedder.current
        List {
            Section {
                FaceCameraPreview(camera: recognizer.camera)
                    .frame(height: 320)
                    .clipShape(.rect(cornerRadius: 16))
                    .listRowInsets(EdgeInsets())
            }
            Section {
                LabeledContent("Faces in view", value: recognizer.latest.faceCount.formatted())
                LabeledContent("Clarity", value: recognizer.latest.quality.formatted(.percent.precision(.fractionLength(0))))
                LabeledContent("Close enough", value: recognizer.latest.box.height >= FaceRecognizer.minimumFaceHeight ? "Yes" : "No")
            }
            Section {
                if recognizer.scores.isEmpty {
                    Text("No clear face yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(recognizer.scores.enumerated()), id: \.offset) { index, entry in
                    let name = members.first { $0.id == entry.id }?.name ?? "Someone"
                    let match = index == 0 && entry.score >= embedder.matchThreshold
                    LabeledContent {
                        Text(entry.score.formatted(.number.precision(.fractionLength(3))))
                            .monospacedDigit()
                            .foregroundStyle(match ? Color(hex: 0x1E9E6A) : .secondary)
                    } label: {
                        Text(name).fontWeight(match ? .semibold : .regular)
                    }
                }
            } header: {
                Text("Match Scores")
            } footer: {
                Text("A match needs \(embedder.matchThreshold.formatted()) or more, \(embedder.margin.formatted()) ahead of the next person, in 3 of 4 looks. " + (FaceEmbedder.usesFaceModel ? "Using the face model." : "Using Apple's on-device image matching; a dedicated face model will be more accurate."))
            }
        }
        .navigationTitle("Test Recognition")
        .task {
            await recognizer.start(.recognize)
        }
        .onDisappear {
            recognizer.stop()
        }
    }
}
