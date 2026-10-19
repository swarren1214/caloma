import CloudKit
import Foundation
import OSLog
import SwiftData

/// Keeps the family's data in step through CloudKit, so everyone in the Hearth household (each
/// on their own Apple Account), and every phone and iPad on them, sees the same family.
///
/// How it works:
/// - Everything is saved on the device with SwiftData, as before.
/// - The family lives in one record zone, "Caloma", in the Hearth container
///   (`iCloud.com.stephenwarren.hearth`), beside the household. Caloma has no engine of its own:
///   it syncs on the household's CKSyncEngines as a `HearthZoneParticipant`, so the family accepts
///   one invitation (the household's) for every Hearth app.
/// - SwiftData's history says what changed locally; those changes are queued on the household's
///   engine for the zone's database, which asks for each record (`zoneRecord(for:)`) when it sends.
/// - Where the zone is (`Location`):
///   - `.personal`: this account's private database. The household's owner shares it with
///     everyone in the household (`HearthAppSharing`, audience everyone: kids edit in Kid View).
///   - `.waiting`: this account joined someone else's household, and their Caloma hasn't shared
///     the family's zone with it yet. Nothing goes up, so this device's data never lands in the
///     wrong family.
///   - `.shared`: the household owner's zone, through the shared database. What was on this
///     device is replaced by the family's (as joining a family always did).
/// - Changes from iCloud are saved by a context whose author is "sync", so they aren't sent
///   back up.
@MainActor
@Observable
final class CloudSync: HearthZoneParticipant {
    static let shared = CloudSync()
    static let familyZoneName = "Caloma"
    let zoneName = CloudSync.familyZoneName

    nonisolated enum Location: Hashable, Codable, Sendable {
        /// This account's own zone, in its private database.
        case personal
        /// In someone else's household; their family's zone isn't shared with this account yet.
        case waiting(ownerName: String)
        /// The household owner's zone, shared with this account.
        case shared(ownerName: String)

        var isShared: Bool {
            if case .shared = self { return true }
            return false
        }
    }

    private(set) var location: Location = .personal
    /// When a sync last finished without an error. Kept between launches, for the iCloud Sync
    /// card's "Last synced".
    private(set) var lastSynced: Date? = UserDefaults.standard.object(forKey: CloudSync.lastSyncedKey) as? Date {
        didSet { UserDefaults.standard.set(lastSynced, forKey: CloudSync.lastSyncedKey) }
    }
    /// The last sync's error in words a person can act on, for the iCloud Sync card; nil once a
    /// sync succeeds, and for errors the engine retries by itself (offline, signed out).
    private(set) var errorMessage: String?
    /// Something to tell the person, like "The family isn't shared with you anymore."
    var notice: String?

    private(set) var modelContainer: ModelContainer?
    private var state = SyncState()
    @ObservationIgnored private var started = false
    /// Each record's CloudKit system fields (its change tag), by record name, for the zone in
    /// `location` only.
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    /// Each model's id by its SwiftData identifier, for sending deletes and finding records.
    @ObservationIgnored private var idsByModel: [PersistentIdentifier: UUID] = [:] {
        didSet { identifierCache = nil }
    }
    @ObservationIgnored private var identifierCache: [UUID: PersistentIdentifier]?
    @ObservationIgnored private var mapsChanged = false
    /// Failed sends per record this session.
    @ObservationIgnored private var retries: [String: Int] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastRestart: Date?
    /// Erase All Data is deleting everything locally: those deletes don't go anywhere.
    @ObservationIgnored private var isErasing = false
    /// Joining a family's zone with this device's own data: nothing goes up until it's decided.
    @ObservationIgnored private var holdsUploads = false
    /// A context reused while the engine asks for a burst of records.
    @ObservationIgnored private var sendContext: ModelContext?
    /// Why iCloud refused the last records sent, if it did.
    @ObservationIgnored private var sendError: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "sync")

    static let author = "sync"
    /// Raise to have every device send everything again once (after records were refused,
    /// like before the CloudKit schema was in Production).
    static let uploadGeneration = 1
    nonisolated static let lastSyncedKey = "sync.lastSynced"

    var household: HearthHouseholdStore { .shared }

    /// The family's zone where it is now, or nil while waiting for the family's.
    var zoneLocation: (zoneID: CKRecordZone.ID, isShared: Bool)? {
        switch location {
        case .personal: (CKRecordZone.ID(zoneName: zoneName), false)
        case .waiting: nil
        case .shared(let ownerName): (CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName), true)
        }
    }

    /// In another family's Caloma (or waiting for it).
    var isJoined: Bool { location != .personal }
    /// Shared with others: joined someone's, or the household has other people in it.
    var isShared: Bool { isJoined || !household.participants.isEmpty }
    /// Whether this device may add Caloma members for household people now: not while its data
    /// is about to be replaced by a family's, and in a family's zone only once the first full
    /// fetch of it finished (so nobody is added twice).
    var canAddPeople: Bool {
        switch location {
        case .personal: !household.isMember
        case .waiting: false
        case .shared: state.hasFamilyData
        }
    }

    private init() {}

    // MARK: Starting

    /// At launch, before the household store starts (it registers Caloma's zone with it).
    func start(with container: ModelContainer) {
        guard AppConfig.cloudSyncEnabled, !started else { return }
        started = true
        modelContainer = container
        let migrating = !SyncState.exists
        state = SyncState.load()
        if migrating {
            // The first launch on the Hearth container. A family that lived in Caloma's own
            // container goes up again from this device, unless it was someone else's family
            // (that family's owner uploads it; this device gets it when it joins).
            if SyncState.legacyRoleWasParticipant() {
                // Until this account is in that family's household and its zone, nothing here
                // goes up (`expectedLocation` keeps it waiting).
                state.legacyParticipant = true
                state.didInitialUpload = true
                state.uploadGeneration = Self.uploadGeneration
            }
            // Saved now, before the old files go, so a quit can't lose what they said.
            state.save()
            SyncState.removeLegacyFiles()
        }
        location = state.location
        systemFields = SyncMaps.load().systemFields
        SyncMaps.removeOldAssetFiles()
        household.register(self)
        observeSaves()
        rememberAllIDs()
        saveState()
    }

    /// Right after `HearthHouseholdStore.shared.start(app:)`: the engines exist now.
    func householdStarted() {
        guard started else { return }
        refreshLocation()
        let typeNames = SyncSchema.types.map { $0.recordType }.sorted()
        let newTypes = state.knownTypes.map { !Set(typeNames).isSubset(of: Set($0)) } ?? false
        state.knownTypes = typeNames
        if !state.didInitialUpload || (state.uploadGeneration ?? 0) < Self.uploadGeneration {
            // Once only (`queueEverything` marks it done); not while waiting for the family's.
            queueEverything()
        } else {
            // What this device changed that iCloud doesn't have yet (kept between launches).
            queueUnsent()
        }
        scanHistory()
        saveState()
        // A build that adds record types fetches the whole family again once: older builds
        // skipped records of types they didn't know yet.
        if newTypes { Task { await fetchWholeZone() } }
    }

    /// Shares the family's zone with the household (owner) or joins it (everyone else). Call on
    /// launch, coming to the foreground and when the household changes.
    func updateSharing() async {
        guard started, !ScreenshotMode.isOn else { return }
        refreshLocation()
        var joinedOwner: String?
        await HearthAppSharing.update(app: .caloma, zoneName: zoneName, title: "Caloma", audience: .everyone) { owner in
            joinedOwner = owner
        }
        if let joinedOwner, location != .shared(ownerName: joinedOwner) {
            markJoined(joinedOwner)
        }
    }

    /// Fetches and sends now (pull to refresh, coming back to the app).
    func syncNow() async {
        guard started else { return }
        if household.account != .available { await household.refreshAccount() }
        scanHistory()
        guard let zone = zoneLocation else {
            await household.refresh()
            return
        }
        if !state.didInitialUpload {
            queueEverything()
        } else if state.needsResend {
            // iCloud refused records earlier: try this device's unsent changes again now.
            state.needsResend = false
            queueUnsent()
        }
        await household.syncZoneNow(isShared: zone.isShared)
        if sendError == nil, household.account == .available {
            markSynced()
        }
    }

    // MARK: Where the family is

    /// Which family's zone this device should use now.
    private var expectedLocation: Location {
        guard case .member(let ownerName) = household.mode else {
            // Data from another family's Caloma (before the Hearth container) never goes into
            // this account's own zone: it waits until this account joins that family.
            return state.legacyParticipant ? .waiting(ownerName: "") : .personal
        }
        return state.joinedOwner == ownerName ? .shared(ownerName: ownerName) : .waiting(ownerName: ownerName)
    }

    /// Follows the household: joined, left, or the family's zone accepted.
    func refreshLocation() {
        guard started else { return }
        let next = expectedLocation
        guard next != location else { return }
        move(to: next)
    }

    private func move(to next: Location) {
        let previous = location
        log.notice("Family moves from \(String(describing: previous), privacy: .public) to \(String(describing: next), privacy: .public)")
        scanTask?.cancel()
        scanHistory()
        let leavesFamily = previous.isShared
        let joinsFamily = next.isShared
        // Joining from waiting with data this device never uploaded anywhere (an old Caloma
        // family whose owner isn't the household's): it's kept until the family's zone turns out
        // to be empty, and then goes up into it instead of being lost.
        var waiting = false
        if case .waiting = previous { waiting = true }
        let keepsLocal = joinsFamily && waiting && !state.hasUploaded && !state.legacyParticipant
            && !leavesFamily && hasLocalData()
        if joinsFamily {
            state.legacyParticipant = false
            state.hasFamilyData = false
            // Nothing goes up until it's clear whose data stays (it stays in `unsent`).
            holdsUploads = keepsLocal
            // The family's data comes down; nothing here is re-sent wholesale.
            state.didInitialUpload = true
            state.uploadGeneration = Self.uploadGeneration
        }
        if (leavesFamily || joinsFamily) && !keepsLocal {
            // What's here belongs to the family being left (or to this account, when joining a
            // family): it never goes into the next zone. Joining replaces it with the family's.
            eraseLocalData()
            systemFields = [:]
            retries = [:]
            mapsChanged = true
            state.hasFamilyData = false
            UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
            if joinsFamily {
                // Starter home care comes with the family.
                UserDefaults.standard.set(true, forKey: SettingsKey.seeded)
            }
        }
        location = next
        state.location = next
        saveState()
        switch next {
        case .shared where keepsLocal:
            Task { await joinKeepingLocalData() }
        case .shared:
            Task { await fetchWholeZone() }
        case .personal where leavesFamily:
            // This account's own family is still in its private database: bring it back.
            Task { await fetchWholeZone() }
        case .personal:
            // Back from waiting: what changed meanwhile goes up now.
            queueUnsent()
        case .waiting:
            break
        }
    }

    private func markJoined(_ ownerName: String) {
        state.joinedOwner = ownerName
        saveState()
        refreshLocation()
    }

    /// The family stopped sharing Caloma with this account, or removed it.
    private func lostFamilyZone() {
        guard location.isShared else { return }
        state.joinedOwner = nil
        notice = "The family’s Caloma isn’t shared with you anymore."
        errorMessage = Self.removedFromFamilyMessage
        refreshLocation()
    }

    /// Downloads every record in the family's zone, from the start. For a zone this device
    /// hasn't had (joining a family, coming back to its own), and after new record types.
    private func fetchWholeZone() async {
        guard let zone = zoneLocation, let container = household.cloudContainer, household.account == .available else { return }
        let database = zone.isShared ? container.sharedCloudDatabase : container.privateCloudDatabase
        var token: CKServerChangeToken?
        var moreComing = true
        do {
            while moreComing {
                let changes = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token)
                // Moved somewhere else meanwhile: these aren't this location's.
                guard zoneLocation?.zoneID == zone.zoneID else { return }
                let records = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                apply(modifications: records, deletions: changes.deletions.map(\.recordID))
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            if zone.isShared { state.hasFamilyData = true }
            markSynced()
            saveState()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            if zone.isShared {
                lostFamilyZone()
            }
        } catch {
            fail(error)
        }
    }

    /// Joining a family's zone with data this device never uploaded: if the family's zone is
    /// empty, this device's family goes up into it; otherwise the family's replaces it.
    private func joinKeepingLocalData() async {
        guard let zone = zoneLocation, zone.isShared else {
            holdsUploads = false
            return
        }
        guard let container = household.cloudContainer, household.account == .available else {
            backToWaiting(zone.zoneID.ownerName)
            return
        }
        defer { holdsUploads = false }
        do {
            let changes = try await container.sharedCloudDatabase.recordZoneChanges(inZoneWith: zone.zoneID, since: nil, desiredKeys: [], resultsLimit: 1)
            guard zoneLocation?.zoneID == zone.zoneID else { return }
            if changes.modificationResultsByID.isEmpty {
                log.notice("The family's Caloma is empty: this device's family goes up into it")
                holdsUploads = false
                queueEverything()
                state.hasFamilyData = true
                saveState()
                return
            }
        } catch {
            log.error("Couldn't look in the family's Caloma: \(Self.detail(error), privacy: .public)")
            backToWaiting(zone.zoneID.ownerName)
            return
        }
        eraseLocalData()
        systemFields = [:]
        retries = [:]
        mapsChanged = true
        UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
        UserDefaults.standard.set(true, forKey: SettingsKey.seeded)
        await fetchWholeZone()
    }

    /// Not sure yet whose data stays: keep what's here, wait again, and look next time
    /// `updateSharing` (or the zone appearing) joins.
    private func backToWaiting(_ ownerName: String) {
        holdsUploads = false
        location = .waiting(ownerName: ownerName)
        state.location = location
        state.joinedOwner = nil
        saveState()
    }

    private func hasLocalData() -> Bool {
        guard let context = makeContext() else { return false }
        for type in SyncSchema.types where !allModels(of: type, in: context).isEmpty { return true }
        return false
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
    /// came from iCloud). Waits until the household's engines exist.
    private func scanHistory() {
        guard started, !isErasing, household.cloudContainer != nil, let context = makeContext() else { return }
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
        for change in pending {
            switch change {
            case .saveRecord(let recordID):
                state.unsentDeletes.remove(recordID.recordName)
                state.unsentSaves.insert(recordID.recordName)
            case .deleteRecord(let recordID):
                systemFields[recordID.recordName] = nil
                state.unsentSaves.remove(recordID.recordName)
                state.unsentDeletes.insert(recordID.recordName)
            @unknown default:
                break
            }
        }
        // Kept in `unsent` until iCloud has them. While waiting for the family's zone nothing
        // goes up (`queue` drops it); they go when this device has a zone again.
        queue(pending)
        mapsChanged = true
        state.historyToken = last.token
        // The history has been handled; keep it from growing forever.
        let handled = last.token
        try? context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token <= handled }))
        saveState()
    }

    private func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        guard !changes.isEmpty, !holdsUploads, let zone = zoneLocation else { return }
        if !zone.isShared { household.ensurePrivateZone(zone.zoneID) }
        household.queueZoneChanges(changes, isShared: zone.isShared)
    }

    /// Queues this device's changes iCloud doesn't have yet (after an engine started over,
    /// coming back from waiting, or after iCloud refused records). Never everything: that would
    /// put stale copies over other devices' newer edits.
    private func queueUnsent() {
        guard zoneLocation != nil, household.cloudContainer != nil else { return }
        let saves = state.unsentSaves.compactMap(UUID.init(uuidString:)).map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(for: $0)) }
        let deletes = state.unsentDeletes.compactMap(UUID.init(uuidString:)).map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID(for: $0)) }
        queue(saves + deletes)
    }

    /// Everything on the device counts as unsent: for a zone that doesn't have it (the first
    /// upload, a new account, a deleted zone).
    private func markAllUnsent() {
        guard let context = makeContext() else { return }
        for type in SyncSchema.types {
            for model in allModels(of: type, in: context) {
                state.unsentSaves.insert(model.id.uuidString)
            }
        }
    }

    /// Queues every record, for a zone that doesn't have them yet (the first upload, a deleted
    /// zone, a new account). Each counts as unsent until iCloud has it.
    private func queueEverything() {
        guard zoneLocation != nil, household.cloudContainer != nil, let context = makeContext() else { return }
        var ids: [CKRecord.ID] = []
        for type in SyncSchema.types {
            for model in allModels(of: type, in: context) {
                idsByModel[model.persistentModelID] = model.id
                ids.append(recordID(for: model.id))
                state.unsentSaves.insert(model.id.uuidString)
            }
        }
        queue(ids.map { .saveRecord($0) })
        mapsChanged = true
        // Everything is queued, so history up to now has been handled.
        state.historyToken = latestHistoryToken(in: context)
        state.didInitialUpload = true
        state.uploadGeneration = Self.uploadGeneration
        saveState()
    }

    // MARK: HearthZoneParticipant

    func zoneRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard recordID.zoneID == zoneLocation?.zoneID, let id = UUID(uuidString: recordID.recordName),
              let context = senderContext(),
              let model = model(id, identifiers: identifiersByID(), in: context) else {
            // Deleted since it was queued (the delete is queued too), or from a zone this
            // device has left: nothing to send.
            return nil
        }
        return makeRecord(for: model)
    }

    func zoneFetched(modifications: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion]) {
        apply(modifications: modifications, deletions: deletions.map(\.recordID))
        if !(modifications.isEmpty && deletions.isEmpty) { markSynced() }
    }

    func zoneSent(saved: [CKRecord], deleted: [CKRecord.ID], failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave], isShared: Bool) -> [CKSyncEngine.PendingRecordZoneChange] {
        for record in saved {
            systemFields[record.recordID.recordName] = Self.encodeSystemFields(of: record)
            retries[record.recordID.recordName] = nil
            state.unsentSaves.remove(record.recordID.recordName)
        }
        for recordID in deleted {
            systemFields[recordID.recordName] = nil
            state.unsentDeletes.remove(recordID.recordName)
        }
        if !saved.isEmpty || !deleted.isEmpty { state.hasUploaded = true }
        mapsChanged = true
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var rejected: CKError?
        var rejectedType: String?
        for failure in failedSaves {
            let recordID = failure.record.recordID
            // Give up on a record after a few tries this session, so one bad record can't
            // keep sync busy forever.
            let tries = retries[recordID.recordName, default: 0] + 1
            retries[recordID.recordName] = tries
            if tries > 3 {
                rejected = failure.error
                rejectedType = failure.record.recordType
                log.error("Gave up sending \(recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                continue
            }
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord else {
                    retry.append(.saveRecord(recordID))
                    break
                }
                if state.unsentSaves.contains(recordID.recordName) {
                    // Changed here too: take their version's change tag and send ours again
                    // on top.
                    systemFields[recordID.recordName] = Self.encodeSystemFields(of: server)
                    retry.append(.saveRecord(recordID))
                } else {
                    // Not changed here since it last came down: theirs is newer.
                    apply(modifications: [server], deletions: [])
                }
            case .zoneNotFound:
                if isShared {
                    // Their zone is gone: the family isn't shared anymore.
                    lostFamilyZone()
                    saveState()
                    return []
                }
                household.ensurePrivateZone(recordID.zoneID)
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .unknownItem:
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .batchRequestFailed:
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited, .accountTemporarilyUnavailable:
                // The engine tries these again by itself.
                break
            default:
                rejected = failure.error
                rejectedType = failure.record.recordType
                log.error("Couldn't send \(recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        // Shown on the iCloud Sync card, rather than "Up to date" while iCloud refuses the
        // records (an undeployed schema on a TestFlight build, say).
        sendError = rejected.map { "iCloud didn't accept \(failedSaves.count) change\(failedSaves.count == 1 ? "" : "s"): \($0.localizedDescription)" }
        if sendError == nil, !(saved.isEmpty && deleted.isEmpty) {
            markSynced()
        }
        if sendError != nil {
            errorMessage = rejected.flatMap { syncErrorMessage(for: $0) }.map { message in
                rejectedType.map { "\(message) [\($0) records]" } ?? message
            }
            // Refused records aren't queued anymore (they stay in `unsent`); send them again
            // next time, once whatever iCloud objected to may be fixed.
            state.needsResend = true
        }
        saveState()
        return retry
    }

    func zoneDatabaseChanged(added: [CKRecordZone.ID], deleted: [CKDatabase.DatabaseChange.Deletion], isShared: Bool) {
        guard isShared else {
            // The family's own zone was deleted (iCloud data deleted in Settings, or the keys
            // reset): send everything up again.
            if location == .personal, deleted.contains(where: { $0.zoneID.zoneName == zoneName }) {
                resendOnce()
            }
            return
        }
        if case .member(let ownerName) = household.mode, added.contains(where: { $0.ownerName == ownerName }) {
            // Accepted on another device, or by `updateSharing`.
            markJoined(ownerName)
        }
        if case .shared(let ownerName) = location, deleted.contains(where: { $0.zoneID.ownerName == ownerName }) {
            lostFamilyZone()
        }
    }

    func zoneEngineReset(isShared: Bool) {
        refreshLocation()
        // The zone's records are as they were; the new engine just needs to know what this
        // device hasn't sent yet.
        guard let zone = zoneLocation, zone.isShared == isShared else { return }
        queueUnsent()
    }

    func zoneAccountDidChange() {
        state.joinedOwner = nil
        if location != .personal {
            // Someone else's family never stays on a device after its account leaves.
            if location.isShared {
                eraseLocalData()
                UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
            }
            location = .personal
            state.location = .personal
            state.hasFamilyData = false
        }
        // This account's own family stays on the device and goes up to the new account's
        // iCloud (`zoneEngineReset` queues it), as it always has.
        markAllUnsent()
        state.hasUploaded = false
        systemFields = [:]
        retries = [:]
        mapsChanged = true
        saveState()
    }

    /// Sends everything again, but never more than once every ten minutes, so nothing can keep
    /// sync starting over.
    private func resendOnce() {
        if let last = lastRestart, Date.now.timeIntervalSince(last) < 600 {
            log.error("Skipped resending everything; it did \(Int(Date.now.timeIntervalSince(last)))s ago")
            return
        }
        lastRestart = .now
        systemFields = [:]
        mapsChanged = true
        queueEverything()
    }

    // MARK: Applying iCloud's changes

    private func apply(modifications: [CKRecord], deletions: [CKRecord.ID]) {
        guard let zoneID = zoneLocation?.zoneID, let context = makeContext(), !(modifications.isEmpty && deletions.isEmpty) else { return }
        let identifiers = identifiersByID()
        var inserted: [any CloudRecord] = []
        var settingsChanged = false
        var calendarChanged = !deletions.isEmpty
        var newCompletions: [ChoreCompletion] = []
        var newRedemptions: [Redemption] = []
        var handled: [UUID] = []
        for record in modifications where record.recordID.zoneID == zoneID {
            guard let type = SyncSchema.type(named: record.recordType),
                  let id = UUID(uuidString: record.recordID.recordName) else { continue }
            if let existing = model(id, identifiers: identifiers, in: context) {
                existing.read(from: record)
                if let completion = existing as? ChoreCompletion, completion.status != .pending { handled.append(id) }
                if let redemption = existing as? Redemption, redemption.status != .pending { handled.append(id) }
            } else {
                let model = type.blank()
                model.id = id
                model.read(from: record)
                context.insert(model)
                inserted.append(model)
                if let completion = model as? ChoreCompletion { newCompletions.append(completion) }
                if let redemption = model as? Redemption { newRedemptions.append(redemption) }
            }
            if ObjectIdentifier(type) == ObjectIdentifier(FamilySetting.self) { settingsChanged = true }
            if ObjectIdentifier(type) == ObjectIdentifier(FamilyEvent.self) || ObjectIdentifier(type) == ObjectIdentifier(HomeTask.self) { calendarChanged = true }
            systemFields[record.recordID.recordName] = Self.encodeSystemFields(of: record)
        }
        for recordID in deletions where recordID.zoneID == zoneID {
            // A chore undone or a reward request taken back: its notification goes too.
            if let id = UUID(uuidString: recordID.recordName) { handled.append(id) }
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
        ApprovalAlerts.update(newCompletions: newCompletions, newRedemptions: newRedemptions, handled: handled, in: context)
        if !inserted.isEmpty, let main = modelContainer?.mainContext {
            // New people from the family: link them to the household.
            CalomaHousehold.sync(in: main)
        }
    }

    // MARK: Erase All Data

    /// Stops sending right away, before Erase All Data deletes everything locally.
    func pauseForErase() {
        scanTask?.cancel()
        isErasing = true
    }

    /// Erase All Data: this account's family zone is deleted from iCloud too. Someone in
    /// another family's Caloma only erases this device; the family's data comes back down.
    /// Call after the local data is deleted.
    func eraseEverywhere() async {
        if location == .personal, let container = household.cloudContainer {
            do {
                _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [CKRecordZone.ID(zoneName: zoneName)])
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            } catch {
                log.error("Couldn't erase iCloud data: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// After Erase All Data deleted everything locally: skip that history and start fresh.
    func didEraseLocally() async {
        idsByModel = [:]
        systemFields = [:]
        retries = [:]
        mapsChanged = true
        if let context = makeContext() {
            state.historyToken = latestHistoryToken(in: context)
        }
        state.didInitialUpload = true
        isErasing = false
        saveState()
        if location.isShared { await fetchWholeZone() }
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
        idsByModel = [:]
        // Those deletes were this device's own business, and nothing here is unsent any more.
        state.historyToken = latestHistoryToken(in: context)
        state.unsentSaves = []
        state.unsentDeletes = []
        state.needsResend = false
    }

    // MARK: Helpers

    /// Remembers every model's id by its SwiftData identifier, so a delete found in the history
    /// can be sent (the deleted model itself can't be read anymore).
    private func rememberAllIDs() {
        guard let context = makeContext() else { return }
        for type in SyncSchema.types {
            for model in allModels(of: type, in: context) {
                idsByModel[model.persistentModelID] = model.id
            }
        }
    }

    /// Each model's SwiftData identifier by its id.
    private func identifiersByID() -> [UUID: PersistentIdentifier] {
        if let identifierCache { return identifierCache }
        var result: [UUID: PersistentIdentifier] = [:]
        result.reserveCapacity(idsByModel.count)
        for (identifier, id) in idsByModel { result[id] = identifier }
        identifierCache = result
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
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneLocation?.zoneID ?? CKRecordZone.ID(zoneName: zoneName))
    }

    private func makeRecord(for model: any CloudRecord) -> CKRecord {
        let recordID = recordID(for: model.id)
        let record: CKRecord
        if let data = systemFields[recordID.recordName], let cached = Self.decodeSystemFields(data), cached.recordID.zoneID == recordID.zoneID {
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

    /// One context for a burst of records the engine asks for, dropped right after.
    private func senderContext() -> ModelContext? {
        if let sendContext { return sendContext }
        let context = makeContext()
        sendContext = context
        Task { @MainActor [weak self] in self?.sendContext = nil }
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

    /// Records really went up or came down.
    private func markSynced() {
        lastSynced = .now
        errorMessage = nil
    }

    private func fail(_ error: Error) {
        errorMessage = syncErrorMessage(for: error)
        log.error("Sync failed: \(Self.detail(error), privacy: .public)")
    }

    static func describe(_ error: CKError) -> String {
        switch error.code {
        case .networkUnavailable, .networkFailure: "No internet connection. Changes will sync when you're back online."
        case .notAuthenticated: "Sign in to iCloud in Settings to sync."
        case .quotaExceeded: "iCloud storage is full."
        default: error.localizedDescription
        }
    }

    // MARK: The iCloud Sync card

    static let removedFromFamilyMessage = "You’re no longer in this family’s shared iCloud."

    /// What Family › iCloud shows, from the sync's state right now.
    var syncSnapshot: HearthSyncSnapshot {
        let account: HearthSyncSnapshot.Account
        if !AppConfig.cloudSyncEnabled {
            account = .unavailable(nil)
        } else {
            switch household.account {
            case .checking: account = .checking
            case .available: account = .available
            case .noAccount:
                account = .unavailable("Sign in to iCloud in Settings to keep the family’s chores, calendar and rewards on every device.")
            case .unavailable:
                account = .unavailable("iCloud isn’t available on this device right now.")
            }
        }
        var message = errorMessage
        if message == nil, case .waiting = location {
            message = "Waiting for your household’s Caloma to be shared with you. It happens the next time the person who set up the household opens Caloma."
        }
        return HearthSyncSnapshot(
            account: account,
            isSyncing: household.isSyncing,
            lastSynced: lastSynced,
            pendingChanges: nil,
            errorMessage: message
        )
    }

    /// An error in words for the iCloud Sync card, or nil for ones that sort themselves out
    /// (offline, signed out: the card says those itself).
    private func syncErrorMessage(for error: Error) -> String? {
        guard let error = error as? CKError else {
            return "iCloud couldn’t sync: \(Self.detail(error))"
        }
        switch error.code {
        case .quotaExceeded:
            return "iCloud storage is full, so new changes can’t be saved there. Free up space in Settings › [your name] › iCloud."
        case .networkUnavailable, .networkFailure, .notAuthenticated:
            return nil
        default:
            return "iCloud couldn’t sync: \(Self.detail(error))"
        }
    }

    /// iCloud's own reason, with its error code, so a refusal can be tracked down. A partial
    /// failure names the first record error inside it.
    static func detail(_ error: Error) -> String {
        guard let error = error as? CKError else {
            let ns = error as NSError
            return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        }
        if error.code == .partialFailure, let inner = error.partialErrorsByItemID?.values.first {
            return detail(inner)
        }
        return "\(error.localizedDescription) (CKError \(error.code.rawValue))"
    }

    /// Saves what sync remembers a moment later, off the main thread, so a burst of events
    /// writes once. The big map (change tags) is written only when it changed.
    private func saveState() {
        state.location = location
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            let core = self.state
            let maps = self.mapsChanged ? SyncMaps(systemFields: self.systemFields) : nil
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

/// What sync remembers between launches, in Application Support/Sync. Only ever about the zone
/// in `location`: moving to another family's zone erases what's on the device and starts over.
nonisolated struct SyncState: Codable, @unchecked Sendable {
    var location: CloudSync.Location = .personal
    /// The household owner whose family zone this account is in, once it was shared with it.
    var joinedOwner: String?
    var historyToken: DefaultHistoryToken?
    var didInitialUpload = false
    /// Which full resend this device has done (see `CloudSync.uploadGeneration`).
    var uploadGeneration: Int?
    /// The record types this device knew when it last started; a new one means fetching
    /// everything again (see `CloudSync.householdStarted`).
    var knownTypes: [String]?
    /// In a family's zone: the first full fetch of it finished, so people can be added here.
    var hasFamilyData = false
    /// This device had joined another family in Caloma's own container: its data is that
    /// family's and never goes into this account's own zone.
    var legacyParticipant = false
    /// Records this device has had accepted by iCloud since the move to the Hearth container.
    var hasUploaded = false
    /// This device's changes iCloud doesn't have yet, by record name (a model's UUID).
    var unsentSaves: Set<String> = []
    var unsentDeletes: Set<String> = []
    /// iCloud refused some: send the unsent ones again on the next sync.
    var needsResend = false

    init() {}

    /// Missing keys (a file from an earlier build) take their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = try container.decodeIfPresent(CloudSync.Location.self, forKey: .location) ?? .personal
        joinedOwner = try container.decodeIfPresent(String.self, forKey: .joinedOwner)
        historyToken = try container.decodeIfPresent(DefaultHistoryToken.self, forKey: .historyToken)
        didInitialUpload = try container.decodeIfPresent(Bool.self, forKey: .didInitialUpload) ?? false
        uploadGeneration = try container.decodeIfPresent(Int.self, forKey: .uploadGeneration)
        knownTypes = try container.decodeIfPresent([String].self, forKey: .knownTypes)
        hasFamilyData = try container.decodeIfPresent(Bool.self, forKey: .hasFamilyData) ?? false
        legacyParticipant = try container.decodeIfPresent(Bool.self, forKey: .legacyParticipant) ?? false
        hasUploaded = try container.decodeIfPresent(Bool.self, forKey: .hasUploaded) ?? false
        unsentSaves = try container.decodeIfPresent(Set<String>.self, forKey: .unsentSaves) ?? []
        unsentDeletes = try container.decodeIfPresent(Set<String>.self, forKey: .unsentDeletes) ?? []
        needsResend = try container.decodeIfPresent(Bool.self, forKey: .needsResend) ?? false
    }

    private static var folder: URL {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var url: URL { folder.appendingPathComponent("hearth-state.json") }

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

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

    // MARK: Before the Hearth container

    /// Builds before the move kept their own engine's state here, for Caloma's own container.
    private struct Legacy: Decodable {
        var role: String?
    }

    /// Whether this device had joined someone else's family in Caloma's own container.
    static func legacyRoleWasParticipant() -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return false }
        return legacy.role == "participant"
    }

    /// The old container's engine state and change tags mean nothing in the Hearth container.
    static func removeLegacyFiles() {
        for name in ["state.json", "maps.plist"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

/// The big part of what sync remembers: every record's change tag. Kept in its own file so the
/// small state can be saved often without rewriting it.
nonisolated struct SyncMaps: Codable, @unchecked Sendable {
    var systemFields: [String: Data] = [:]

    private static var url: URL {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("hearth-maps.plist")
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
