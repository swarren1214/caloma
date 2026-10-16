import SwiftUI

/// Two people the camera can't tell apart right now, and the look it had.
struct CloseCall: Identifiable {
    let id = UUID()
    let first: UUID
    let second: UUID
    let look: [Float]
}

/// "Ellie or Sam?": when brothers or sisters keep coming out about even, the wall asks
/// instead of guessing. The pick opens their screen and, if the camera was leaning that way,
/// teaches it this look.
struct CloseCallPicker: View {
    var call: CloseCall
    var first: Member
    var second: Member
    var onPick: (Member) -> Void

    var body: some View {
        VStack(spacing: 26) {
            Text("\(first.name) or \(second.name)?")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            HStack(spacing: 36) {
                choice(first)
                choice(second)
            }
            Text("You two look alike to the camera. A tap helps it learn.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .presentationDetents([.medium])
    }

    private func choice(_ person: Member) -> some View {
        Button {
            onPick(person)
        } label: {
            VStack(spacing: 10) {
                MemberAvatar(person, size: 120)
                    .padding(5)
                    .overlay(Circle().strokeBorder(person.color.color, lineWidth: 5))
                Text(person.name)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(KidPressStyle())
        .accessibilityLabel("I'm \(person.name)")
    }
}
