// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Storage
import TestKit
@testable import Client

final class DependencyHelperMock {
    @MainActor
    func bootstrapDependencies(
        injectedProfile: Profile? = nil,
        injectedWindowManager: WindowManager? = nil,
        injectedTabManager: TabManager? = nil,
        injectedThemeManager: ThemeManager? = nil,
        injectedMicrosurveyManager: MicrosurveyManager? = nil,
        injectedMerinoManager: MerinoManagerProvider? = nil,
        injectedFeatureFlagProvider: FeatureFlagProviding? = nil,
        injectedUserFeaturePreferences: UserFeaturePreferring? = nil
    ) {
        // Registrations go into a staging container that is swapped in atomically
        // (see ServiceProvider.rebuild). Never reset the live shared container here:
        // async work from a previous test may still resolve from it mid-bootstrap.
        AppContainer.shared.rebuild { container in
            let profile: Profile = injectedProfile ?? BrowserProfile(
                localName: "profile"
            )
            registerCoreServices(
                in: container,
                profile: profile,
                injectedWindowManager: injectedWindowManager,
                injectedTabManager: injectedTabManager,
                injectedThemeManager: injectedThemeManager
            )
            registerManagerServices(
                in: container,
                profile: profile,
                injectedMicrosurveyManager: injectedMicrosurveyManager,
                injectedMerinoManager: injectedMerinoManager,
                injectedFeatureFlagProvider: injectedFeatureFlagProvider,
                injectedUserFeaturePreferences: injectedUserFeaturePreferences
            )
        }
    }

    @MainActor
    private func registerCoreServices(
        in container: ServiceProvider,
        profile: Profile,
        injectedWindowManager: WindowManager?,
        injectedTabManager: TabManager?,
        injectedThemeManager: ThemeManager?
    ) {
        container.register(service: profile as Profile)

        let diskImageStore: DiskImageStore = DefaultDiskImageStore(
            files: profile.files,
            namespace: TabManagerConstants.tabScreenshotNamespace,
            quality: UIConstants.ScreenshotQuality)
        container.register(service: diskImageStore as DiskImageStore)

        let windowUUID = WindowUUID.XCTestDefaultUUID
        let windowManager: WindowManager = injectedWindowManager ?? MockWindowManager(
            wrappedManager: WindowManagerImplementation()
        )

        var tabManager: TabManager!

        let appSessionProvider: AppSessionProvider = AppSessionManager()
        container.register(service: appSessionProvider as AppSessionProvider)

        tabManager = injectedTabManager ?? MockTabManager()
        container.register(service: (injectedThemeManager ?? MockThemeManager()) as ThemeManager)

        let searchEnginesManager = SearchEnginesManager(
            prefs: profile.prefs,
            files: profile.files,
            engineProvider: MockSearchEngineProvider()
        )
        container.register(service: searchEnginesManager)

        let downloadQueue = DownloadQueue()
        container.register(service: downloadQueue)

        container.register(service: windowManager as WindowManager)
        windowManager.newBrowserWindowConfigured(AppWindowInfo(tabManager: tabManager), uuid: windowUUID)
    }

    @MainActor
    private func registerManagerServices(
        in container: ServiceProvider,
        profile: Profile,
        injectedMicrosurveyManager: MicrosurveyManager?,
        injectedMerinoManager: MerinoManagerProvider?,
        injectedFeatureFlagProvider: FeatureFlagProviding?,
        injectedUserFeaturePreferences: UserFeaturePreferring?
    ) {
        let microsurveyManager: MicrosurveyManager = injectedMicrosurveyManager ?? MockMicrosurveySurfaceManager()
        container.register(service: microsurveyManager as MicrosurveyManager)

        let merinoManager: MerinoManagerProvider = injectedMerinoManager ?? MockMerinoManager()
        container.register(service: merinoManager as MerinoManagerProvider)

        let documentLogger = DocumentLogger(logger: MockLogger())
        container.register(service: documentLogger)

        let gleanUsageReportingMetricsService: GleanUsageReportingMetricsService =
        MockGleanUsageReportingMetricsService(profile: profile)
        container.register(service: gleanUsageReportingMetricsService)

        container.register(service: ShareTelemetry())

        let featureFlagProvider = injectedFeatureFlagProvider ?? FeatureFlagsProvider(prefs: profile.prefs)
        container.register(service: featureFlagProvider as FeatureFlagProviding)

        let userFeatureProvider = injectedUserFeaturePreferences ?? UserFeaturePreferenceManager(
            prefs: profile.prefs
        )
        container.register(service: userFeatureProvider as UserFeaturePreferring)
    }

    func reset() {
        // Intentionally leaves the container populated: emptying it while async
        // work from the finishing test is still in flight makes any late
        // AppContainer.resolve fatalError (host crash under parallel testing).
        // The next test's bootstrapDependencies() swaps in fresh registrations.
    }
}
