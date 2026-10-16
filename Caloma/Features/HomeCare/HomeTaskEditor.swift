import SwiftData
import SwiftUI

/// New home care task and editing one.
struct HomeTaskEditor: View {
    var task: HomeTask?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.homeReminders) private var remindersOn = false

    @State private var name = ""
    @State private var symbol = "wrench.and.screwdriver"
    @State private var area: HomeArea = .other
    @State private var count = 3
    @State private var unit: IntervalUnit = .months
    @State private var nextDue = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var remindDaysBefore = 3
    @State private var location = ""
    @State private var details = ""
    @State private var notes = ""
    @State private var loaded = false
    @State private var confirmsDelete = false

    private var color: Color { Color(hex: area.colorHex) }
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol, color: color, size: 40)
                        TextField("What needs doing", text: $name)
                            .font(.title3)
                    }
                    Picker("Area", selection: $area) {
                        ForEach(HomeArea.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("Icon") {
                    IconPicker(quick: SymbolSets.homeCare, selection: $symbol, color: color, text: name)
                }

                Section {
                    Stepper(value: $count, in: 1...365) {
                        Text(HomeCareMath.intervalLabel(count: count, unit: unit))
                            .monospacedDigit()
                    }
                    Picker("Unit", selection: $unit) {
                        ForEach(IntervalUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Next Due", selection: $nextDue, displayedComponents: .date)
                    Picker("Remind", selection: $remindDaysBefore) {
                        Text("On the day").tag(0)
                        Text("1 day before").tag(1)
                        Text("3 days before").tag(3)
                        Text("1 week before").tag(7)
                        Text("2 weeks before").tag(14)
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if !remindersOn {
                        Text("Turn on Home Care Reminders in Family to get a notification.")
                    }
                }

                Section("Details") {
                    TextField("Where (Upstairs hallway)", text: $location)
                    TextField("Size or model (16×25×1 MERV 11)", text: $details)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if task != nil {
                    Section {
                        Button("Delete Task", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .contentMargins(.bottom, 56, for: .scrollContent)
            .navigationTitle(task == nil ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Task", role: .destructive) {
                    task?.isArchived = true
                    Persistence.save(context)
                    Reminders.reschedule(in: context)
                    dismiss()
                }
            }
            .onChange(of: area) { old, new in
                // Follow the area's icon until someone picks their own.
                if symbol == old.symbol || symbol == "wrench.and.screwdriver" { symbol = new.symbol }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let task else { return }
        name = task.name
        symbol = task.symbol
        area = task.area
        count = task.intervalCount
        unit = task.intervalUnit
        nextDue = task.nextDue
        remindDaysBefore = task.remindDaysBefore
        location = task.location
        details = task.details
        notes = task.notes
    }

    private func save() {
        let target: HomeTask
        if let task {
            target = task
        } else {
            target = HomeTask(name: name, symbol: symbol, area: area, intervalCount: count, unit: unit, nextDue: nextDue)
            context.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.symbol = symbol
        target.area = area
        target.intervalCount = count
        target.intervalUnit = unit
        target.nextDue = Calendar.current.startOfDay(for: nextDue)
        target.remindDaysBefore = remindDaysBefore
        target.location = location.trimmingCharacters(in: .whitespaces)
        target.details = details.trimmingCharacters(in: .whitespaces)
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Persistence.save(context)
        Reminders.reschedule(in: context)
        dismiss()
    }
}

#Preview {
    HomeTaskEditor(task: nil)
        .previewEnvironment()
}
