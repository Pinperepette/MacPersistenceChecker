import XCTest
@testable import MacPersistenceChecker

@MainActor
final class AppStatePermissionTests: XCTestCase {
    func testLegacySkipFDACheckKeyIsClearedOnInitialization() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppState.legacySkipFDACheckKey)

        _ = makeAppState(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: AppState.legacySkipFDACheckKey))
    }

    func testSessionSkipDoesNotPersistAcrossFreshAppStateInitialization() {
        let defaults = makeDefaults()
        let firstState = makeAppState(defaults: defaults)
        firstState.skipFDACheckForCurrentSession = true

        let freshState = makeAppState(defaults: defaults)

        XCTAssertTrue(firstState.skipFDACheckForCurrentSession)
        XCTAssertFalse(freshState.skipFDACheckForCurrentSession)
        XCTAssertNil(defaults.object(forKey: AppState.legacySkipFDACheckKey))
    }

    private func makeAppState(defaults: UserDefaults) -> AppState {
        AppState(
            defaults: defaults,
            initializeDatabase: false,
            setupBindings: false,
            startBackgroundLoading: false,
            preloadCaches: false
        )
    }

    private func makeDefaults(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UserDefaults {
        let suiteName = "MacPersistenceCheckerTests.AppState.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
            return .standard
        }

        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
