// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
@testable import Storage

class MockFiles: FileAccessor, @unchecked Sendable {
    private let cleanupRootPath: String?

    /// Keeps concurrently running test bundles and processes from sharing artifacts.
    static let testingRoot: String = {
        let bundleName = Bundle(for: MockFiles.self).bundleURL.deletingPathExtension().lastPathComponent
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("fxios-tests", isDirectory: true)
            .appendingPathComponent("\(bundleName)-\(UUID().uuidString)", isDirectory: true)
            .path
    }()

    var rootPath: String

    init(rootPath: String? = nil, removeRootOnDeinit: Bool = false) {
        let rootPath = rootPath ?? URL(fileURLWithPath: MockFiles.testingRoot, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .path
        self.rootPath = rootPath
        cleanupRootPath = removeRootOnDeinit ? rootPath : nil
    }

    deinit {
        guard let cleanupRootPath else { return }
        try? FileManager.default.removeItem(atPath: cleanupRootPath)
    }

    func removeRoot() {
        try? FileManager.default.removeItem(atPath: cleanupRootPath ?? rootPath)
    }
}

protocol LifecycleStore: AnyObject {
    associatedtype LifecycleResult

    func reopenIfClosed() -> LifecycleResult
    func forceClose() -> LifecycleResult
}

final class StoreLifecycle: @unchecked Sendable {
    private enum State {
        case open
        case closed
    }

    private let lock = NSLock()
    private var state = State.open
    private var stores: [any LifecycleStore] = []

    var isShutdown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .closed
    }

    @discardableResult
    func track<Store: LifecycleStore>(_ store: Store) -> Store {
        lock.lock()
        defer { lock.unlock() }
        stores.append(store)
        update(store, for: state)
        return store
    }

    func reopen() {
        update(to: .open)
    }

    func shutdown() {
        update(to: .closed)
    }

    private func update(to state: State) {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
        stores.forEach { update($0, for: state) }
    }

    private func update(_ store: any LifecycleStore, for state: State) {
        switch state {
        case .open:
            _ = store.reopenIfClosed()
        case .closed:
            _ = store.forceClose()
        }
    }
}

class SupportingFiles: FileAccessor {
    var rootPath: String

    init() {
        rootPath = Bundle.main.bundlePath + "/PlugIns/StorageTests.xctest/"
    }
}
