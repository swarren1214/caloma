import AuthenticationServices
import SwiftData
import SwiftUI

/// First run: Welcome, who's in the family, then a few chores to start with.
///
/// Signing in is optional, after Hearken's App Review rejection: everything works without it,
/// and Sign in with Apple just fills in your name. When another Hearth app on this device was
/// signed in with Apple (`HearthAccounts.appleID()`), it offers "Continue as <name>" instead,
/// so nobody signs in twice; Apple only gives the name to the first app that asks.
struct OnboardingView: View {
    @State private var step = 1
    @State private var draft = FamilyDraft()

    var body: some View {
        Group {
            switch step {
            case 1:
                WelcomeStep(draft: $draft) { withAnimation(.smooth) { step = 2 } }
            case 2:
                FamilyStep(draft: $draft) { withAnimation(.smooth) { step = 3 } }
            default:
                StarterStep(draft: $draft)
            }
        }
        .transition(.opacity)
    }
}

/// What onboarding collects before anything is saved.
struct FamilyDraft {
    struct Person: Identifiable {
        var id = UUID()
        var name = ""
        var color: KidColor = .blue
        var photo: Data?
    }

    var myName = ""
    var myPhoto: Data?
    var partnerName = ""
    var partnerPhoto: Data?
    var kids: [Person] = [Person(color: .purple)]
    var pickedChores: Set<String> = Set(StarterData.chores.prefix(6).map(\.title))
    var addRewards = true

    var namedKids: [Person] { kids.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
}

// MARK: - Step 1

private struct WelcomeStep: View {
    @Binding var draft: FamilyDraft
    var next: () -> Void

    /// Filled in by sync when this Apple Account already has a family in iCloud (a second
    /// device, or Caloma reinstalled).
    @Query(filter: #Predicate<Member> { !$0.isArchived }, sort: \Member.sortOrder) private var existing: [Member]
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    private var sync: CloudSync { CloudSync.shared }
    private var parents: [Member] { existing.filter { !$0.isKid } }

    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorMessage: String?
    /// Who signed in with Apple in another Hearth app, once Apple says that's still good.
    @State private var sharedAppleID: HearthSharedAppleID?

    var body: some View {
        OnboardingPage(title: "Caloma", subtitle: "Run the house together, and make chores something kids want to do.") { isShort in
            AppIconBadge(size: isShort ? 64 : 92)
        } content: { _ in
            VStack(alignment: .leading, spacing: 18) {
                OnboardingFeatureRow(symbol: "checklist", title: "Chores kids love", detail: "Big buttons, confetti and a progress track. Parents give the OK.")
                OnboardingFeatureRow(symbol: "gift.fill", title: "Rewards your way", detail: "Screen time, outings or allowance. You set what things cost.")
                OnboardingFeatureRow(symbol: "wrench.and.screwdriver.fill", title: "Home care on time", detail: "Filters, smoke detectors and gutters, with reminders before they're due.")
                OnboardingFeatureRow(symbol: "icloud.fill", title: "Private by design", detail: "Your family's data lives in your own iCloud. No ads, no servers.")
            }
        } controls: { _ in
            if !parents.isEmpty {
                existingFamily
            } else {
                newFamilyControls
            }
        }
        .alert("Couldn't sign in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .animation(.smooth, value: parents.count)
        .animation(.smooth, value: sharedAppleID?.userID)
        .task { await loadSharedAppleID() }
    }

    /// The first name to greet them by, when another Hearth app knows it.
    private var sharedFirstName: String? {
        guard let fullName = sharedAppleID?.fullName,
              let first = fullName.split(whereSeparator: \.isWhitespace).first else { return nil }
        return String(first)
    }

    /// The Apple sign-in another Hearth app shared, if it has a name and Apple still accepts it
    /// (it's revoked when they stop using Sign in with Apple for these apps).
    private func loadSharedAppleID() async {
        guard !ScreenshotMode.isOn, let shared = HearthAccounts.appleID(), shared.fullName != nil else { return }
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: shared.userID)
            if state == .authorized { sharedAppleID = shared }
        } catch {
            // Not sure, so ask Apple the usual way.
        }
    }

    private func continueAsShared() {
        guard let shared = sharedAppleID else { return }
        appleUserID = shared.userID
        if let name = sharedFirstName { draft.myName = name }
        next()
    }

    /// "Your family is already in iCloud": pick who you are and go straight in.
    private var existingFamily: some View {
        VStack(spacing: 10) {
            Text("Your family is already in iCloud. Who's using this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")?")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            ForEach(parents) { parent in
                Button {
                    currentMember = parent.id.uuidString
                    // Starter home care came with the family, so nothing to add.
                    UserDefaults.standard.set(true, forKey: SettingsKey.seeded)
                    onboarded = true
                } label: {
                    HStack(spacing: 10) {
                        MemberAvatar(name: parent.name, color: parent.color.color, photo: parent.photoData, size: 32)
                        Text("I'm \(parent.name)")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var newFamilyControls: some View {
            VStack(spacing: 6) {
                if sync.status == .syncing || sync.status == .off {
                    Label("Checking iCloud for your family…", systemImage: "icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }
                if let name = sharedFirstName {
                    Button(action: continueAsShared) {
                        HStack(spacing: 10) {
                            MemberAvatar(name: name, color: Color(.systemGray), size: 30)
                            Text("Continue as \(name)")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .accessibilityHint("Uses the Apple sign-in from your other Hearth apps")
                } else {
                    signInWithApple
                }

                Button("Not now", action: next)
                    .frame(minHeight: 44)

                Text("Optional. Signing in adds your name. Everything works without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
    }

    private var signInWithApple: some View {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                            appleUserID = credential.user
                            let fullName = credential.fullName
                                .map { $0.formatted() }
                                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                            // Shared with the other Hearth apps, which won't get the name from Apple.
                            HearthAccounts.saveAppleID(HearthSharedAppleID(userID: credential.user, fullName: fullName, email: credential.email, updatedBy: .caloma))
                            if let name = credential.fullName?.givenName, !name.isEmpty {
                                draft.myName = name
                            } else if let shared = HearthAccounts.appleID(), shared.userID == credential.user,
                                      let first = shared.fullName?.split(whereSeparator: \.isWhitespace).first {
                                draft.myName = String(first)
                            }
                        }
                        next()
                    case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                        break
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(Capsule())
    }
}

// MARK: - Step 2

private struct FamilyStep: View {
    @Binding var draft: FamilyDraft
    var next: () -> Void

    private var canContinue: Bool { !draft.myName.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        OnboardingPage(title: "Who's in the family?", subtitle: "Kids each get a color. It's theirs on the chore board and in Kid View.", step: (2, 3)) { isShort in
            OnboardingSymbolIcon(symbol: "person.3.fill", size: isShort ? 64 : 92)
        } content: { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text("PARENTS")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                VStack(spacing: 0) {
                    nameRow("Your name", text: $draft.myName, photo: $draft.myPhoto, color: Color(.systemGray))
                    Divider().padding(.leading, 66)
                    nameRow("Partner's name (optional)", text: $draft.partnerName, photo: $draft.partnerPhoto, color: Color(.systemGray))
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))

                Text("KIDS")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .padding(.top, 14)
                VStack(spacing: 0) {
                    ForEach($draft.kids) { $kid in
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                PhotoPickerAvatar(name: kid.name, color: kid.color.color, photo: $kid.photo, size: 40)
                                TextField("Kid's name", text: $kid.name)
                                    .textInputAutocapitalization(.words)
                                Menu {
                                    Picker("Color", selection: $kid.color) {
                                        ForEach(KidColor.allCases) { color in
                                            Label(color.name, systemImage: "circle.fill").tag(color)
                                        }
                                    }
                                } label: {
                                    Circle().fill(kid.color.color).frame(width: 26, height: 26)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("\(kid.name.isEmpty ? "Kid" : kid.name)'s color, \(kid.color.name)")
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 60)
                            Divider().padding(.leading, 66)
                        }
                    }
                    Button {
                        let used = draft.kids.map(\.color)
                        draft.kids.append(FamilyDraft.Person(color: KidColor.next(after: used)))
                    } label: {
                        Label("Add a Kid", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
            }
        } controls: { _ in
            OnboardingPrimaryButton(title: "Continue", action: next)
                .disabled(!canContinue)
        }
    }

    private func nameRow(_ prompt: String, text: Binding<String>, photo: Binding<Data?>, color: Color) -> some View {
        HStack(spacing: 12) {
            PhotoPickerAvatar(name: text.wrappedValue, color: color, photo: photo, size: 40)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.words)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
    }
}

// MARK: - Step 3

private struct StarterStep: View {
    @Binding var draft: FamilyDraft

    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var didSave = false

    var body: some View {
        OnboardingPage(
            title: draft.namedKids.isEmpty ? "You're all set" : "Pick a few chores",
            subtitle: draft.namedKids.isEmpty ? "Add kids any time from Family, then give them chores." : "Every kid gets these. You can change who does what, and what each is worth, later.",
            step: (3, 3)
        ) { isShort in
            OnboardingSymbolIcon(symbol: "checklist", size: isShort ? 64 : 92)
        } content: { _ in
            if !draft.namedKids.isEmpty {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        ForEach(StarterData.chores) { chore in
                            Toggle(isOn: Binding(
                                get: { draft.pickedChores.contains(chore.title) },
                                set: { on in
                                    if on { draft.pickedChores.insert(chore.title) } else { draft.pickedChores.remove(chore.title) }
                                }
                            )) {
                                HStack(spacing: 12) {
                                    IconTile(symbol: chore.symbol, color: .accentColor, size: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(chore.title)
                                        Text(detail(for: chore))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 58)
                            if chore.id != StarterData.chores.last?.id {
                                Divider().padding(.leading, 58)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))

                    Toggle(isOn: $draft.addRewards) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Start the family store")
                            Text("Screen time, outings, cash out and a family goal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 60)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                }
            }
        } controls: { _ in
            OnboardingPrimaryButton(title: "Start", action: save)
        }
    }

    private func detail(for chore: StarterData.StarterChore) -> String {
        var parts = [PointWords.current().count(chore.points)]
        switch chore.repeatRule {
        case .daily: parts.append("Daily")
        case .weekdays: parts.append("Weekdays")
        case .someDays: parts.append("Tuesdays")
        case .once: parts.append("Once")
        }
        if chore.rotates { parts.append("Kids take turns") }
        if chore.upForGrabs { parts.append("Up for grabs") }
        return parts.joined(separator: " · ")
    }

    private func save() {
        guard !didSave else { return }
        didSave = true
        let me = Member(name: draft.myName.trimmingCharacters(in: .whitespaces), role: .parent, color: .teal, sortOrder: 0)
        me.photoData = draft.myPhoto
        context.insert(me)
        let partner = draft.partnerName.trimmingCharacters(in: .whitespaces)
        if !partner.isEmpty {
            let member = Member(name: partner, role: .parent, color: .pink, sortOrder: 1)
            member.photoData = draft.partnerPhoto
            context.insert(member)
        }
        var kids: [Member] = []
        for (index, person) in draft.namedKids.enumerated() {
            let kid = Member(name: person.name.trimmingCharacters(in: .whitespaces), role: .kid, color: person.color, sortOrder: 2 + index)
            kid.photoData = person.photo
            context.insert(kid)
            kids.append(kid)
        }
        if !kids.isEmpty {
            let picked = StarterData.chores.filter { draft.pickedChores.contains($0.title) }
            StarterData.insertChores(picked, kids: kids, into: context)
            if draft.addRewards { StarterData.insertRewards(into: context) }
        }
        Persistence.save(context)
        StarterData.seedIfNeeded(in: context)
        currentMember = me.id.uuidString
        onboarded = true
    }
}

#Preview {
    OnboardingView()
        .previewEnvironment()
}
