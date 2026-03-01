import XCTest
import WebKit
@testable import PopupBridge

class MockURLOpener: URLOpener {

    var isVenmoInstalled = false
    var isPayPalInstalled = false
    var openURLCalled = false
    var openURLArg: URL?
    var openURLSuccess = true

    func isVenmoAppInstalled() -> Bool {
        isVenmoInstalled
    }

    func isPayPalAppInstalled() -> Bool {
        isPayPalInstalled
    }

    func openURL(_ url: URL, completionHandler: @escaping (Bool) -> Void) {
        openURLCalled = true
        openURLArg = url
        completionHandler(openURLSuccess)
    }
}

final class PopupBridge_AppSwitch_UnitTests: XCTestCase {

    let scriptMessageHandlerName = "POPPopupBridge"
    let mockWebAuthenticationSession = MockWebAuthenticationSession()
    let mockAnalyticsService = MockAnalyticsService()
    let mockURLOpener = MockURLOpener()

    override func setUp() {
        super.setUp()
        POPPopupBridge.analyticsService = mockAnalyticsService
        POPPopupBridge.activeInstance = nil
    }

    // MARK: - Helper

    private func makeSUT(paypalInstalled: Bool = false) -> (POPPopupBridge, WKWebView) {
        mockURLOpener.isPayPalInstalled = paypalInstalled
        let webView = WKWebView()
        let sut = POPPopupBridge(
            webView: webView,
            application: mockURLOpener,
            webAuthenticationSession: mockWebAuthenticationSession
        )
        return (sut, webView)
    }

    private func makeLaunchAppMessage() -> MockScriptMessage {
        let msg = MockScriptMessage()
        msg.body = ["url": "https://paypal.com/checkout?token=EC-123", "action": "launchApp"] as [String: Any]
        msg.name = scriptMessageHandlerName
        return msg
    }

    private func makeOpenMessage() -> MockScriptMessage {
        let msg = MockScriptMessage()
        msg.body = ["url": "http://example.com/?hello=world"] as [String: String]
        msg.name = scriptMessageHandlerName
        return msg
    }

    private func extractJSON(from jsString: String) -> [String: Any]? {
        let pattern = "window\\.popupBridge\\.onComplete\\(null, (.*)\\);"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        if let match = regex?.firstMatch(in: jsString, options: [], range: NSRange(jsString.startIndex..., in: jsString)),
           let jsonRange = Range(match.range(at: 1), in: jsString) {
            let jsonString = String(jsString[jsonRange])

            if let data = jsonString.data(using: .utf8) {
                return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            }
        }

        return nil
    }

    // MARK: - isPayPalInstalled detection

    func testInit_whenPayPalInstalled_sendsAppDetectedAnalytics() {
        let (_, _) = makeSUT(paypalInstalled: true)

        // Should have 2 events: "started" then "app-detected"
        XCTAssertEqual(mockAnalyticsService.eventCount, 2)
        XCTAssertEqual(mockAnalyticsService.lastEventName, PopupBridgeAnalytics.appDetected)
    }

    func testInit_whenPayPalNotInstalled_doesNotSendAppDetectedAnalytics() {
        let (_, _) = makeSUT(paypalInstalled: false)

        // Should only have the "started" event, not "app-detected"
        XCTAssertEqual(mockAnalyticsService.eventCount, 1)
        XCTAssertEqual(mockAnalyticsService.lastEventName, PopupBridgeAnalytics.started)
    }

    // MARK: - UserScript injection

    func testInit_injectsIsPayPalInstalledTrue_whenAppInstalled() {
        let (_, webView) = makeSUT(paypalInstalled: true)

        let script = webView.configuration.userContentController.userScripts.first
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.source.contains("window.popupBridge.isPayPalInstalled = true"))
    }

    func testInit_injectsIsPayPalInstalledFalse_whenAppNotInstalled() {
        let (_, webView) = makeSUT(paypalInstalled: false)

        let script = webView.configuration.userContentController.userScripts.first
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.source.contains("window.popupBridge.isPayPalInstalled = false"))
    }

    func testInit_injectsLaunchAppFunction() {
        let (_, webView) = makeSUT()

        let script = webView.configuration.userContentController.userScripts.first
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.source.contains("window.popupBridge.launchApp"))
        XCTAssertTrue(script!.source.contains("action: \"launchApp\""))
    }

    // MARK: - launchApp message routing

    func testReceiveScriptMessage_whenActionIsLaunchApp_callsOpenURL() {
        let (sut, _) = makeSUT()
        let message = makeLaunchAppMessage()

        sut.userContentController(WKUserContentController(), didReceive: message)

        XCTAssertTrue(mockURLOpener.openURLCalled)
        XCTAssertEqual(mockURLOpener.openURLArg?.absoluteString, "https://paypal.com/checkout?token=EC-123")
    }

    func testReceiveScriptMessage_whenActionIsLaunchApp_doesNotStartWebAuthSession() {
        let (sut, _) = makeSUT()
        let message = makeLaunchAppMessage()
        mockWebAuthenticationSession.cannedResponseURL = URL(string: "http://example.com")

        sut.userContentController(WKUserContentController(), didReceive: message)

        // returnedWithURL should remain false since we didn't go through web auth
        XCTAssertFalse(sut.returnedWithURL)
    }

    func testReceiveScriptMessage_whenActionIsLaunchApp_andOpenURLSucceeds_sendsAppLaunchedAnalytics() {
        let (sut, _) = makeSUT()
        mockURLOpener.openURLSuccess = true
        let message = makeLaunchAppMessage()

        sut.userContentController(WKUserContentController(), didReceive: message)

        XCTAssertEqual(mockAnalyticsService.lastEventName, PopupBridgeAnalytics.appLaunched)
    }

    func testReceiveScriptMessage_whenActionIsLaunchApp_andOpenURLFails_sendsAppLaunchFailedAnalytics() {
        let (sut, _) = makeSUT()
        mockURLOpener.openURLSuccess = false
        let message = makeLaunchAppMessage()

        sut.userContentController(WKUserContentController(), didReceive: message)

        XCTAssertEqual(mockAnalyticsService.lastEventName, PopupBridgeAnalytics.appLaunchFailed)
    }

    // MARK: - Backward compatibility (no action field)

    func testReceiveScriptMessage_whenNoActionField_startsWebAuthSession() {
        let (sut, _) = makeSUT()
        let message = makeOpenMessage()
        mockWebAuthenticationSession.cannedResponseURL = URL(string: "sdk.ios.popup-bridge://popupbridgev1/return?token=abc")

        sut.userContentController(WKUserContentController(), didReceive: message)

        XCTAssertTrue(sut.returnedWithURL)
        XCTAssertFalse(mockURLOpener.openURLCalled)
    }

    // MARK: - handleOpenURL

    func testHandleOpenURL_whenActiveInstanceSet_setsReturnedWithURL() {
        let (sut, _) = makeSUT()
        POPPopupBridge.activeInstance = sut

        let returnURL = URL(string: "com.paypal.XOSphereApp.payments://popupbridgev1/return?token=EC-TEST123")!
        POPPopupBridge.handleOpenURL(returnURL)

        XCTAssertTrue(sut.returnedWithURL)
    }

    func testHandleOpenURL_whenNoActiveInstance_doesNotCrash() {
        POPPopupBridge.activeInstance = nil

        let returnURL = URL(string: "com.paypal.XOSphereApp.payments://popupbridgev1/return?token=EC-TEST123")!
        POPPopupBridge.handleOpenURL(returnURL)
        // Should not crash
    }

    func testHandleOpenURL_sendsAppSwitchReturnedAnalytics() {
        let (sut, _) = makeSUT()
        POPPopupBridge.activeInstance = sut

        let returnURL = URL(string: "com.paypal.XOSphereApp.payments://popupbridgev1/return?token=EC-TEST123")!
        POPPopupBridge.handleOpenURL(returnURL)

        // constructAppSwitchCompletionResult sends "succeeded", then handleOpenURL sends "appSwitchReturned"
        XCTAssertTrue(mockAnalyticsService.allEventNames.contains(PopupBridgeAnalytics.succeeded))
        XCTAssertEqual(mockAnalyticsService.lastEventName, PopupBridgeAnalytics.appSwitchReturned)
    }

    // MARK: - constructAppSwitchCompletionResult

    func testConstructAppSwitchCompletionResult_withQueryParams_returnsCorrectPayload() {
        let (sut, _) = makeSUT()
        let url = URL(string: "com.paypal.XOSphereApp.payments://popupbridgev1/return?token=EC-123&PayerID=ABC")!

        let result = sut.constructAppSwitchCompletionResult(returnURL: url)

        XCTAssertNotNil(result)
        let json = extractJSON(from: result!)
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["path"] as? String, "/return")
        let queryItems = json?["queryItems"] as? [String: String]
        XCTAssertEqual(queryItems?["token"], "EC-123")
        XCTAssertEqual(queryItems?["PayerID"], "ABC")
    }

    func testConstructAppSwitchCompletionResult_withFragment_returnsHash() {
        let (sut, _) = makeSUT()
        let url = URL(string: "com.paypal.XOSphereApp.payments://popupbridgev1/return#fragment=value")!

        let result = sut.constructAppSwitchCompletionResult(returnURL: url)

        XCTAssertNotNil(result)
        let json = extractJSON(from: result!)
        XCTAssertEqual(json?["hash"] as? String, "fragment=value")
    }

    func testConstructAppSwitchCompletionResult_withMismatchedHost_returnsNil() {
        let (sut, _) = makeSUT()
        let url = URL(string: "com.paypal.XOSphereApp.payments://wronghost/return?token=EC-123")!

        let result = sut.constructAppSwitchCompletionResult(returnURL: url)

        XCTAssertNil(result)
    }

    func testConstructAppSwitchCompletionResult_validatesHostOnly_notScheme() {
        let (sut, _) = makeSUT()
        // Any scheme should work as long as host matches
        let url = URL(string: "any.custom.scheme://popupbridgev1/return?token=EC-123")!

        let result = sut.constructAppSwitchCompletionResult(returnURL: url)

        XCTAssertNotNil(result)
    }

    func testConstructAppSwitchCompletionResult_noQueryParams_returnsEmptyQueryItems() {
        let (sut, _) = makeSUT()
        let url = URL(string: "com.paypal.XOSphereApp.payments://popupbridgev1/return")!

        let result = sut.constructAppSwitchCompletionResult(returnURL: url)

        XCTAssertNotNil(result)
        let json = extractJSON(from: result!)
        let queryItems = json?["queryItems"] as? [String: String]
        XCTAssertEqual(queryItems, [:])
    }
}
