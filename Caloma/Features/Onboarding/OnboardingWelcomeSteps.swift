import AuthenticationServices
import SwiftData
import SwiftUI

// MARK: - 1 · Welcome

struct WelcomeStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.accent) private var accent
    @Environment(\.onboardingLayout) private var layout

    /// Filled in by sync when this Apple Account already has a family in iCloud (a second
    /// device, or Caloma reinstalled).
    @Query(filter: #Predicate<Member> { !$0.isArchived }, sort: \Member.sortOrder) private var existing: [Member]
    private var parents: [Member] { existing.filter { !$0.isKid } }

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
            if parents.isEmpty {
                OnboardingPrimaryButton(title: "Get Started") {
                    flow.path = .start
                    flow.next()
                }
                OnboardingSecondaryButton(title: "Already have a family? Join it") {
                    flow.path = .join
                    flow.next()
                }
            } else {
                ExistingFamilyPicker(parents: parents)
            }
        }
        .animation(.smooth, value: parents.count)
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

/// "Your family is already in iCloud": pick who you are and go straight in. On a second device,
/// after Caloma is reinstalled, or once an invite has brought the family over.
struct ExistingFamilyPicker: View {
    var parents: [Member]
    /// Joining: lets someone not on the list add themselves.
    var canAddSelf = false

    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var addingSelf = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 10) {
            Text("Your family is already in iCloud. Who's using this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")?")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            ForEach(parents) { parent in
                Button {
                    finish(as: parent)
                } label: {
                    HStack(spacing: 12) {
                        MemberAvatar(parent, size: 34)
                        Text("I'm \(parent.name)")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .onboardingCard(cornerRadius: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if canAddSelf {
                if addingSelf {
                    HStack(spacing: 10) {
                        TextField("Your name", text: $newName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(addSelf)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .onboardingCard(cornerRadius: 24)
                        Button("Add Me", action: addSelf)
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    OnboardingSecondaryButton(title: "Not on the list? Add me") {
                        withAnimation(.smooth) { addingSelf = true }
                    }
                }
            }
        }
    }

    private func finish(as parent: Member) {
        currentMember = parent.id.uuidString
        // Starter home care came with the family, so nothing to add.
        UserDefaults.standard.set(true, forKey: SettingsKey.seeded)
        onboarded = true
    }

    private func addSelf() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<Member>())) ?? []
        let member = Member(
            name: name,
            role: .parent,
            color: KidColor.next(for: .parent, after: all.map(\.color)),
            sortOrder: (all.map(\.sortOrder).max() ?? -1) + 1
        )
        context.insert(member)
        Persistence.save(context)
        finish(as: member)
    }
}

// MARK: - 2 · Start or join

struct StartOrJoinStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.accent) private var accent
    @Environment(\.openURL) private var openURL

    @Query(filter: #Predicate<Member> { !$0.isArchived }, sort: \Member.sortOrder) private var existing: [Member]
    private var parents: [Member] { existing.filter { !$0.isKid } }
    private var sync: CloudSync { CloudSync.shared }

    var body: some View {
        OnboardingScreen(
            title: "Is your family already on Caloma?",
            subtitle: "Everyone shares one family: chores, points and the calendar stay in step on every device."
        ) {
            OnboardingSymbolIcon(symbol: "house.and.flag.fill")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                pathCard(.start, symbol: "house.fill", title: "Start our family", detail: "You'll add everyone next. Takes about two minutes.")
                pathCard(.join, symbol: "person.2.fill", title: "Join my family", detail: "Another parent already set it up and sent you an invite.")

                if flow.path == .join {
                    joinDetails
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    AppleSignInSection()
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.smooth(duration: 0.3), value: flow.path)
        } controls: {
            if flow.path == .start {
                OnboardingPrimaryButton(title: "Continue", action: flow.next)
            } else if parents.isEmpty, let messages = URL(string: "messages://") {
                OnboardingPrimaryButton(title: "Open My Invite") { openURL(messages) }
            }
        }
    }

    private func pathCard(_ path: OnboardingFlow.Path, symbol: String, title: String, detail: String) -> some View {
        let selected = flow.path == path
        return Button {
            flow.path = path
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? .white : accent)
                    .frame(width: 48, height: 48)
                    .background(selected ? accent : accent.opacity(0.14), in: .rect(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Circle()
                    .strokeBorder(selected ? accent : Color(.systemGray3), lineWidth: selected ? 7 : 2)
                    .frame(width: 24, height: 24)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .onboardingCard()
            .onboardingSelection(selected, color: accent)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var joinDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask the parent who set it up to tap \(Text("Family › Invite").bold()). Their invite opens Caloma straight into your family. Nothing to type.")
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))

            if !parents.isEmpty {
                ExistingFamilyPicker(parents: parents, canAddSelf: true)
                    .padding(.top, 6)
            } else if sync.status == .off {
                Label("Sign in to iCloud in Settings to join your family.", systemImage: "icloud.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else if sync.status == .syncing {
                Label("Checking iCloud for your family…", systemImage: "icloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .padding(.top, 4)
        .animation(.smooth, value: parents.count)
    }
}

/// Sign in with Apple, optional. When another Hearth app on this device was signed in with
/// Apple (`HearthAccounts.appleID()`), it offers "Continue as <name>" instead, so nobody signs
/// in twice; Apple only gives the name to the first app that asks.
private struct AppleSignInSection: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @State private var errorMessage: String?
    /// Who signed in with Apple in another Hearth app, once Apple says that's still good.
    @State private var sharedAppleID: HearthSharedAppleID?

    var body: some View {
        VStack(spacing: 8) {
            if !appleUserID.isEmpty {
                Label(flow.draft.myName.isEmpty ? "Signed in with Apple" : "Signed in as \(flow.draft.myName)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x1E9E6A))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .onboardingCard(cornerRadius: 25)
            } else if let name = sharedFirstName {
                Button(action: continueAsShared) {
                    HStack(spacing: 10) {
                        MemberAvatar(name: name, color: Color(.systemGray), size: 30)
                        Text("Continue as \(name)")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityHint("Uses the Apple sign-in from your other Hearth apps")
            } else {
                signInWithApple
            }
            Text("Optional. Adds your name. Everything works without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .alert("Couldn't sign in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
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
        if let name = sharedFirstName, flow.draft.myName.isEmpty { flow.draft.myName = name }
        flow.next()
    }

    private var signInWithApple: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                    appleUserID = credential.user
                    // Apple only sends the name and email the first time, so keep what another
                    // Hearth app saved for the same Apple Account rather than clearing it.
                    let previous = HearthAccounts.appleID().flatMap { $0.userID == credential.user ? $0 : nil }
                    let fullName = credential.fullName
                        .map { $0.formatted() }
                        .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                        ?? previous?.fullName
                    // Shared with the other Hearth apps, which won't get the name from Apple.
                    HearthAccounts.saveAppleID(HearthSharedAppleID(userID: credential.user, fullName: fullName, email: credential.email ?? previous?.email, updatedBy: .caloma))
                    if let name = credential.fullName?.givenName, !name.isEmpty {
                        flow.draft.myName = name
                    } else if let first = fullName?.split(whereSeparator: \.isWhitespace).first {
                        flow.draft.myName = String(first)
                    }
                }
                flow.next()
            case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                break
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .clipShape(Capsule())
    }
}
