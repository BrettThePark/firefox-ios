// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import Storage

/// A `FileAccessor` rooted in a temporary directory that it can own and remove.
class TemporaryFiles: FileAccessor, @unchecked Sendable {
    private let cleanupRootPath: String?

    /// One root per bundle load, so test bundles that share a host process never share artifacts.
    static let bundleRoot: String = {
        let bundleName = Bundle(for: TemporaryFiles.self).bundleURL.deletingPathExtension().lastPathComponent
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("fxios-tests", isDirectory: true)
            .appendingPathComponent("\(bundleName)-\(UUID().uuidString)", isDirectory: true)
            .path
    }()

    var rootPath: String

    /// Only an owned root is ever removed, so a caller-supplied path such as Documents stays safe.
    init(rootPath: String? = nil, ownsRoot: Bool = false) {
        let rootPath = rootPath ?? URL(fileURLWithPath: TemporaryFiles.bundleRoot, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .path
        self.rootPath = rootPath
        cleanupRootPath = ownsRoot ? rootPath : nil
    }

    deinit {
        removeRoot()
    }

    func removeRoot() {
        guard let cleanupRootPath else { return }
        try? FileManager.default.removeItem(atPath: cleanupRootPath)
    }

    /// The path for `filename` inside the root, creating the root if it does not exist yet.
    func pathEnsuringRoot(for filename: String) -> String {
        do {
            return URL(fileURLWithPath: try getAndEnsureDirectory(), isDirectory: true)
                .appendingPathComponent(filename)
                .path
        } catch {
            XCTFail("Could not create directory at root path: \(error)")
            fatalError("Could not create directory at root path: \(error)")
        }
    }
}

extension XCTestCase {
    /// A `TemporaryFiles` with its own root, removed when the current test finishes.
    func makeTemporaryFiles() -> TemporaryFiles {
        let files = TemporaryFiles(ownsRoot: true)
        addTeardownBlock { files.removeRoot() }
        return files
    }
}
