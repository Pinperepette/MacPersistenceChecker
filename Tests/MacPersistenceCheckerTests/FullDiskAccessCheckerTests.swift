import XCTest
@testable import MacPersistenceChecker

final class FullDiskAccessCheckerTests: XCTestCase {
    private let fdaGrantedKey = "fdaWasGranted"

    func testAnySuccessfulProtectedProbeGrantsFDA() {
        let fakeExecutor = FakeFDAProbeExecutor(results: [
            .systemTCCDatabase: .failure(.systemTCCDatabase, api: .posixOpen),
            .userSafariHistory: .success(.userSafariHistory, api: .posixOpen),
            .userMailDirectory: .failure(.userMailDirectory, api: .contentsOfDirectory),
            .launchDaemonsDirectory: .failure(.launchDaemonsDirectory, api: .contentsOfDirectory),
            .launchDaemonsTCCDatabaseReadable: .failure(.launchDaemonsTCCDatabaseReadable, api: .isReadableFile)
        ])
        let defaults = makeDefaults()
        let checker = makeChecker(executor: fakeExecutor, defaults: defaults)

        let snapshot = checker.refreshAccess(reason: .manual)

        XCTAssertTrue(snapshot.isGranted)
        XCTAssertTrue(checker.hasFullDiskAccess)
    }

    func testAllFailedProtectedProbesDenyFDA() {
        let fakeExecutor = FakeFDAProbeExecutor.allFailed()
        let defaults = makeDefaults()
        let checker = makeChecker(executor: fakeExecutor, defaults: defaults)

        let snapshot = checker.refreshAccess(reason: .manual)

        XCTAssertFalse(snapshot.isGranted)
        XCTAssertFalse(checker.hasFullDiskAccess)
    }

    func testStaleGrantedDefaultIsClearedAfterDeniedRefresh() {
        let fakeExecutor = FakeFDAProbeExecutor.allFailed()
        let defaults = makeDefaults()
        defaults.set(true, forKey: fdaGrantedKey)
        let checker = makeChecker(executor: fakeExecutor, defaults: defaults)

        _ = checker.refreshAccess(reason: .manual)

        XCTAssertFalse(defaults.bool(forKey: fdaGrantedKey))
        XCTAssertFalse(checker.hasFullDiskAccess)
    }

    func testSuccessfulRefreshWritesGrantedDefault() {
        let fakeExecutor = FakeFDAProbeExecutor(results: [
            .systemTCCDatabase: .success(.systemTCCDatabase, api: .posixOpen),
            .userSafariHistory: .failure(.userSafariHistory, api: .posixOpen),
            .userMailDirectory: .failure(.userMailDirectory, api: .contentsOfDirectory),
            .launchDaemonsDirectory: .failure(.launchDaemonsDirectory, api: .contentsOfDirectory),
            .launchDaemonsTCCDatabaseReadable: .failure(.launchDaemonsTCCDatabaseReadable, api: .isReadableFile)
        ])
        let defaults = makeDefaults()
        let checker = makeChecker(executor: fakeExecutor, defaults: defaults)

        _ = checker.refreshAccess(reason: .manual)

        XCTAssertTrue(defaults.bool(forKey: fdaGrantedKey))
        XCTAssertTrue(checker.hasFullDiskAccess)
    }

    func testPollingUsesRefreshPath() {
        let fakeExecutor = FakeFDAProbeExecutor(results: [
            .systemTCCDatabase: .success(.systemTCCDatabase, api: .posixOpen),
            .userSafariHistory: .failure(.userSafariHistory, api: .posixOpen),
            .userMailDirectory: .failure(.userMailDirectory, api: .contentsOfDirectory),
            .launchDaemonsDirectory: .failure(.launchDaemonsDirectory, api: .contentsOfDirectory),
            .launchDaemonsTCCDatabaseReadable: .failure(.launchDaemonsTCCDatabaseReadable, api: .isReadableFile)
        ])
        let defaults = makeDefaults()
        let checker = makeChecker(executor: fakeExecutor, defaults: defaults)
        let granted = expectation(description: "polling detected FDA grant")

        checker.startPolling(interval: 0.01) {
            granted.fulfill()
        }

        wait(for: [granted], timeout: 1.0)
        checker.stopPolling()

        XCTAssertEqual(checker.lastSnapshot?.reason, .polling)
        XCTAssertEqual(fakeExecutor.calls.map(\.probeID), FDAProbeID.allCases)
        XCTAssertFalse(checker.isChecking)
    }

    func testLastSnapshotContainsEveryProbeAndPreservesErrorDetails() throws {
        let fakeExecutor = FakeFDAProbeExecutor(results: [
            .systemTCCDatabase: .failure(.systemTCCDatabase, api: .posixOpen, errnoCode: EACCES),
            .userSafariHistory: .failure(.userSafariHistory, api: .posixOpen, errnoCode: ENOENT),
            .userMailDirectory: .failure(
                .userMailDirectory,
                api: .contentsOfDirectory,
                cocoaErrorDomain: NSCocoaErrorDomain,
                cocoaErrorCode: NSFileReadNoPermissionError
            ),
            .launchDaemonsDirectory: .success(.launchDaemonsDirectory, api: .contentsOfDirectory),
            .launchDaemonsTCCDatabaseReadable: .failure(
                .launchDaemonsTCCDatabaseReadable,
                api: .isReadableFile,
                cocoaErrorDomain: NSCocoaErrorDomain,
                cocoaErrorCode: NSFileNoSuchFileError
            )
        ])
        let defaults = makeDefaults()
        let checker = makeChecker(executor: fakeExecutor, defaults: defaults)

        _ = checker.refreshAccess(reason: .manual)

        let snapshot = try XCTUnwrap(checker.lastSnapshot)
        XCTAssertEqual(snapshot.results.map(\.probeID), FDAProbeID.allCases)
        XCTAssertEqual(snapshot.results.first?.errnoCode, EACCES)

        let mailProbe = try XCTUnwrap(snapshot.results.first { $0.probeID == .userMailDirectory })
        XCTAssertEqual(mailProbe.cocoaErrorDomain, NSCocoaErrorDomain)
        XCTAssertEqual(mailProbe.cocoaErrorCode, NSFileReadNoPermissionError)

        let readableProbe = try XCTUnwrap(snapshot.results.first { $0.probeID == .launchDaemonsTCCDatabaseReadable })
        XCTAssertEqual(readableProbe.api, .isReadableFile)
        XCTAssertEqual(readableProbe.cocoaErrorCode, NSFileNoSuchFileError)
    }

    private func makeChecker(
        executor: FDAProbeExecuting,
        defaults: UserDefaults
    ) -> FullDiskAccessChecker {
        FullDiskAccessChecker(
            executor: executor,
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            observeAppActivation: false,
            performInitialCheck: false
        )
    }

    private func makeDefaults(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UserDefaults {
        let suiteName = "MacPersistenceCheckerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
            return .standard
        }

        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class FakeFDAProbeExecutor: FDAProbeExecuting {
    struct Call {
        let probeID: FDAProbeID
        let api: FDAProbeAPI
        let path: String
    }

    private let results: [FDAProbeID: FDAProbeResult]
    private(set) var calls: [Call] = []

    init(results: [FDAProbeID: FDAProbeResult]) {
        self.results = results
    }

    static func allFailed() -> FakeFDAProbeExecutor {
        FakeFDAProbeExecutor(results: [
            .systemTCCDatabase: .failure(.systemTCCDatabase, api: .posixOpen),
            .userSafariHistory: .failure(.userSafariHistory, api: .posixOpen),
            .userMailDirectory: .failure(.userMailDirectory, api: .contentsOfDirectory),
            .launchDaemonsDirectory: .failure(.launchDaemonsDirectory, api: .contentsOfDirectory),
            .launchDaemonsTCCDatabaseReadable: .failure(.launchDaemonsTCCDatabaseReadable, api: .isReadableFile)
        ])
    }

    func canOpenForRead(probeID: FDAProbeID, path: String) -> FDAProbeResult {
        calls.append(Call(probeID: probeID, api: .posixOpen, path: path))
        return result(for: probeID, fallbackAPI: .posixOpen)
    }

    func canListDirectory(probeID: FDAProbeID, path: String) -> FDAProbeResult {
        calls.append(Call(probeID: probeID, api: .contentsOfDirectory, path: path))
        return result(for: probeID, fallbackAPI: .contentsOfDirectory)
    }

    func isReadableFile(probeID: FDAProbeID, path: String) -> FDAProbeResult {
        calls.append(Call(probeID: probeID, api: .isReadableFile, path: path))
        return result(for: probeID, fallbackAPI: .isReadableFile)
    }

    private func result(for probeID: FDAProbeID, fallbackAPI: FDAProbeAPI) -> FDAProbeResult {
        results[probeID] ?? .failure(probeID, api: fallbackAPI)
    }
}

private extension FDAProbeResult {
    static func success(_ probeID: FDAProbeID, api: FDAProbeAPI) -> FDAProbeResult {
        FDAProbeResult(
            probeID: probeID,
            path: "/test/\(probeID.rawValue)",
            api: api,
            success: true,
            timestamp: Date(timeIntervalSince1970: 1)
        )
    }

    static func failure(
        _ probeID: FDAProbeID,
        api: FDAProbeAPI,
        errnoCode: Int32? = nil,
        cocoaErrorDomain: String? = nil,
        cocoaErrorCode: Int? = nil
    ) -> FDAProbeResult {
        FDAProbeResult(
            probeID: probeID,
            path: "/test/\(probeID.rawValue)",
            api: api,
            success: false,
            errnoCode: errnoCode,
            cocoaErrorDomain: cocoaErrorDomain,
            cocoaErrorCode: cocoaErrorCode,
            timestamp: Date(timeIntervalSince1970: 1)
        )
    }
}
