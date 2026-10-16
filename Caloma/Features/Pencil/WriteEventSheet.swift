import PencilKit
import SwiftData
import SwiftUI

/// "Write an Event": tap who it's for (the Pencil switches to their color), write what and
/// when, and Add. Caloma reads the handwriting on the device; the handwritten title stays on
/// the event in the writer's color. A time it can't read never blocks saving: the picker under
/// WHEN is used instead.
struct WriteEventSheet: View {
    /// The day it was opened for, used when no day is written.
    var day: Date
    /// On the Kiosk Mode wall: no typing, and a locked writer's passcode before it's added.
    var onTheWall = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(KioskSession.self) private var session: KioskSession?
    @Query(sort: \Member.sortOrder) private var members: [Member]

    @State private var who: [UUID] = []
    @State private var inkMemberID: UUID?
    @State private var erasing = false

    @State private var what = PKDrawing()
    @State private var when = PKDrawing()
    @State private var notes = PKDrawing()
    @State private var typedWhat = ""
    @State private var typedWhen = ""
    @State private var typedNotes = ""
    @State private var typing: Field?

    @State private var fallback: Date
    /// What was read from WHEN, shown under it once it's been read.
    @State private var readWhen: String?
    @State private var timeUnreadable = false
    @State private var saving = false
    @State private var unlocking: Member?
    /// Whose passcode was already given in this sheet.
    @State private var unlockedWriter: UUID?

    enum Field: Hashable {
        case what, when, notes
    }

    init(day: Date, onTheWall: Bool = false) {
        self.day = day
        self.onTheWall = onTheWall
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        // The next whole hour today, or 9 in the morning on another day.
        let hour = calendar.isDateInToday(day) ? min(calendar.component(.hour, from: .now) + 1, 23) : 9
        _fallback = State(initialValue: calendar.date(byAdding: .hour, value: hour, to: start) ?? start)
    }

    private var people: [Member] { members.filter { !$0.isArchived } }
    private var inkMember: Member? { people.first { $0.id == inkMemberID } }
    private var ink: Color { inkMember?.color.color ?? WhiteboardView.black }
    private var tool: PencilTool { erasing ? .eraser : .pen(ink, width: 4.5) }
    private var hasTitle: Bool {
        what.hasInk || !typedWhat.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    whoRow
                    box(.what, label: "WHAT", hint: "Soccer practice", height: 150, drawing: $what, typed: $typedWhat)
                    VStack(alignment: .leading, spacing: 8) {
                        box(.when, label: "WHEN", hint: "Tue 4:30  ·  Sat 10–12  ·  tomorrow 6", height: 110, drawing: $when, typed: $typedWhen)
                        HStack(spacing: 10) {
                            Image(systemName: timeUnreadable ? "exclamationmark.circle.fill" : "clock")
                                .foregroundStyle(timeUnreadable ? Brand.waiting : .secondary)
                            Text(timeUnreadable ? "Couldn't read \u{201C}\(readWhen ?? "")\u{201D} as a time. Check it here, then Add." : "Or pick it")
                                .font(.subheadline.weight(timeUnreadable ? .semibold : .regular))
                                .foregroundStyle(timeUnreadable ? Brand.waiting : .secondary)
                            Spacer()
                            DatePicker("Time", selection: $fallback)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 4)
                    }
                    box(.notes, label: "NOTES", hint: "Bring cleats", height: 130, drawing: $notes, typed: $typedNotes)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Write an Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Button {
                        erasing.toggle()
                    } label: {
                        Label(erasing ? "Eraser" : "Pen", systemImage: erasing ? "eraser.fill" : "pencil.tip")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityHint("Double-tap the Pencil to switch, too")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Add") { add() }
                            .disabled(!hasTitle)
                    }
                }
            }
            .interactiveDismissDisabled(what.hasInk || when.hasInk || notes.hasInk)
            .onChange(of: when) { _, _ in timeUnreadable = false }
            // On the wall, a face walking up doesn't swap screens out from under the writing.
            .onAppear { session?.setComposing(true) }
            .onDisappear { session?.setComposing(false) }
            // Walked away mid-event: the wall goes back to the calendar and this closes.
            .onChange(of: session?.idleResets) { _, _ in dismiss() }
            .onChange(of: typedWhen) { _, _ in timeUnreadable = false }
        }
        .presentationDetents([.large])
        .sheet(item: $unlocking) { person in
            ProfileUnlockSheet(member: person) {
                unlocking = nil
                unlockedWriter = person.id
                save()
            } onCancel: {
                unlocking = nil
            }
            .presentationDetents([.large])
            .onAppear {
                FaceRecognizer.shared.pause(true)
                KioskPresence.shared.pause(true)
            }
            .onDisappear {
                FaceRecognizer.shared.pause(false)
                KioskPresence.shared.pause(false)
            }
        }
    }

    // MARK: Who

    private var whoRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("WHO", hint: who.isEmpty ? "Everyone" : nil)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(people) { person in
                        let on = who.contains(person.id)
                        Button {
                            toggle(person)
                        } label: {
                            HStack(spacing: 8) {
                                MemberAvatar(person, size: 30)
                                Text(person.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(on ? .white : .primary)
                            }
                            .padding(.leading, 4)
                            .padding(.trailing, 14)
                            .frame(height: 40)
                            .background(on ? person.color.color : Color(.secondarySystemGroupedBackground), in: Capsule())
                            .overlay(Capsule().strokeBorder(person.id == inkMemberID ? Color.primary.opacity(0.35) : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(person.name)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Picking someone writes in their color; taking the writer out goes back to the last one
    /// picked, or black.
    private func toggle(_ person: Member) {
        if let index = who.firstIndex(of: person.id) {
            who.remove(at: index)
            if inkMemberID == person.id { inkMemberID = who.last }
        } else {
            who.append(person.id)
            inkMemberID = person.id
        }
        erasing = false
    }

    // MARK: Writing boxes

    private func label(_ title: String, hint: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func box(_ field: Field, label title: String, hint: String, height: CGFloat, drawing: Binding<PKDrawing>, typed: Binding<String>) -> some View {
        let isTyping = typing == field
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                label(title, hint: nil)
                Spacer()
                if drawing.wrappedValue.hasInk && !isTyping {
                    Button("Clear") {
                        drawing.wrappedValue = PKDrawing()
                        if field == .when { timeUnreadable = false }
                    }
                    .font(.caption.weight(.semibold))
                }
                // Typing is the fallback in the app; the wall is for the Pencil.
                if !onTheWall {
                    Button {
                        typing = isTyping ? nil : field
                    } label: {
                        Image(systemName: isTyping ? "applepencil.tip" : "keyboard")
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityLabel(isTyping ? "Write instead" : "Type instead")
                }
            }
            Group {
                if isTyping {
                    TextField(hint, text: typed, axis: .vertical)
                        .font(.title3)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                } else {
                    PencilCanvas(drawing: drawing, tool: tool, onPencilTap: { erasing.toggle() })
                        .frame(height: height)
                        .overlay(alignment: .topLeading) {
                            if !drawing.wrappedValue.hasInk {
                                Text(hint)
                                    .font(.title3)
                                    .foregroundStyle(Color.black.opacity(0.18))
                                    .padding(16)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background {
                            // Writing lines.
                            VStack(spacing: 0) {
                                Spacer()
                                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1).padding(.horizontal, 16).padding(.bottom, 26)
                            }
                        }
                }
            }
            .background(Color(red: 0.995, green: 0.995, blue: 0.99), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.08)))
            // Paper is always light, like the ink on it.
            .environment(\.colorScheme, .light)
        }
    }

    // MARK: Saving

    private func add() {
        // On the wall, a locked writer's passcode first, so nobody else can put events in
        // their name.
        if onTheWall, let writer = inkMember, writer.id != unlockedWriter, ProfileLock.isLocked(writer.id) {
            unlocking = writer
        } else {
            save()
        }
    }

    private func save() {
        saving = true
        Task {
            let typedTitle = typedWhat.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if !typedTitle.isEmpty {
                title = typedTitle
            } else {
                title = await HandwritingReader.text(in: what) ?? "Handwritten event"
            }

            // When: what's written, unless it already couldn't be read and the picker was checked.
            var range: EventTimeParser.Result?
            if !timeUnreadable {
                let typedTime = typedWhen.trimmingCharacters(in: .whitespacesAndNewlines)
                let written: String? = !typedTime.isEmpty ? typedTime : (when.hasInk ? await HandwritingReader.text(in: when) : nil)
                if let written {
                    range = EventTimeParser.parse(written, day: day)
                    if range == nil {
                        // Written but not readable: say so, and let them check the picker.
                        readWhen = written
                        timeUnreadable = true
                        saving = false
                        return
                    }
                }
            }
            let start = range?.start ?? fallback
            let end = range?.end ?? fallback.addingTimeInterval(3600)

            let typedNote = typedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let noteText: String
            if !typedNote.isEmpty {
                noteText = typedNote
            } else if notes.hasInk {
                noteText = await HandwritingReader.text(in: notes, separator: "\n") ?? ""
            } else {
                noteText = ""
            }

            let event = FamilyEvent(title: title, start: start, end: end, isAllDay: range?.isAllDay ?? false, attendeeIDs: people.map(\.id).filter { who.contains($0) })
            event.notes = noteText
            if typedTitle.isEmpty && what.hasInk {
                event.handwriting = what.dataRepresentation()
                event.inkMemberID = inkMemberID
            }
            context.insert(event)
            Family.didSave(event, getReady: false, in: context)
            saving = false
            dismiss()
        }
    }
}

/// An event's handwritten title, in the writer's ink on light paper.
struct EventHandwriting: View {
    var data: Data
    var maxHeight: CGFloat = 120

    var body: some View {
        if let image = PKDrawing(savedData: data).inkImage(scale: 2) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxHeight, alignment: .leading)
                .padding(10)
                .background(Color(red: 0.995, green: 0.995, blue: 0.99), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
        }
    }
}
