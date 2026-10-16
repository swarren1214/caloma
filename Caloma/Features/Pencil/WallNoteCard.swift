import PencilKit
import SwiftUI

/// The paper wall notes are drawn on.
enum WallNotePaper {
    static let color = Color(red: 1.0, green: 0.973, blue: 0.882)
}

/// A wall note dropping in over someone's screen when they walk up: the drawing on paper,
/// who it's from, and Got It or Draw Back.
struct WallNoteCard: View {
    var note: WallNote
    var viewer: Member
    var sender: Member?
    /// "1 of 3" when more are waiting.
    var position: (index: Int, count: Int)
    var onGotIt: () -> Void
    var onDrawBack: (() -> Void)?

    @State private var landed = false

    var body: some View {
        let image = PKDrawing(savedData: note.drawing).paperImage(scale: 2, margin: 24, background: UIColor(WallNotePaper.color))
        ZStack {
            Color.black.opacity(landed ? 0.28 : 0)
                .ignoresSafeArea()
                .onTapGesture {}
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    if let sender {
                        MemberAvatar(sender, size: 44)
                    } else {
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.06), in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sender.map { "From \($0.name)" } ?? "A note for you")
                            .font(.title3.weight(.bold))
                        Text("For \(viewer.name)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.black.opacity(0.5))
                    }
                    Spacer(minLength: 8)
                    if position.count > 1 {
                        Text("\(position.index) of \(position.count)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Color.black.opacity(0.07), in: Capsule())
                    }
                }
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text("(An empty note)")
                            .foregroundStyle(Color.black.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 400)
                .accessibilityLabel("Handwritten note")
                HStack(spacing: 12) {
                    if let onDrawBack {
                        Button(action: onDrawBack) {
                            Label("Draw Back", systemImage: "applepencil.tip")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(Color.black.opacity(0.8))
                                .background(Color.black.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(KidPressStyle())
                    }
                    Button(action: onGotIt) {
                        Text("Got It")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(.white)
                            .background(viewer.color.color, in: Capsule())
                    }
                    .buttonStyle(KidPressStyle())
                }
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(24)
            .frame(maxWidth: 620)
            .background(WallNotePaper.color, in: .rect(cornerRadius: 6))
            // A strip of tape at the top.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 120, height: 28)
                    .rotationEffect(.degrees(-3))
                    .offset(y: -14)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
            .rotationEffect(.degrees(landed ? -1.2 : -6))
            .offset(y: landed ? 0 : -700)
            .padding(32)
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.25)) { landed = true }
        }
    }
}

/// "Draw Back": a small canvas to answer a wall note, shown to the sender the next time they
/// walk up.
struct DrawBackSheet: View {
    var from: Member
    var to: Member
    var onSend: (PKDrawing) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var erasing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    MemberAvatar(to, size: 34)
                    Text("For \(to.name)")
                        .font(.headline)
                    Spacer()
                    Button {
                        erasing.toggle()
                    } label: {
                        Image(systemName: "eraser.fill")
                            .frame(width: 38, height: 38)
                            .foregroundStyle(erasing ? .white : .primary)
                            .background(erasing ? Color.primary.opacity(0.75) : Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Eraser")
                }
                PencilCanvas(drawing: $drawing, tool: erasing ? .eraser : .pen(from.color.color, width: 5), onPencilTap: { erasing.toggle() })
                    .background(WallNotePaper.color)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        if !drawing.hasInk {
                            Text("Write back with the Pencil")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.black.opacity(0.25))
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(20)
            .navigationTitle("Draw Back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSend(drawing) }
                        .disabled(!drawing.hasInk)
                }
            }
        }
        .presentationDetents([.large])
    }
}
