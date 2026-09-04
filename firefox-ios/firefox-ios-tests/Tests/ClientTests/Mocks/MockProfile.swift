// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Account
import Foundation
import Shared
import Storage
import XCTest
import Common

@testable import Client

import enum MozillaAppServices.SyncReason
import struct MozillaAppServices.SyncResult
import class MozillaAppServices.RemoteSettingsService

public typealias ClientSyncManager = Client.SyncManager

open class ClientSyncManagerSpy: ClientSyncManager, @unchecked Sendable {
    open var isSyncing = false
    open var lastSyncFinishTime: Timestamp?
    open var syncDisplayState: SyncDisplayState?

    private var mockDeclinedEngines: [String]?
    private var mockEngineEnabled = false
    private var emptySyncResult = deferMaybe(SyncResult(status: .ok,
                                                        successful: [],
                                                        failures: [:],
                                                        persistedState: "",
                                                        declined: nil,
                                                        nextSyncAllowedAt: nil,
                                                        telemetryJson: nil))

    open func syncTabs() -> Deferred<Maybe<SyncResult>> { return emptySyncResult }
    open func syncHistory() -> Deferred<Maybe<SyncResult>> { return emptySyncResult }
    open func syncEverything(why: SyncReason) -> Success { return succeed() }

    var syncNamedCollectionsCalled = 0
    open func syncNamedCollections(why: SyncReason, names: [String]) -> Deferred<Maybe<SyncResult>> {
        syncNamedCollectionsCalled += 1
        return emptySyncResult
    }
    var syncPostSyncSettingsChangeCalled = 0
    open func syncPostSyncSettingsChange(why: SyncReason, names: [String]) {
        syncPostSyncSettingsChangeCalled += 1
    }
    open func reportOpenSyncSettingsMenuTelemetry() {}
    open func beginTimedSyncs() {}
    open func endTimedSyncs() {}
    open func applicationDidBecomeActive() {
        self.beginTimedSyncs()
    }
    open func applicationDidEnterBackground() {
        self.endTimedSyncs()
    }

    open func onAddedAccount() -> Success {
        return succeed()
    }
    open func onRemovedAccount() -> Success {
        return succeed()
    }
    open func checkCreditCardEngineEnablement() -> Bool {
        guard let mockDeclinedEngines = mockDeclinedEngines,
              !mockDeclinedEngines.isEmpty,
              mockDeclinedEngines.contains("creditcards") else {
            return mockEngineEnabled
        }
        return false
    }

    func setMockDeclinedEngines(_ engines: [String]?) {
        mockDeclinedEngines = engines
    }

    func setMockEngineEnabled(_ enabled: Bool) {
        mockEngineEnabled = enabled
    }
}

final class MockTabQueue: TabQueue, @unchecked Sendable {
    var queuedTabs = [ShareItem]()
    var getQueuedTabsCalled = 0
    var addToQueueCalled = 0
    var clearQueuedTabsCalled = 0

    func addToQueue(_ tab: ShareItem) -> Success {
        addToQueueCalled += 1
        return succeed()
    }

    func getQueuedTabs(completion: @MainActor @escaping ([ShareItem]) -> Void) {
        Task { @MainActor in
            completion(queuedTabs)
            getQueuedTabsCalled += 1
        }
    }

    func clearQueuedTabs() -> Success {
        clearQueuedTabsCalled += 1
        return succeed()
    }
}

class MockFiles: FileAccessor {
    /// Root for this bundle's test file artifacts.
    static let testingRoot: String = {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("fxios-tests")
        return (base as NSString).appendingPathComponent("ClientTests-\(UUID().uuidString)")
    }()

    var rootPath: String

    init(rootPath: String? = nil) {
        self.rootPath = rootPath ?? MockFiles.testingRoot
    }
}

private final class MockProfileFiles: MockFiles {
    private let cleanupPath: String

    init(rootPath: String) {
        cleanupPath = rootPath
        super.init(rootPath: rootPath)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: cleanupPath)
    }
}

/// The open/close surface the profile's stores share, so `shutdown` and `reopen`
/// act on whatever a test actually created.
protocol LifecycleStore: AnyObject {
    func reopenIfClosed() -> NSError?
    func forceClose() -> NSError?
}

extension RustPlaces: LifecycleStore {}
extension RustLogins: LifecycleStore {}
extension RustRemoteTabs: LifecycleStore {}
extension RustAutofill: LifecycleStore {}

private final class BrowserDBLifecycle: LifecycleStore {
    private let database: BrowserDB

    init(_ database: BrowserDB) {
        self.database = database
    }

    func reopenIfClosed() -> NSError? {
        database.reopenIfClosed()
        return nil
    }

    func forceClose() -> NSError? {
        database.forceClose()
        return nil
    }
}

/// Runs `body` with a fresh profile, then shuts it down and removes its directory, so
/// cleanup does not depend on when ARC releases the profile.
func withMockProfile<T>(
    databasePrefix: String = "mock",
    _ body: (MockProfile) async throws -> T
) async throws -> T {
    let profile = MockProfile(databasePrefix: databasePrefix)
    defer {
        profile.shutdown()
        try? FileManager.default.removeItem(atPath: profile.files.rootPath)
    }
    return try await body(profile)
}

extension XCTestCase {
    /// The XCTest form of `withMockProfile`: shutdown and directory removal run in teardown.
    func makeProfile(databasePrefix: String = "mock") -> MockProfile {
        let profile = MockProfile(databasePrefix: databasePrefix)
        addTeardownBlock {
            profile.shutdown()
            try? FileManager.default.removeItem(atPath: profile.files.rootPath)
        }
        return profile
    }
}

// TODO: FXIOS-12610 Profile should be refactored so it is **not** `Sendable`.
final class MockProfile: Client.Profile, @unchecked Sendable {
    public var rustFxA: RustFirefoxAccounts {
        return RustFirefoxAccounts.shared
    }

    // Read/Writeable properties for mocking

    public let files: FileAccessor
    public let syncManager: ClientSyncManager?
    public let firefoxSuggest: RustFirefoxSuggestProtocol?
    public let remoteSettingsService: RemoteSettingsService
    public let mockNotificationCenter: NotificationProtocol = MockNotificationCenter()

    fileprivate let name = "mockaccount"

    private let directory: String
    private let databasePrefix: String
    private let injectedPinnedSites: MockablePinnedSites?
    private let storesLock = NSLock()
    private var stores: [any LifecycleStore] = []

    init(
        databasePrefix: String = "mock",
        firefoxSuggest: RustFirefoxSuggestProtocol? = nil,
        remoteSettingsService: RemoteSettingsService = RemoteSettingsService(unsafeFromHandle: 0),
        injectedPinnedSites: MockablePinnedSites? = nil
    ) {
        // Each profile owns a private subdirectory so its databases cannot be seen or
        // reused by another instance, and so teardown can remove them in one call.
        files = MockProfileFiles(rootPath: (MockFiles.testingRoot as NSString)
            .appendingPathComponent("\(databasePrefix)-\(UUID().uuidString)"))
        syncManager = ClientSyncManagerSpy()
        self.databasePrefix = databasePrefix
        self.firefoxSuggest = firefoxSuggest
        self.remoteSettingsService = remoteSettingsService
        self.injectedPinnedSites = injectedPinnedSites

        do {
            directory = try files.getAndEnsureDirectory()
        } catch {
            XCTFail("Could not create directory at root path: \(error)")
            fatalError("Could not create directory at root path: \(error)")
        }
    }

    deinit {
        shutdown()
    }

    public func localName() -> String {
        return name
    }

    public func reopen() {
        isShutdown = false
        trackedStores.forEach { _ = $0.reopenIfClosed() }
    }

    public func shutdown() {
        isShutdown = true
        trackedStores.forEach { _ = $0.forceClose() }
    }

    public var isShutdown = false

    private var trackedStores: [any LifecycleStore] {
        storesLock.lock()
        defer { storesLock.unlock() }
        return stores
    }

    /// Registers a store as its lazy property creates it and aligns it with the current
    /// lifecycle state, so a store first touched after `shutdown()` stays closed and never
    /// writes its database. `reopen` and `shutdown` only ever see stores a test created.
    private func track<Store: LifecycleStore>(_ store: Store) -> Store {
        storesLock.lock()
        stores.append(store)
        storesLock.unlock()
        _ = isShutdown ? store.forceClose() : store.reopenIfClosed()
        return store
    }

    private func trackDatabase(_ database: BrowserDB) -> BrowserDB {
        _ = track(BrowserDBLifecycle(database))
        return database
    }

    private func databasePath(_ filename: String) -> String {
        URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(filename).path
    }

    public lazy var queue: TabQueue = {
        return MockTabQueue()
    }()

    public lazy var isChinaEdition: Bool = {
        return Locale.current.identifier == "zh_CN"
    }()

    public lazy var certStore: CertStore = {
        return CertStore()
    }()

    public lazy var prefs: Prefs = {
        return MockProfilePrefs()
    }()

    public lazy var autofill: RustAutofill = track(RustAutofill(databasePath: databasePath("autofill.db")))

    public lazy var readingList: ReadingList = {
        return SQLiteReadingList(db: self.readingListDB)
    }()

    public lazy var recentlyClosedTabs: ClosedTabsStore = {
        return ClosedTabsStore(prefs: self.prefs)
    }()

    public lazy var logins: RustLogins = track(
        RustLogins(databasePath: databasePath("\(databasePrefix)_loginsPerField.db"))
    )

    lazy var database: BrowserDB = trackDatabase(
        BrowserDB(filename: "\(databasePrefix).db", schema: BrowserSchema(), files: files)
    )

    lazy var readingListDB: BrowserDB = trackDatabase(
        BrowserDB(filename: "\(databasePrefix)_ReadingList.db", schema: ReadingListSchema(), files: files)
    )

    public lazy var places: RustPlaces = track(
        RustPlaces(databasePath: databasePath("\(databasePrefix)_places.db"),
                   notificationCenter: mockNotificationCenter)
    )

    public lazy var tabs: RustRemoteTabs = track(
        RustRemoteTabs(databasePath: databasePath("\(databasePrefix)_tabs.db"))
    )

    fileprivate lazy var legacyPlaces: PinnedSites = {
        BrowserDBSQLite(database: self.database, prefs: MockProfilePrefs())
    }()

    public lazy var pinnedSites: PinnedSites = {
        injectedPinnedSites ?? legacyPlaces
    }()

    public func hasSyncAccount(completion: @escaping (Bool) -> Void) {
        completion(hasSyncableAccountMock)
    }

    public func hasAccount() -> Bool {
        return hasSyncableAccountMock
    }

    var hasSyncableAccountMock = true
    public func hasSyncableAccount() -> Bool {
        return hasSyncableAccountMock
    }

    public func flushAccount() {}

    public func removeAccount() {
        self.syncManager?.onRemovedAccount()
    }

    public func getCachedClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>> {
        return deferMaybe(mockClientAndTabs)
    }

    public func getClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>> {
        return deferMaybe([])
    }

    var mockClientAndTabs = [ClientAndTabs]()

    public func getCachedClientsAndTabs(completion: @escaping ([ClientAndTabs]?) -> Void) {
        completion(mockClientAndTabs)
    }

    public func getClientsAndTabs(completion: @escaping ([ClientAndTabs]?) -> Void) {
        completion(mockClientAndTabs)
    }

    public func cleanupHistoryIfNeeded() {}

    var storeAndSyncTabsCalled = 0
    public func storeAndSyncTabs(_ tabs: [RemoteTab]) -> Deferred<Maybe<Int>> {
        storeAndSyncTabsCalled += 1
        return deferMaybe(0)
    }

    public func addTabToCommandQueue(_ deviceId: String, url: URL) {
        return
    }

    public func flushTabCommands(toDeviceId: String?) {
        return
    }

    public func sendItem(_ item: ShareItem, toDevices devices: [RemoteDevice]) -> Success {
        return succeed()
    }

    public func setCommandArrived() {
        return
    }

    public func pollCommands(forcePoll: Bool) {
        return
    }

    public func hasSyncedLogins() -> Deferred<Maybe<Bool>> {
        return deferMaybe(true)
    }
}
