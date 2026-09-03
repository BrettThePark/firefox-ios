// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Storage
import Testing

@testable import Client

@Suite("MockProfile")
struct MockProfileTests {
    @Test("Reading List follows the profile lifecycle")
    func readingListLifecycle() async {
        await assertLifecycle {
            $0.readingList.getAvailableRecords().value.isSuccess
        }
    }

    @Test("Places follows the profile lifecycle")
    func placesLifecycle() async {
        await assertLifecycle {
            $0.places.getRecentBookmarks(limit: 1).value.isSuccess
        }
    }

    @Test("Tabs follows the profile lifecycle")
    func tabsLifecycle() async {
        await assertLifecycle {
            $0.tabs.getAll().value.isSuccess
        }
    }

    @Test("Logins follows the profile lifecycle")
    func loginsLifecycle() async {
        await assertLifecycle {
            $0.logins.hasSyncedLogins().value.isSuccess
        }
    }

    @Test("Autofill follows the profile lifecycle")
    func autofillLifecycle() async {
        await assertLifecycle(isUsable: Self.autofillIsUsable)
    }

    @Test("Legacy BrowserDB follows the profile lifecycle")
    func legacyBrowserDBLifecycle() async {
        await assertLifecycle {
            $0.pinnedSites.getPinnedTopSites().value.isSuccess
        }
    }

    @Test("Using Places creates its expected database")
    func usingPlacesCreatesDatabase() {
        let profile = MockProfile()
        let root = profile.files.rootPath

        _ = profile.places
        profile.shutdown()

        #expect(databaseArtifacts(under: root).contains("mock_places.db"))
    }

    @Test("Releasing a profile removes its directory")
    func releasingProfileRemovesDirectory() async {
        let root = autoreleasepool {
            let profile = MockProfile()
            _ = profile.places
            return profile.files.rootPath
        }

        #expect(await isEventuallyRemoved(root))
    }

    @Test("Reading List retains the profile directory")
    func readingListRetainsDirectory() async {
        await assertStoreRetainsDirectory { $0.readingList }
    }

    @Test("Places retains the profile directory")
    func placesRetainsDirectory() async {
        await assertStoreRetainsDirectory { $0.places }
    }

    private func assertLifecycle(isUsable: @Sendable (MockProfile) async -> Bool) async {
        let accessedAfterShutdown = MockProfile()
        let untouchedRoot = accessedAfterShutdown.files.rootPath

        accessedAfterShutdown.shutdown()

        let openedWhileShutdown = await isUsable(accessedAfterShutdown)
        #expect(!openedWhileShutdown)
        #expect(databaseArtifacts(under: untouchedRoot).isEmpty)

        let initializedProfile = MockProfile()

        initializedProfile.reopen()

        let openedAfterReopen = await isUsable(initializedProfile)
        #expect(openedAfterReopen)

        initializedProfile.shutdown()

        let usableAfterShutdown = await isUsable(initializedProfile)
        #expect(!usableAfterShutdown)

        initializedProfile.reopen()

        let usableAfterSecondReopen = await isUsable(initializedProfile)
        #expect(usableAfterSecondReopen)
    }

    private static func autofillIsUsable(_ profile: MockProfile) async -> Bool {
        return await withCheckedContinuation { continuation in
            profile.autofill.listAllAddresses { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func assertStoreRetainsDirectory<Store>(
        _ makeStore: (MockProfile) -> Store
    ) async {
        var retainedStore: Store?
        let root = autoreleasepool {
            let profile = MockProfile()
            retainedStore = makeStore(profile)
            return profile.files.rootPath
        }

        withExtendedLifetime(retainedStore) {
            #expect(FileManager.default.fileExists(atPath: root))
        }

        retainedStore = nil

        #expect(await isEventuallyRemoved(root))
    }

    private func isEventuallyRemoved(_ path: String) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while FileManager.default.fileExists(atPath: path), Date() < deadline {
            try? await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    private func databaseArtifacts(under root: String) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return contents.filter {
            $0.hasSuffix(".db") || $0.hasSuffix(".db-wal") || $0.hasSuffix(".db-shm")
        }.sorted()
    }
}
