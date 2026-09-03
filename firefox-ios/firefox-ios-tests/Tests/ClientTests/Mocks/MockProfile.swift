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
    public let mockNotificationCenter: NotificationProtocol

    fileprivate let name = "mockaccount"

    private let directory: String
    private let databasePrefix: String
    private let injectedPinnedSites: MockablePinnedSites?
    private var shouldReopenLazyStores = false

    init(
        databasePrefix: String = "mock",
        firefoxSuggest: RustFirefoxSuggestProtocol? = nil,
        remoteSettingsService: RemoteSettingsService = RemoteSettingsService(unsafeFromHandle: 0),
        injectedPinnedSites: MockablePinnedSites? = nil
    ) {
        let profileFiles = MockProfileFiles(rootPath: (MockFiles.testingRoot as NSString)
            .appendingPathComponent("\(databasePrefix)-\(UUID().uuidString)"))
        // Each profile owns a private subdirectory so its databases cannot be seen or
        // reused by another instance, and so teardown can remove them in one call.
        files = profileFiles
        syncManager = ClientSyncManagerSpy()
        self.databasePrefix = databasePrefix
        self.firefoxSuggest = firefoxSuggest
        self.remoteSettingsService = remoteSettingsService
        self.injectedPinnedSites = injectedPinnedSites
        mockNotificationCenter = MockNotificationCenter(retaining: profileFiles)

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

    /// `reopen` and `shutdown` deliberately go through the `_`-prefixed backing storage
    /// rather than the lazy properties. Referencing a lazy property is what constructs it,
    /// and `logins` and `places` open (and therefore create) their database file as part of
    /// construction — so touching them here would make every profile write the databases
    /// these methods are only meant to close.
    public func reopen() {
        isShutdown = false
        shouldReopenLazyStores = true

        _database?.reopenIfClosed()
        _readingListDB?.reopenIfClosed()
        _ = _logins?.reopenIfClosed()
        _ = _places?.reopenIfClosed()
        _ = _tabs?.reopenIfClosed()
        _ = _autofill?.reopenIfClosed()
    }

    public func shutdown() {
        isShutdown = true
        shouldReopenLazyStores = false

        _database?.forceClose()
        _readingListDB?.forceClose()
        _ = _logins?.forceClose()
        _ = _places?.forceClose()
        _ = _tabs?.forceClose()
        _ = _autofill?.forceClose()
    }

    public var isShutdown = false

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

    private var _autofill: RustAutofill?
    public lazy var autofill: RustAutofill = {
        let autofillDbPath = URL(
            fileURLWithPath: directory,
            isDirectory: true
        ).appendingPathComponent("autofill.db").path
        let autofill = RustAutofill(databasePath: autofillDbPath)
        _autofill = autofill
        if shouldReopenLazyStores {
            _ = autofill.reopenIfClosed()
        }
        return autofill
    }()

    public lazy var readingList: ReadingList = {
        return SQLiteReadingList(db: self.readingListDB)
    }()

    public lazy var recentlyClosedTabs: ClosedTabsStore = {
        return ClosedTabsStore(prefs: self.prefs)
    }()

    private var _logins: RustLogins?
    public lazy var logins: RustLogins = {
        let newLoginsDatabasePath = URL(
            fileURLWithPath: directory,
            isDirectory: true
        ).appendingPathComponent("\(databasePrefix)_loginsPerField.db").path

        let logins = RustLogins(databasePath: newLoginsDatabasePath)
        _logins = logins
        if !isShutdown {
            _ = logins.reopenIfClosed()
        }

        return logins
    }()

    private var _database: BrowserDB?
    lazy var database: BrowserDB = {
        let database = BrowserDB(filename: "\(databasePrefix).db", schema: BrowserSchema(), files: files)
        _database = database
        if isShutdown {
            database.forceClose()
        }
        return database
    }()

    private var _readingListDB: BrowserDB?
    lazy var readingListDB: BrowserDB = {
        let database = BrowserDB(
            filename: "\(databasePrefix)_ReadingList.db",
            schema: ReadingListSchema(),
            files: files
        )
        _readingListDB = database
        if isShutdown {
            database.forceClose()
        }
        return database
    }()

    private var _places: RustPlaces?
    public lazy var places: RustPlaces = {
        let placesDatabasePath = URL(
            fileURLWithPath: directory,
            isDirectory: true
        ).appendingPathComponent("\(databasePrefix)_places.db").path

        let places = RustPlaces(databasePath: placesDatabasePath, notificationCenter: mockNotificationCenter)
        _places = places
        if !isShutdown {
            _ = places.reopenIfClosed()
        }

        return places
    }()

    private var _tabs: RustRemoteTabs?
    public lazy var tabs: RustRemoteTabs = {
        let tabsDbPath = URL(
            fileURLWithPath: directory,
            isDirectory: true
        ).appendingPathComponent("\(databasePrefix)_tabs.db").path
        let tabs = RustRemoteTabs(databasePath: tabsDbPath)
        _tabs = tabs
        if shouldReopenLazyStores {
            _ = tabs.reopenIfClosed()
        }

        return tabs
    }()

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
