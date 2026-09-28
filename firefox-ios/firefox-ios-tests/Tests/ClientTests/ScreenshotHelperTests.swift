// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest

@testable import Client

@MainActor
final class ScreenshotHelperTests: XCTestCase, StoreTestUtility {
    var profile: MockProfile!
    var tabManager: MockTabManager!
    var mockVC: MockBrowserViewController!
    var mockStore: MockStoreForMiddleware<AppState>!

    override func setUp() async throws {
        try await super.setUp()
        profile = MockProfile()
        tabManager = MockTabManager()
        DependencyHelperMock().bootstrapDependencies()
        mockVC = MockBrowserViewController(profile: profile, tabManager: tabManager)
        setupStore()
    }

    override func tearDown() async throws {
        profile.shutdown()
        profile = nil
        DependencyHelperMock().reset()
        mockVC = nil
        tabManager = nil
        resetStore()
        try await super.tearDown()
    }

    func testTakeScreenshotForHomepage() {
        let subject = createSubject()
        let tab = Tab(profile: profile, windowUUID: .XCTestDefaultUUID)
        let homeURL = URL(string: "internal://local/about/home")
        let mockTabWebView = MockTabWebView(tab: tab)
        tabManager.selectedTab = tab

        mockTabWebView.loadedURL = homeURL
        tab.webView = mockTabWebView
        tab.url = homeURL

        subject.takeScreenshot(tab, windowUUID: .XCTestDefaultUUID, screenshotBounds: .zero)

        guard let screenshotAction = mockStore.dispatchedActions.first as? ScreenshotAction else {
            XCTFail("fired action was not of the expected type")
            return
        }

        XCTAssertEqual(tab.screenshot, UIImage.checkmark)
        XCTAssertTrue(tab.hasHomeScreenshot)
        XCTAssertEqual(screenshotAction.tab, tab)
    }

    func testTakeScreenshotFromErrorPage() {
        let subject = createSubject()
        let tab = Tab(profile: profile, windowUUID: .XCTestDefaultUUID)
        let homeURL = URL(string: "https://example.com")
        let mockTabWebView = MockTabWebView(tab: tab)

        mockVC.mockContentContainer.shouldHaveNativeErrorPage = true
        mockTabWebView.loadedURL = homeURL
        tab.webView = mockTabWebView
        tab.url = homeURL

        subject.takeScreenshot(tab, windowUUID: .XCTestDefaultUUID, screenshotBounds: .zero)

        guard let screenshotAction = mockStore.dispatchedActions.first as? ScreenshotAction else {
            XCTFail("fired action was not of the expected type")
            return
        }

        XCTAssertEqual(screenshotAction.tab, tab)
        XCTAssertEqual(tab.screenshot, UIImage.checkmark)
        XCTAssertFalse(tab.hasHomeScreenshot)
    }

    func testTakeScreenshotFromWebView() {
        let subject = createSubject()
        let tab = Tab(profile: profile, windowUUID: .XCTestDefaultUUID)
        let homeURL = URL(string: "https://example.com")
        let mockTabWebView = MockTabWebView(tab: tab)

        mockTabWebView.loadedURL = homeURL
        tab.webView = mockTabWebView
        tab.url = homeURL

        subject.takeScreenshot(tab, windowUUID: .XCTestDefaultUUID, screenshotBounds: .zero)

        guard let screenshotAction = mockStore.dispatchedActions.first as? ScreenshotAction else {
            XCTFail("fired action was not of the expected type")
            return
        }

        XCTAssertTrue(mockTabWebView.takeSnapshotWasCalled)
        XCTAssertEqual(screenshotAction.tab, tab)
        XCTAssertEqual(tab.screenshot, UIImage.strokedCheckmark)
        XCTAssertFalse(tab.hasHomeScreenshot)
    }

    func testTakeScreenshotFromWebView_capturesAtOnePixelPerPoint() throws {
        let subject = createSubject()
        let (tab, mockTabWebView) = makeWebTab()
        mockTabWebView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)

        subject.takeScreenshot(tab,
                               windowUUID: .XCTestDefaultUUID,
                               screenshotBounds: CGRect(x: 0, y: -60, width: 390, height: 844))

        let configuration = try XCTUnwrap(mockTabWebView.lastSnapshotConfiguration)
        let snapshotWidth = try XCTUnwrap(configuration.snapshotWidth).doubleValue
        let pointWidth = configuration.rect.isNull ? mockTabWebView.bounds.width : configuration.rect.width
        let displayScale = max(mockTabWebView.traitCollection.displayScale, 1)
        XCTAssertEqual(snapshotWidth * displayScale, pointWidth, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tab.screenshot).size.width, pointWidth, accuracy: 0.001)
    }

    private func makeWebTab() -> (Tab, MockTabWebView) {
        let tab = Tab(profile: profile, windowUUID: .XCTestDefaultUUID)
        let url = URL(string: "https://example.com")
        let mockTabWebView = MockTabWebView(tab: tab)
        mockTabWebView.loadedURL = url
        tab.webView = mockTabWebView
        tab.url = url
        return (tab, mockTabWebView)
    }

    private func createSubject() -> ScreenshotHelper {
        let subject = ScreenshotHelper(controller: mockVC)
        trackForMemoryLeaks(subject)
        return subject
    }

    func setupAppState() -> AppState {
        return AppState()
    }
}
