import CloudKit
import Foundation
import OSLog
import SwiftData

/// Keeps the family's data in step through CloudKit, so both parents (on their own Apple
/// Accounts), and every phone and iPad on them, see the same family.
///
/// How it works:
/// - Everything is saved on the device with SwiftData, as before.
/// - SwiftData's history says what changed locally; those changes are queued on a
///   `CKSyncEngine`, which sends them when it can and fetches everyone else's.
/// - The family lives in one record zone, "Family". It's in the private database of the parent
///   who set the family up (the owner). Sharing the whole zone lets the other parent join:
///   their phone then syncs the same zone through its shared database.
/// - Changes from iCloud are saved by a context whose author is "sync", so they aren't sent
///   back up.
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    nonisolated enum Role: String, Codable, Sendable {
        /// Syncing through this Apple Account's private database. Not shared (yet).
        case solo
        /// Shared this family with others.
        case owner
        /// Joined someone else's family.
        case participant
    }

    enum Status: Equatable {
        case off
        case noAccount
        case syncing
        case upToDate
        case failed(String)
    }

    private(set) var role: Role = .solo
    private(set) var status: Status = .off
    private(set) var lastSynced: Date?
    /// An invitation someone tapped, waiting for them to say Join.
    var pendingInvite: CKShare.Metadata?
    /// Something to tell the person, like "You left the family."
    var notice: String?

    let ckContainer = CKContainer(identifier: AppConfig.cloudKitContainerID)
    private(set) var modelContainer: ModelContainer?
    private var engine: CKSyncEngine?
    private let delegate = SyncEngineDelegate()
    private var state = SyncState()
    /// Each record's CloudKit system fields (its change tag), by record name.
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    /// Each model's id by its SwiftData identifier, for sending deletes and finding records.
    @ObservationIgnored private var idsByModel: [PersistentIdentifier: UUID] = [:]
    @ObservationIgnored private var mapsChanged = false
    /// Failed sends per record this session.
    @ObservationIgnored private var retries: [String: Int] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "sync")

    static let author = "sync"
    static let zoneName = "Family"

    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: state.zoneName, ownerName: state.zoneOwner) }
    var database: CKDatabase { role == .participant ? ckContainer.sharedCloudDatabase : ckContainer.privateCloudDatabase }
    var isShared: Bool { role != .solo }

    private init() {}

    // MARK: Starting

    /// Starts syncing, once, at launch.
    func start(with container: ModelContainer) {
        guard AppConfig.cloudSyncEnabled, modelContainer == nil else { return }
        modelContainer = container
        state = SyncState.load()
        let maps = SyncMaps.load()
        systemFields = maps.systemFields
        idsByModel = maps.modelIDs
        role = state.role
        SyncMaps.removeOldAssetFiles()
        observeSaves()
        Task { await startEngine() }
    }

    private func startEngine() async {
        do {
            let account = try await ckContainer.accountStatus()
            guard account == .available else {
                status = .noAccount
                return
            }
        } catch {
            status = .noAccount
            return
        }
        let configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state.engineState, delegate: delegate)
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        status = .syncing
        if role != .participant {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        rememberAllIDs()
        if !state.didInitialUpload {
            queueEverything()
            state.didInitialUpload = true
        }
        scanHistory()
        saveState()
    }

    /// Stops the engine (to switch families or start over).
    private func stopEngine() {
        engine = nil
        status = .off
    }

    /// Queues every record, for the first sync or after starting over.
    private func queueEverything() {
        guard let engine, let context = makeContext() else { return }
        var ids: [CKRecord.ID] = []
        for type in SyncSchema.types {
            ids += allModels(of: type, in: context).map { recordID(for: $0.id) }
        }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        // Everything is queued, so history up to now has been handled.
        state.historyToken = latestHistoryToken(in: context)
        saveState()
    }

    /// Fetches and sends now (pull to refresh, coming back to the app).
    func syncNow() async {
        guard let engine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            status = .upToDate
            lastSynced = .now
        } catch {
            fail(error)
        }
    }

    // MARK: Local changes

    private func observeSaves() {
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            let author = (note.object as? ModelContext)?.author
            MainActor.assumeIsolated {
                guard author != CloudSync.author else { return }
                self?.scheduleScan()
            }
        }
        observers.append(observer)
    }

    /// Looks at what changed a moment after a save, so a burst of saves goes up together.
    func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.scanHistory()
        }
    }

    /// Reads SwiftData's history since last time and queues what changed (not counting what
    /// came from iCloud).
    private func scanHistory() {
        guard let engine, let context = makeContext() else { return }
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = state.historyToken {
            descriptor.predicate = #Predicate { $0.token > token }
        }
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try context.fetchHistory(descriptor)
        } catch {
            log.error("Couldn't read history: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let last = transactions.last else { return }

        var changed = Set<PersistentIdentifier>()
        var deleted = Set<UUID>()
        for transaction in transactions where transaction.author != CloudSync.author {
            for change in transaction.changes {
                switch change {
                case .insert(let insert):
                    changed.insert(insert.changedPersistentIdentifier)
                case .update(let update):
                    changed.insert(update.changedPersistentIdentifier)
                case .delete(let delete):
                    // A deleted model can't be read, so its id comes from what sync
                    // remembered about it.
                    changed.remove(delete.changedPersistentIdentifier)
                    if let id = idsByModel.removeValue(forKey: delete.changedPersistentIdentifier) {
                        deleted.insert(id)
                    }
                @unknown default:
                    break
                }
            }
        }

        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        // Only the models that changed are looked up, not the whole store.
        for identifier in changed {
            guard let model = context.model(for: identifier) as? any CloudRecord, !model.isDeleted else { continue }
            idsByModel[identifier] = model.id
            deleted.remove(model.id)
            pending.append(.saveRecord(recordID(for: model.id)))
        }
        pending += deleted.map { .deleteRecord(recordID(for: $0)) }
        if !pending.isEmpty {
            engine.state.add(pendingRecordZoneChanges: pending)
            mapsChanged = true
        }
        state.historyToken = last.token
        // The history has been handled; keep it from growing forever.
        let handled = last.token
        try? context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token <= handled }))
        saveState()
    }

    // MARK: The engine's events

    func handle(_ event: CKSyncEngine.Event, from engine: CKSyncEngine) async {
        guard engine === self.engine else { return }
        switch event {
        case .stateUpdate(let update):
            state.engineState = update.stateSerialization
            saveState()

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                zoneWasDeleted()
            }

        case .fetchedRecordZoneChanges(let changes):
            apply(modifications: changes.modifications.map(\.record), deletions: changes.deletions.map(\.recordID))

        case .sentRecordZoneChanges(let sent):
            handleSent(sent)

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("Couldn't save the family zone: \(failure.error.localizedDescription, privacy: .public)")
            }

        case .willFetchChanges, .willSendChanges:
            status = .syncing

        case .didFetchChanges, .didSendChanges:
            status = .upToDate
            lastSynced = .now

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    func nextBatch(_ context: CKSyncEngine.SendChangesContext, for engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === self.engine, let modelContext = makeContext() else { return nil }
        let scope = context.options.scope
        let changes = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }.prefix(250)
        guard !changes.isEmpty else { return nil }

        // Build the records up front, from the store as it is now, looking up only these.
        let identifiers = identifiersByID()
        var records: [CKRecord.ID: CKRecord] = [:]
        var missing: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in changes {
            guard case .saveRecord(let recordID) = change else { continue }
            if let id = UUID(uuidString: recordID.recordName), let model = model(id, identifiers: identifiers, in: modelContext) {
                records[recordID] = makeRecord(for: model)
            } else {
                // Deleted since it was queued; the delete is (or will be) queued too.
                missing.append(change)
            }
        }
        if !missing.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: missing)
        }
        let ready = Array(changes).filter { change in
            if case .saveRecord(let recordID) = change { return records[recordID] != nil }
            return true
        }
        let provided = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: ready) { recordID in
            provided[recordID]
        }
    }

    // MARK: Applying iCloud's changes

    private func apply(modifications: [CKRecord], deletions: [CKRecord.ID]) {
        guard let context = makeContext(), !(modifications.isEmpty && deletions.isEmpty) else { return }
        let identifiers = identifiersByID()
        var inserted: [any CloudRecord] = []
        var settingsChanged = false
        var calendarChanged = !deletions.isEmpty
        for record in modifications where record.recordID.zoneID == zoneID {
            guard let type = SyncSchema.type(named: record.recordType),
                  let id = UUID(uuidString: record.recordID.recordName) else { continue }
            if let existing = model(id, identifiers: identifiers, in: context) {
                existing.read(from: record)
            } else {
                let model = type.blank()
                model.id = id
                model.read(from: record)
                context.insert(model)
                inserted.append(model)
            }
            if ObjectIdentifier(type) == ObjectIdentifier(FamilySetting.self) { settingsChanged = true }
            if ObjectIdentifier(type) == ObjectIdentifier(FamilyEvent.self) || ObjectIdentifier(type) == ObjectIdentifier(HomeTask.self) { calendarChanged = true }
            systemFields[record.recordID.recordName] = Self.encodeSystemFields(of: record)
        }
        for recordID in deletions where recordID.zoneID == zoneID {
            if let id = UUID(uuidString: recordID.recordName), let model = model(id, identifiers: identifiers, in: context) {
                idsByModel[model.persistentModelID] = nil
                context.delete(model)
            }
            systemFields[recordID.recordName] = nil
        }
        mapsChanged = true
        do {
            try context.save()
        } catch {
            log.error("Couldn't save changes from iCloud: \(error.localizedDescription, privacy: .public)")
        }
        // New models have their lasting identifiers once saved.
        for model in inserted {
            idsByModel[model.persistentModelID] = model.id
        }
        saveState()
        if settingsChanged { SharedSettings.shared.pull(from: context) }
        if calendarChanged {
            EventAlerts.reschedule(in: context)
            Reminders.reschedule(in: context)
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        guard let engine else { return }
        for record in sent.savedRecords {
            systemFields[record.recordID.recordName] = Self.encodeSystemFields(of: record)
            retries[record.recordID.recordName] = nil
        }
        for recordID in sent.deletedRecordIDs {
            systemFields[recordID.recordName] = nil
        }
        mapsChanged = true
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var needsZone = false
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            // Give up on a record after a few tries this session, so one bad record can't
            // keep sync busy forever.
            let tries = retries[recordID.recordName, default: 0] + 1
            retries[recordID.recordName] = tries
            if tries > 3 {
                log.error("Gave up sending \(recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                continue
            }
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else changed it first. Take their version's change tag and send
                // ours again on top.
                if let server = failure.error.serverRecord {
                    systemFields[recordID.recordName] = Self.encodeSystemFields(of: server)
                }
                retry.append(.saveRecord(recordID))
            case .zoneNotFound:
                needsZone = true
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .unknownItem:
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
                // The engine tries these again by itself.
                break
            default:
                log.error("Couldn't send \(recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        if needsZone && role == .participant {
            // Their zone is gone: the family isn't shared anymore.
            zoneWasDeleted()
            return
        }
        if needsZone {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        if !retry.isEmpty {
            engine.state.add(pendingRecordZoneChanges: retry)
        }
        saveState()
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            Task { await restart(resetting: true) }
        case .signOut, .switchAccounts:
            if role == .participant {
                // The family was on that account. This phone goes back to its own.
                Task { await leaveLocally(message: "iCloud signed out, so this iPhone left the family.") }
            } else {
                Task { await restart(resetting: true) }
            }
        @unknown default:
            break
        }
    }

    /// The family's zone is gone from iCloud: the owner stopped sharing or erased it.
    private func zoneWasDeleted() {
        if role == .participant {
            Task { await leaveLocally(message: "The family isn't shared with you anymore.") }
        } else {
            Task { await restart(resetting: true) }
        }
    }

    // MARK: Switching families

    /// Starts over with a fresh engine. Resetting sends everything up again.
    func restart(resetting: Bool) async {
        stopEngine()
        if resetting {
            state.engineState = nil
            systemFields = [:]
            state.didInitialUpload = false
            mapsChanged = true
        }
        saveState()
        await startEngine()
    }

    /// Becomes part of another family: everything here is replaced by what's in their zone.
    func join(zoneID: CKRecordZone.ID) async {
        stopEngine()
        eraseLocalData()
        role = .participant
        state = SyncState()
        systemFields = [:]
        idsByModel = [:]
        mapsChanged = true
        state.role = .participant
        state.zoneName = zoneID.zoneName
        state.zoneOwner = zoneID.ownerName
        state.didInitialUpload = true
        if let context = makeContext() {
            state.historyToken = latestHistoryToken(in: context)
        }
        saveState()
        UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
        UserDefaults.standard.set(true, forKey: SettingsKey.onboarded)
        UserDefaults.standard.set(true, forKey: SettingsKey.seeded)
        await startEngine()
        await syncNow()
    }

    /// After leaving (or being removed from) a family: this device starts fresh on its own.
    func leaveLocally(message: String?) async {
        stopEngine()
        eraseLocalData()
        role = .solo
        state = SyncState()
        systemFields = [:]
        idsByModel = [:]
        mapsChanged = true
        if let context = makeContext() {
            state.historyToken = latestHistoryToken(in: context)
        }
        state.didInitialUpload = true
        saveState()
        UserDefaults.standard.set(false, forKey: SettingsKey.onboarded)
        notice = message
        await startEngine()
    }

    func becameOwner() {
        role = .owner
        state.role = .owner
        saveState()
    }

    func stoppedSharing() {
        role = .solo
        state.role = .solo
        saveState()
    }

    /// Stops sending right away, before Erase All Data deletes everything locally.
    func pauseForErase() {
        scanTask?.cancel()
        stopEngine()
    }

    /// Erase All Data: the family's zone is deleted from iCloud too (or, for someone who
    /// joined, they leave). Call before the local data is deleted.
    func eraseEverywhere() async {
        stopEngine()
        let wasParticipant = role == .participant
        let zone = zoneID
        do {
            if wasParticipant {
                try await ckContainer.sharedCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone))
            } else {
                try await ckContainer.privateCloudDatabase.deleteRecordZone(withID: zone)
            }
        } catch {
            log.error("Couldn't erase iCloud data: \(error.localizedDescription, privacy: .public)")
        }
        role = .solo
        state = SyncState()
        systemFields = [:]
        idsByModel = [:]
        mapsChanged = true
        saveState()
    }

    /// After Erase All Data deleted everything locally: skip that history and start fresh.
    func didEraseLocally() async {
        idsByModel = [:]
        systemFields = [:]
        mapsChanged = true
        if let context = makeContext() {
            state.historyToken = latestHistoryToken(in: context)
        }
        state.didInitialUpload = true
        saveState()
        await startEngine()
    }

    /// Deletes every model on this device without sending the deletes anywhere.
    private func eraseLocalData() {
        guard let context = makeContext() else { return }
        for type in SyncSchema.types {
            for model in allModels(of: type, in: context) {
                context.delete(model)
            }
        }
        try? context.save()
    }

    // MARK: Helpers

    /// Remembers every model's id by its SwiftData identifier, so a delete found in the history
    /// can be sent (the deleted model itself can't be read anymore). Keeps entries for models
    /// deleted since last time until the history scan sends them.
    private func rememberAllIDs() {
        guard let context = makeContext() else { return }
        for type in SyncSchema.types {
            for model in allModels(of: type, in: context) {
                idsByModel[model.persistentModelID] = model.id
            }
        }
        mapsChanged = true
    }

    /// Each model's SwiftData identifier by its id.
    private func identifiersByID() -> [UUID: PersistentIdentifier] {
        var result: [UUID: PersistentIdentifier] = [:]
        result.reserveCapacity(idsByModel.count)
        for (identifier, id) in idsByModel { result[id] = identifier }
        return result
    }

    /// One model by its id, without fetching the rest.
    private func model(_ id: UUID, identifiers: [UUID: PersistentIdentifier], in context: ModelContext) -> (any CloudRecord)? {
        guard let identifier = identifiers[id],
              let model = context.model(for: identifier) as? any CloudRecord,
              !model.isDeleted else { return nil }
        return model
    }

    func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    private func makeRecord(for model: any CloudRecord) -> CKRecord {
        let recordID = recordID(for: model.id)
        let record: CKRecord
        if let data = systemFields[recordID.recordName], let cached = Self.decodeSystemFields(data), cached.recordID.zoneID == zoneID {
            record = cached
        } else {
            record = CKRecord(recordType: type(of: model).recordType, recordID: recordID)
        }
        model.write(to: record)
        return record
    }

    private func makeContext() -> ModelContext? {
        guard let modelContainer else { return nil }
        let context = ModelContext(modelContainer)
        context.author = CloudSync.author
        context.autosaveEnabled = false
        return context
    }

    private func fetchModels<T: CloudRecord>(_ type: T.Type, in context: ModelContext) -> [any CloudRecord] {
        ((try? context.fetch(FetchDescriptor<T>())) ?? []).map { $0 as any CloudRecord }
    }

    private func allModels(of type: any CloudRecord.Type, in context: ModelContext) -> [any CloudRecord] {
        fetchModels(type, in: context)
    }

    private func latestHistoryToken(in context: ModelContext) -> DefaultHistoryToken? {
        let transactions = (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())) ?? []
        return transactions.last?.token
    }

    private func fail(_ error: Error) {
        let message = (error as? CKError).map { Self.describe($0) } ?? error.localizedDescription
        status = .failed(message)
        log.error("Sync failed: \(error.localizedDescription, privacy: .public)")
    }

    static func describe(_ error: CKError) -> String {
        switch error.code {
        case .networkUnavailable, .networkFailure: "No internet connection. Changes will sync when you're back online."
        case .notAuthenticated: "Sign in to iCloud in Settings to sync."
        case .quotaExceeded: "iCloud storage is full."
        default: error.localizedDescription
        }
    }

    /// Saves what sync remembers a moment later, off the main thread, so a burst of events
    /// writes once. The big maps (change tags and ids) are written only when they changed.
    private func saveState() {
        state.role = role
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            let core = self.state
            let maps = self.mapsChanged ? SyncMaps(systemFields: self.systemFields, modelIDs: self.idsByModel) : nil
            self.mapsChanged = false
            await Task.detached(priority: .utility) {
                core.save()
                maps?.save()
            }.value
        }
    }

    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }
}

/// The engine's delegate. It holds nothing and hands every call to `CloudSync` on the main
/// actor, where the store is.
nonisolated final class SyncEngineDelegate: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await CloudSync.shared.handle(event, from: syncEngine)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await CloudSync.shared.nextBatch(context, for: syncEngine)
    }
}

/// What sync remembers between launches, in Application Support.
nonisolated struct SyncState: Codable, @unchecked Sendable {
    var role: CloudSync.Role = .solo
    var zoneName: String = "Family"
    var zoneOwner: String = CKCurrentUserDefaultName
    var historyToken: DefaultHistoryToken?
    var engineState: CKSyncEngine.State.Serialization?
    var didInitialUpload = false

    private static var url: URL {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("state.json")
    }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState()
        }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// The big part of what sync remembers: every record's change tag and every model's id. Kept
/// in its own file so the small state can be saved often without rewriting these.
nonisolated struct SyncMaps: Codable, @unchecked Sendable {
    var systemFields: [String: Data] = [:]
    var modelIDs: [PersistentIdentifier: UUID] = [:]

    private static var url: URL {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("maps.plist")
    }

    static func load() -> SyncMaps {
        guard let data = try? Data(contentsOf: url), let maps = try? PropertyListDecoder().decode(SyncMaps.self, from: data) else {
            return SyncMaps()
        }
        return maps
    }

    func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Photos sent as assets go through temporary files; clear out old ones.
    static func removeOldAssetFiles() {
        let folder = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("caloma-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
