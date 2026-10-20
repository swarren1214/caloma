import PencilKit
import SwiftData
import SwiftUI

/// The family whiteboard: draw with the Apple Pencil (or a finger, unless the iPad only draws
/// with the Pencil), pick a board, and send what's drawn to someone's wall screen with "Show
/// this when they walk up". On the wall it's the Whiteboard half of the rail's switch; in the
/// app it's its own tab.
struct WhiteboardView: View {
    /// On the Kiosk Mode wall.
    var kiosk = false

    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppRouter.self) private var router
    @Environment(KioskSession.self) private var session: KioskSession?
    @Query(sort: \Whiteboard.sortOrder) private var boards: [Whiteboard]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \WallNote.createdAt, order: .reverse) private var notes: [WallNote]

    /// The board showing, kept on this iPad so the wall comes back to the same one.
    @AppStorage("whiteboardBoardID") private var boardIDRaw = ""
    @State private var drawing = PKDrawing()
    /// What's stored for the current board; the drawing differs from it until it's saved.
    @State private var savedDrawing = PKDrawing()
    /// The board's updatedAt when this iPad last loaded or saved it; anything newer came from
    /// another device.
    @State private var syncedAt: Date?
    @State private var saveToken = 0
    /// What was there before Clear, for a few seconds of Undo.
    @State private var cleared: PKDrawing?
    @State private var clearCount = 0
    /// The Pencil is on the paper; nothing reloads underneath it.
    @State private var inStroke = false
    /// A note "from" a locked parent, waiting on their passcode before it's sent.
    @State private var pendingNote: PendingNote?
    @State private var sending = false
    @State private var renaming: Whiteboard?
    @State private var newName = ""
    @State private var deleting: Whiteboard?
    @State private var erasingNote: WallNote?

    static let black = Color(red: 0.11, green: 0.11, blue: 0.13)

    private var people: [Member] { members.filter { !$0.isArchived } }
    private var boardID: UUID? {
        get { UUID(uuidString: boardIDRaw) }
        nonmutating set { boardIDRaw = newValue?.uuidString ?? "" }
    }
    private var board: Whiteboard? { boards.first { $0.id == boardID } }
    /// Notes still on the wall for someone.
    private var onTheWall: [WallNote] {
        notes.filter { note in
            note.pinnedToWall || note.audienceIDs.contains { WallNoteQueue.isPending(note, for: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            paper
            if !onTheWall.isEmpty {
                wallStrip
            }
        }
        .padding(kiosk ? 24 : 16)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Whiteboard")
        .toolbarVisibility(kiosk ? .hidden : .automatic, for: .navigationBar)
        .onAppear(perform: setUp)
        .onDisappear { save() }
        .onChange(of: drawing) { _, new in
            if new != savedDrawing { saveToken += 1 }
        }
        .task(id: saveToken) {
            guard drawing != savedDrawing else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            save()
        }
        // Drawn on another iPad: show it. Strokes drawn here since the last save are kept on
        // top, and nothing changes mid-stroke.
        .onChange(of: board?.updatedAt) { _, _ in mergeRemote() }
        .onChange(of: inStroke) { _, drawingNow in
            if !drawingNow { mergeRemote() }
        }
        // The board was deleted (here or on another device), or boards just arrived.
        .onChange(of: boards.map(\.id)) { _, _ in
            if board == nil, let first = boards.first {
                boardID = first.id
                load(PKDrawing(savedData: first.drawing))
            }
        }
        .task(id: clearCount) {
            guard cleared != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation { cleared = nil }
        }
        .sheet(isPresented: $sending) {
            WallNoteSendSheet(drawing: drawing, people: people) { audience, from, keep, pinned in
                let pending = PendingNote(drawing: drawing.dataRepresentation(), from: from, audience: audience, keep: keep, pinned: pinned)
                sending = false
                // On the wall, sending "from" a locked parent takes their passcode.
                if kiosk, let from, ProfileLock.isLocked(from) {
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        pendingNote = pending
                    }
                } else {
                    insert(pending)
                }
            }
        }
        .sheet(item: $pendingNote) { pending in
            if let sender = people.first(where: { $0.id == pending.from }) {
                ProfileUnlockSheet(member: sender) {
                    insert(pending)
                    pendingNote = nil
                } onCancel: {
                    pendingNote = nil
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
            } else {
                Color.clear.onAppear { pendingNote = nil }
            }
        }
        .alert("Rename Board", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let renaming, !name.isEmpty {
                    renaming.name = name
                    Persistence.save(context)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete \(deleting?.name ?? "this board")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Board", role: .destructive) {
                if let deleting { delete(deleting) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The drawing on it is erased everywhere.")
        }
        .alert("Erase this note?", isPresented: Binding(get: { erasingNote != nil }, set: { if !$0 { erasingNote = nil } })) {
            Button("Erase Note", role: .destructive) {
                if let erasingNote {
                    context.delete(erasingNote)
                    Persistence.save(context)
                }
                erasingNote = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It won't show on the wall anymore.")
        }
    }

    // MARK: Header: boards, Clear, send. Pens, widths, colors, the eraser, the ruler and
    // undo are Apple's own tool palette, which floats over the paper.

    private var header: some View {
        HStack(spacing: 12) {
            boardPicker
            clearButton
            sendButton(short: sizeClass == .compact)
        }
    }

    private var boardPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(boards) { item in
                    boardChip(item)
                }
                Button {
                    addBoard()
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 38, height: 38)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New board")
            }
        }
        .scrollIndicators(.hidden)
    }

    private func sendButton(short: Bool) -> some View {
        Button {
            send()
        } label: {
            Label(short ? "Show on Wall" : "Show When They Walk Up", systemImage: "person.crop.circle.badge.checkmark")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 42)
                .foregroundStyle(.white)
                .background(drawing.hasInk ? accent : Color.secondary.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!drawing.hasInk)
        .fixedSize()
    }

    private func boardChip(_ item: Whiteboard) -> some View {
        let on = item.id == boardID
        return Button {
            select(item)
        } label: {
            Text(item.name.isEmpty ? "Board" : item.name)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .foregroundStyle(on ? .white : .primary)
                .background(on ? accent : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", menuIcon: "pencil") {
                newName = item.name
                renaming = item
            }
            if boards.count > 1 {
                Button("Delete", menuIcon: "trash", role: .destructive) { deleting = item }
            }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Clear, then Undo for a few seconds after.
    @ViewBuilder
    private var clearButton: some View {
        if let cleared {
            Button("Undo") {
                drawing = cleared
                withAnimation { self.cleared = nil }
            }
            .font(.subheadline.weight(.semibold))
            .transition(.opacity)
            .fixedSize()
        } else {
            Button("Clear") {
                guard drawing.hasInk else { return }
                withAnimation { cleared = drawing }
                clearCount += 1
                drawing = PKDrawing()
            }
            .font(.subheadline.weight(.semibold))
            .disabled(!drawing.hasInk)
            .fixedSize()
        }
    }

    // MARK: The paper

    private var paper: some View {
        PencilCanvas(
            drawing: $drawing,
            tool: .pen(Self.black, width: 5),
            onPencilTap: nil,
            onDrawingChange: { drawingNow in
                inStroke = drawingNow
                // Drawing counts as using the wall, so it doesn't idle back to the calendar.
                if drawingNow { session?.touched() }
            },
            toolPicker: PencilToolPicker(isVisible: (kiosk || router.tab == .whiteboard) && renaming == nil && deleting == nil && erasingNote == nil && !sending && pendingNote == nil)
        )
        .background {
            ZStack {
                PencilPaper.color
                DotGrid()
            }
        }
        .clipShape(.rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(PencilPaper.border))
        .overlay {
            // Gone the moment the Pencil touches down, not when the first stroke ends.
            if !drawing.hasInk && !inStroke {
                VStack(spacing: 8) {
                    Image(systemName: "applepencil.and.scribble")
                        .font(.system(size: 40))
                    Text("Draw anything")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(PencilPaper.hint)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Notes on the wall

    private var wallStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On the Wall")
                .font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(onTheWall) { note in
                        wallNoteThumb(note)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func wallNoteThumb(_ note: WallNote) -> some View {
        let audience = note.audienceIDs.compactMap { id in people.first { $0.id == id } }
        let image = PKDrawing(savedData: note.drawing).paperImage(scale: 1, margin: 16, background: UIColor(WallNotePaper.color))
        return HStack(spacing: 10) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    WallNotePaper.color
                }
            }
            .frame(width: 84, height: 60)
            .background(WallNotePaper.color)
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: -6) {
                    ForEach(audience) { person in
                        MemberAvatar(person, size: 22)
                            .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                    }
                }
                Text("For \(audience.map(\.name).formatted(.list(type: .and)))")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(note.pinnedToWall ? "\(note.keep.title) · Pinned" : note.keep.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button {
                erasingNote = note
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Erase note")
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: Boards

    private func setUp() {
        WallNoteQueue.sweep(notes, in: context)
        if boards.isEmpty {
            // Fixed ids, so two iPads opening the whiteboard before they sync make the same
            // two boards rather than four.
            let fridge = Whiteboard(name: "Fridge Note", sortOrder: 0)
            fridge.id = FamilySetting.id(for: "whiteboard.fridge")
            let doodles = Whiteboard(name: "Doodles", sortOrder: 1)
            doodles.id = FamilySetting.id(for: "whiteboard.doodles")
            context.insert(fridge)
            context.insert(doodles)
            Persistence.save(context)
            boardID = fridge.id
            load(PKDrawing())
            return
        }
        if let board {
            load(PKDrawing(savedData: board.drawing))
        } else if let first = boards.first {
            boardID = first.id
            load(PKDrawing(savedData: first.drawing))
        }
    }

    /// The board changed on another iPad. With nothing unsaved here it simply shows; with
    /// strokes drawn here since the last save, those go on top of the new drawing.
    private func mergeRemote() {
        guard !inStroke, let board, board.updatedAt != syncedAt else { return }
        syncedAt = board.updatedAt
        let remote = PKDrawing(savedData: board.drawing)
        if drawing == savedDrawing {
            load(remote)
        } else if drawing.strokes.count >= savedDrawing.strokes.count {
            let added = drawing.strokes.dropFirst(savedDrawing.strokes.count)
            savedDrawing = remote
            drawing = PKDrawing(strokes: remote.strokes + added)
        } else {
            // Something was erased here: this iPad's version wins when it saves.
            savedDrawing = remote
            saveToken += 1
        }
    }

    private func insert(_ pending: PendingNote) {
        let note = WallNote(drawing: pending.drawing, from: pending.from, audience: pending.audience, keep: pending.keep, pinned: pending.pinned)
        context.insert(note)
        Persistence.save(context)
    }

    private func select(_ item: Whiteboard) {
        guard item.id != boardID else { return }
        save()
        boardID = item.id
        cleared = nil
        load(PKDrawing(savedData: item.drawing))
    }

    /// Shows a drawing without counting it as a change.
    private func load(_ saved: PKDrawing) {
        syncedAt = board?.updatedAt
        savedDrawing = saved
        drawing = saved
    }

    private func save() {
        guard drawing != savedDrawing, let board else { return }
        board.drawing = drawing.dataRepresentation()
        board.updatedAt = .now
        syncedAt = board.updatedAt
        savedDrawing = drawing
        Persistence.save(context)
    }

    private func addBoard() {
        save()
        let next = Whiteboard(name: "Board \(boards.count + 1)", sortOrder: (boards.map(\.sortOrder).max() ?? 0) + 1)
        context.insert(next)
        Persistence.save(context)
        boardID = next.id
        cleared = nil
        load(PKDrawing())
        newName = next.name
        renaming = next
    }

    private func delete(_ item: Whiteboard) {
        let wasCurrent = item.id == boardID
        context.delete(item)
        Persistence.save(context)
        if wasCurrent, let first = boards.first(where: { $0.id != item.id }) {
            boardID = first.id
            load(PKDrawing(savedData: first.drawing))
        }
    }

    private func send() {
        save()
        sending = true
    }
}

/// A wall note waiting to be sent.
struct PendingNote: Identifiable {
    let id = UUID()
    var drawing: Data
    var from: UUID?
    var audience: [UUID]
    var keep: WallNoteKeep
    var pinned: Bool
}

/// Faint dots, like a whiteboard's grid.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 28
            var y = step
            while y < size.height {
                var x = step
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(PencilPaper.marks))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// "Show this when they walk up": who it's for, who it's from, how long it keeps showing, and
/// whether it stays pinned in the whiteboard's list.
struct WallNoteSendSheet: View {
    var drawing: PKDrawing
    var people: [Member]
    var onSend: (_ audience: [UUID], _ from: UUID?, _ keep: WallNoteKeep, _ pinned: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var audience: Set<UUID> = []
    @State private var from: UUID?
    @State private var keep: WallNoteKeep = .once
    @State private var pinned = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image = drawing.paperImage(scale: 2, margin: 20, background: UIColor(WallNotePaper.color)) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .background(WallNotePaper.color)
                            .clipShape(.rect(cornerRadius: 12))
                    }
                }
                Section("Show it to") {
                    peopleRow(selected: { audience.contains($0) }) { id in
                        if audience.contains(id) { audience.remove(id) } else { audience.insert(id) }
                    }
                }
                Section("From") {
                    peopleRow(selected: { from == $0 }) { id in
                        from = from == id ? nil : id
                    }
                }
                Section {
                    Picker("Keep Showing", selection: $keep) {
                        ForEach(WallNoteKeep.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Pin to the Whiteboard", isOn: $pinned)
                } footer: {
                    Text(keep.detail + (pinned ? ". It also stays in the whiteboard's list until someone erases it." : "."))
                }
            }
            .navigationTitle("Show When They Walk Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Send") {
                        onSend(people.map(\.id).filter { audience.contains($0) }, from, keep, pinned)
                    }
                    .disabled(audience.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func peopleRow(selected: @escaping (UUID) -> Bool, toggle: @escaping (UUID) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(people) { person in
                    let on = selected(person.id)
                    Button {
                        toggle(person.id)
                    } label: {
                        VStack(spacing: 5) {
                            MemberAvatar(person, size: 46)
                                .padding(3)
                                .overlay(Circle().strokeBorder(on ? person.color.color : .clear, lineWidth: 3))
                                .overlay(alignment: .bottomTrailing) {
                                    if on {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.white, person.color.color)
                                    }
                                }
                            Text(person.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(on ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(person.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}
