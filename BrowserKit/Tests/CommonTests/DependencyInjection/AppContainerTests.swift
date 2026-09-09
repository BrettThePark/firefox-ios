// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Common

final class AppContainerTests: XCTestCase {
    func testRebuild_replacesRegistrations() {
        let subject = AppContainer()
        subject.rebuild { $0.register(service: "first") }
        subject.rebuild { $0.register(service: "second") }

        XCTAssertEqual(subject.resolve(String.self), "second")
    }

    func testRebuild_whileResolvingConcurrently_alwaysResolves() {
        nonisolated(unsafe) let subject = AppContainer()
        subject.rebuild { $0.register(service: 0) }

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                subject.rebuild { $0.register(service: index) }
            } else {
                _ = subject.resolve(Int.self)
            }
        }
    }
}
