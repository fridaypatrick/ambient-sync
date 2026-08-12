import AppKit
import Foundation
import XCTest
@testable import AmbientSync

@MainActor
final class IntegrationTests: XCTestCase {
    func testAppLifecycleStateSuppressesInitialUntitledOpenOnlyBeforeLaunch() {
        var state = AppLifecycleState()

        XCTAssertFalse(state.shouldShowSettingsForUntitledOpen)

        state.markDidFinishLaunching()

        XCTAssertTrue(state.shouldShowSettingsForUntitledOpen)
    }

    func testAppearanceRedundantCurrentModeSuppressesRequest() {
        let adapter = TestAppearanceAdapter(mode: .dark)
        let controller = AppearanceAutomationController(adapter: adapter)

        controller.evaluate(brightness: 0.10)

        XCTAssertEqual(adapter.readCount, 1)
        XCTAssertEqual(adapter.requestedModes, [])
        XCTAssertEqual(controller.status, .operational)
    }

    func testAppearanceBetweenThresholdsDoesNotReadOrRequest() {
        let adapter = TestAppearanceAdapter(mode: .light)
        let controller = AppearanceAutomationController(adapter: adapter)

        controller.evaluate(brightness: 0.30)

        XCTAssertEqual(adapter.readCount, 0)
        XCTAssertEqual(adapter.requestedModes, [])
        XCTAssertEqual(controller.status, .notAttempted)
    }

    func testAppearanceSuccessfulSwitchCompletesDwellBeforeNextRequest() {
        let clock = TestIntegrationClock(now: Date(timeIntervalSince1970: 0))
        let adapter = TestAppearanceAdapter(mode: .light)
        let controller = AppearanceAutomationController(
            adapter: adapter,
            minimumDwell: 60,
            clock: clock
        )

        controller.evaluate(brightness: 0.20)
        XCTAssertEqual(adapter.requestedModes, [.dark])

        clock.now = Date(timeIntervalSince1970: 59)
        controller.evaluate(brightness: 0.80)
        XCTAssertEqual(adapter.requestedModes, [.dark])

        clock.now = Date(timeIntervalSince1970: 60)
        controller.evaluate(brightness: 0.80)
        XCTAssertEqual(adapter.requestedModes, [.dark, .light])
    }

    func testAppearanceFailureClearsPendingRequestForLaterRetry() {
        let adapter = TestAppearanceAdapter(
            mode: .light,
            setErrors: [AppearanceAutomationError.permissionDenied, nil]
        )
        let controller = AppearanceAutomationController(adapter: adapter)

        controller.evaluate(brightness: 0.20)
        XCTAssertEqual(controller.status, .permissionDenied)

        controller.evaluate(brightness: 0.20)
        XCTAssertEqual(adapter.requestedModes, [.dark, .dark])
        XCTAssertEqual(controller.status, .operational)
    }

    func testAppearancePermissionDeniedMapsToActionableStatus() {
        let adapter = TestAppearanceAdapter(
            mode: .light,
            readError: AppearanceAutomationError.permissionDenied
        )
        let controller = AppearanceAutomationController(adapter: adapter)

        controller.evaluate(brightness: 0.20)

        XCTAssertEqual(controller.status, .permissionDenied)
        XCTAssertTrue(controller.status.userMessage.contains("Privacy & Security"))
    }

    func testSystemEventsAppearanceResponseParserAcceptsKnownBooleanDescriptors() {
        XCTAssertEqual(
            SystemEventsAppearanceResponseParser.mode(
                from: NSAppleEventDescriptor(boolean: true)
            ),
            .dark
        )
        XCTAssertEqual(
            SystemEventsAppearanceResponseParser.mode(
                from: NSAppleEventDescriptor(boolean: false)
            ),
            .light
        )

        XCTAssertEqual(
            SystemEventsAppearanceResponseParser.mode(from: appleScriptDescriptor("return true")),
            .dark
        )
        XCTAssertEqual(
            SystemEventsAppearanceResponseParser.mode(from: appleScriptDescriptor("return false")),
            .light
        )
    }

    func testSystemEventsAppearanceResponseParserAcceptsExactModeTokens() {
        XCTAssertEqual(
            SystemEventsAppearanceResponseParser.mode(
                from: NSAppleEventDescriptor(string: "dark")
            ),
            .dark
        )
        XCTAssertEqual(
            SystemEventsAppearanceResponseParser.mode(
                from: NSAppleEventDescriptor(string: "light")
            ),
            .light
        )
    }

    func testSystemEventsAppearanceResponseParserRejectsUnknownResponses() {
        let invalidResponses = [
            NSAppleEventDescriptor(string: "true"),
            NSAppleEventDescriptor(string: "false"),
            NSAppleEventDescriptor(string: "Dark"),
            NSAppleEventDescriptor(string: " dark "),
            NSAppleEventDescriptor(int32: 1)
        ]

        for response in invalidResponses {
            XCTAssertNil(SystemEventsAppearanceResponseParser.mode(from: response))
        }
    }

    func testLoginManagerReconcilesPersistedSettingToActualServiceState() {
        let suiteName = "AmbientSyncTests.Login.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: SettingsStore.launchAtLoginEnabledKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let service = TestLoginItemService(state: .notRegistered)
        let manager = LoginItemManager(settings: settings, service: service)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(settings.launchAtLoginEnabled)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(settings.launchAtLoginEnabled)

        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(settings.launchAtLoginEnabled)
    }

    func testLoginManagerRestoresVisibleStateAfterRegistrationError() {
        let suiteName = "AmbientSyncTests.Login.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let service = TestLoginItemService(
            state: .notRegistered,
            registerError: TestLoginError.denied
        )
        let manager = LoginItemManager(settings: settings, service: service)

        manager.setEnabled(true)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(settings.launchAtLoginEnabled)
        XCTAssertEqual(manager.lastError, TestLoginError.denied.localizedDescription)
    }

    func testLoginManagerExposesApprovalRequirementWithoutClaimingEnabled() {
        let suiteName = "AmbientSyncTests.Login.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let service = TestLoginItemService(state: .requiresApproval)
        let manager = LoginItemManager(settings: settings, service: service)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.registrationState, .requiresApproval)
        XCTAssertNotNil(manager.statusMessage)
    }

}

private func appleScriptDescriptor(_ source: String) -> NSAppleEventDescriptor {
    let script = NSAppleScript(source: source)!
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    XCTAssertNil(error)
    return result
}

@MainActor
private final class TestAppearanceAdapter: SystemAppearanceAdapter {
    private(set) var mode: AppearanceMode
    private(set) var readCount = 0
    private(set) var requestedModes: [AppearanceMode] = []
    private var setErrors: [Error?]
    private let readError: Error?

    init(mode: AppearanceMode, readError: Error? = nil, setErrors: [Error?] = []) {
        self.mode = mode
        self.readError = readError
        self.setErrors = setErrors
    }

    func currentMode() throws -> AppearanceMode {
        readCount += 1
        if let readError {
            throw readError
        }
        return mode
    }

    func setMode(_ mode: AppearanceMode) throws {
        requestedModes.append(mode)
        let error = setErrors.isEmpty ? nil : setErrors.removeFirst()
        if let error {
            throw error
        }
        self.mode = mode
    }
}

@MainActor
private final class TestLoginItemService: LoginItemService {
    private(set) var state: LoginItemRegistrationState
    private let registerError: Error?
    private let unregisterError: Error?

    init(
        state: LoginItemRegistrationState,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.state = state
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func registrationState() -> LoginItemRegistrationState {
        state
    }

    func register() throws {
        if let registerError {
            throw registerError
        }
        state = .enabled
    }

    func unregister() throws {
        if let unregisterError {
            throw unregisterError
        }
        state = .notRegistered
    }
}

private enum TestLoginError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Login item registration denied."
    }
}

private final class TestIntegrationClock: AmbientClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
