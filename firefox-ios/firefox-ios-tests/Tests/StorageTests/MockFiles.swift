// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
@testable import Storage
import XCTest

class MockFiles: FileAccessor, @unchecked Sendable {
    /// Root for this bundle's test file artifacts. It lives in the container's temporary
    /// directory rather than `Documents`, which persists across simulator runs, and is
    /// cleared once per process so nothing survives into the next run. The path is scoped
    /// per test bundle because bundles may share a host process, and a shared root would
    /// let one bundle's clear delete files another is still using.
    static let testingRoot: String = {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("fxios-tests/StorageTests")
        try? FileManager.default.removeItem(atPath: root)
        return root
    }()

    var rootPath: String

    init(rootPath: String? = nil) {
        self.rootPath = rootPath ?? MockFiles.testingRoot
    }
}

class SupportingFiles: FileAccessor {
    var rootPath: String

    init() {
        rootPath = Bundle.main.bundlePath + "/PlugIns/StorageTests.xctest/"
    }
}
