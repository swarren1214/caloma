import SwiftData
import SwiftUI

/// Profile › Kiosk Mode › Faces: turn recognition on, set up each person, and the promises.
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

            if facesOn, store.needsSetupAgain {
                Section {
                    Label("Face matching was improved, so faces need setting up again. It's now much better at telling brothers and sisters apart.", systemImage: "sparkles")
                        .font(.subheadline)
                }
            }

            if facesOn, !store.isEmpty, people.contains(where: { !store.isEnrolled($0.id) }) {
                Section {
                    Label("Set up everyone who uses the wall. Caloma can only tell people apart from the faces it knows, so a brother or sister who isn't set up can be taken for one who is.", systemImage: "person.2.badge.gearshape")
                        .font(.subheadline)
                }
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
                                    Button("Set Up Again", menuIcon: "faceid") { settingUp = person }
                                    Button("Forget \(person.name)'s Face", menuIcon: "trash", role: .destructive) {
                                        store.erase(person.id)
                                    }
                                }
                                .tint(.primary)
                            } else {
                                Button("Set Up") { settingUp = person }
                                    .buttonStyle(.borderedProminent)
                                    .tint(accent)
                            }
                        }
                    }
                }

                if store.isTraining || store.report != nil {
                    Section {
                        if let report = store.report, !store.isTraining {
                            LabeledContent("Held-back looks matched", value: "\(report.correct) of \(report.checked)")
                            ForEach(report.mixUps, id: \.self) { mixUp in
                                let actual = people.first { $0.id == mixUp.actual }?.name ?? "Someone"
                                let guessed = people.first { $0.id == mixUp.guessed }?.name ?? "someone"
                                LabeledContent("\(actual) taken for \(guessed)", value: "\(mixUp.count)×")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Learning everyone's faces…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Telling Everyone Apart")
                    } footer: {
                        Text("Caloma trains a small model on just your family, on this iPad, and checks it on looks it kept aside. Anyone taken for someone else here will be mixed up at the wall too: set them up again in brighter, even light.")
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
        .alert("Turn off Recognize Faces?", isPresented: $confirmsOff) {
            Button("Turn Off and Erase Faces", role: .destructive) {
                store.eraseAll()
                facesOn = false
            }
            Button("Cancel", role: .cancel) {}
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
                .foregroundStyle(.secondary)
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
        let calibrated = FaceStore.shared.family.isCalibrated
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
                LabeledContent("Close enough", value: recognizer.latest.pixelHeight >= FaceAnalyzer.minimumFacePixels ? "Yes (\(Int(recognizer.latest.pixelHeight)) px)" : "No (\(Int(recognizer.latest.pixelHeight)) px)")
                LabeledContent("Following", value: recognizer.following.flatMap { id in members.first { $0.id == id }?.name } ?? "No one")
            }
            if !recognizer.chances.isEmpty {
                Section {
                    ForEach(recognizer.chances, id: \.id) { entry in
                        let name = members.first { $0.id == entry.id }?.name ?? "Someone"
                        let match = recognizer.verdict == .match(entry.id)
                        let close: Bool = {
                            if case .closeCall(let a, let b) = recognizer.verdict { return entry.id == a || entry.id == b }
                            return false
                        }()
                        LabeledContent {
                            Text(entry.probability.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                                .fontWeight(.semibold)
                                .foregroundStyle(match ? Color(hex: 0x1E9E6A) : close ? Color.orange : .secondary)
                        } label: {
                            Text(name + (close ? " · close call" : "")).fontWeight(match ? .semibold : .regular)
                        }
                    }
                } header: {
                    Text("Who It Is")
                } footer: {
                    Text("From the model trained on your family. A match needs \(FaceStore.matchChance.formatted(.percent)) or more, well ahead of the next person, in 3 of 4 looks; two people both over \(FaceStore.closeCallChance.formatted(.percent)) is a close call, and the wall asks which.")
                }
            }
            Section {
                if recognizer.scores.isEmpty {
                    Text("No clear face yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recognizer.scores, id: \.id) { entry in
                    let name = members.first { $0.id == entry.id }?.name ?? "Someone"
                    let match = recognizer.verdict == .match(entry.id)
                    let close: Bool = {
                        if case .closeCall(let a, let b) = recognizer.verdict { return entry.id == a || entry.id == b }
                        return false
                    }()
                    LabeledContent {
                        HStack(spacing: 10) {
                            if let standout = entry.standout {
                                Text(standout.formatted(.number.precision(.fractionLength(1))) + "×")
                                    .fontWeight(.semibold)
                            }
                            Text(entry.similarity.formatted(.number.precision(.fractionLength(3))))
                                .font(entry.standout == nil ? .body : .caption)
                        }
                        .monospacedDigit()
                        .foregroundStyle(match ? Color(hex: 0x1E9E6A) : close ? Color.orange : .secondary)
                    } label: {
                        Text(name + (close ? " · close call" : "")).fontWeight(match ? .semibold : .regular)
                    }
                }
            } header: {
                Text(recognizer.chances.isEmpty ? "Match Scores" : "Face Print Scores")
            } footer: {
                if calibrated {
                    Text("The big number is how far each person stands out from how close the rest of the family usually comes to them. A match needs \(FamilyFaceModel.matchStandout.formatted())× or more, \(FamilyFaceModel.standoutMargin.formatted())× ahead of the next person, in 3 of 4 looks. Two people both over \(FamilyFaceModel.closeCallStandout.formatted())× is a close call, and the wall asks which.")
                } else {
                    Text("Set up two or more people for family matching. Until then a match needs \(embedder.matchThreshold.formatted()) or more, in 3 of 4 looks. " + (FaceEmbedder.usesFaceModel ? "Using the face model." : "Using Apple's on-device image matching; a dedicated face model will be more accurate."))
                }
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
