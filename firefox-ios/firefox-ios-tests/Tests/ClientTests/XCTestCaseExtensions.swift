// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

@testable import Client

import Foundation
import Glean
import XCTest

extension XCTestCase {
    func wait(_ timeout: TimeInterval) {
        let expectation = XCTestExpectation(description: "Waiting for \(timeout) seconds")
        XCTWaiter().wait(for: [expectation], timeout: timeout)
    }

    /// Helper function to cast a value to `AnyHashable`.
    func asAnyHashable<T>(_ value: T) -> AnyHashable? {
        return value as? AnyHashable
    }

    /// Helper function to ensure Glean telemetry is setup for unit tests
    /// This should not be called in new code:
    /// - We should us GleanWrapper or mock objects instead of concrete type testing for Glean
    @MainActor
    static func setupTelemetry(with profile: Profile) {
        TelemetryWrapper.hasTelemetryOverride = true

        DependencyHelperMock().bootstrapDependencies()
        TelemetryWrapper().initGlean(profile, sendUsageData: false)

        // Due to changes allow certain custom pings to implement their own opt-out
        // independent of Glean, custom pings may need to be registered manually in
        // tests in order to put them in a state in which they can collect data.
        Glean.shared.registerPings(GleanMetrics.Pings.shared)
        Glean.shared.resetGlean(clearStores: true)
    }

    /// Helper function to ensure Glean telemetry is properly teardown for unit tests
    static func tearDownTelemetry() {
        TelemetryWrapper.hasTelemetryOverride = false
        DependencyHelperMock().reset()
    }
}

/// Instantiated once per test process by XCTest (NSPrincipalClass in Info.plist)
/// before any tests run. Bootstraps the dependency container so no test depends
/// on an earlier test having populated it — required for tests to run first in a
/// fresh process, e.g. on parallel-testing simulator clones (FXIOS: Experiments
/// resolved an empty AppContainer and crashed the host).
@objc(ClientTestsPrincipal)
final class ClientTestsPrincipal: NSObject {
    override init() {
        super.init()
        let bootstrap: @MainActor () -> Void = {
            DependencyHelperMock().bootstrapDependencies()
            // Initialize the process-lifetime Nimbus singleton now, while exactly one
            // profile exists and no test is mid-rebuild. Lazily initializing it later
            // races per-test container rebuilds and can segfault in the Rust FFI
            // (RemoteSettingsService handle from a torn-down profile).
            _ = Experiments.shared
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { bootstrap() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { bootstrap() } }
        }
    }
}
