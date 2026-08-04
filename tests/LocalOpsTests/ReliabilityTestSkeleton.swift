import Darwin
import Foundation
import LocalOpsCore
import LocalOpsWeb
import XCTest

/// Release-blocking reliability coverage.  These tests use only temporary
/// databases, loopback sockets and child processes created by the test
/// itself; no configured user service is started or stopped.
final class ReliabilityTests: XCTestCase {
  func testFailureHysteresisRecoveryAndEventDeduplication() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LocalOpsStore(path: directory.appendingPathComponent("localops.sqlite3"))
    try await store.migrate()

    let base = Date()
    let healthy = Self.snapshot(
      id: "hysteresis",
      lifecycle: .running,
      health: .healthy,
      checkedAt: base
    )
    let firstFailure = Self.snapshot(
      id: "hysteresis",
      lifecycle: .stopped,
      health: .unhealthy,
      checkedAt: base.addingTimeInterval(1)
    )
    let secondFailure = Self.snapshot(
      id: "hysteresis",
      lifecycle: .stopped,
      health: .unhealthy,
      checkedAt: base.addingTimeInterval(2)
    )
    let recovered = Self.snapshot(
      id: "hysteresis",
      lifecycle: .running,
      health: .healthy,
      checkedAt: base.addingTimeInterval(3)
    )

    _ = try await store.commitRefresh(
      snapshots: [healthy], observed: [], attemptedAt: base, successfulAt: base
    )
    let first = try await store.commitRefresh(
      snapshots: [firstFailure], observed: [],
      attemptedAt: base.addingTimeInterval(1), successfulAt: base.addingTimeInterval(1)
    ).snapshots[0]
    XCTAssertNotEqual(first.lifecycle, .stopped, "one failed probe must not mark offline")
    XCTAssertEqual(first.health, .degraded)
    XCTAssertEqual(first.observation.freshness, .partial)

    let second = try await store.commitRefresh(
      snapshots: [secondFailure], observed: [],
      attemptedAt: base.addingTimeInterval(2), successfulAt: base.addingTimeInterval(2)
    ).snapshots[0]
    XCTAssertEqual(second.lifecycle, .stopped, "the second consecutive failure marks offline")
    XCTAssertEqual(second.health, .unhealthy)

    // A repeated failure keeps the same state and must not create another
    // transition event.
    _ = try await store.commitRefresh(
      snapshots: [secondFailure], observed: [],
      attemptedAt: base.addingTimeInterval(2.5), successfulAt: base.addingTimeInterval(2.5)
    )
    let recoveredSnapshot = try await store.commitRefresh(
      snapshots: [recovered], observed: [],
      attemptedAt: base.addingTimeInterval(3), successfulAt: base.addingTimeInterval(3)
    ).snapshots[0]
    XCTAssertEqual(recoveredSnapshot.lifecycle, .running)
    XCTAssertEqual(recoveredSnapshot.health, .healthy)

    // A repeated healthy result must also be deduplicated.
    _ = try await store.commitRefresh(
      snapshots: [recovered], observed: [],
      attemptedAt: base.addingTimeInterval(4), successfulAt: base.addingTimeInterval(4)
    )
    let events = try await store.listEvents(limit: 200).sorted { $0.id < $1.id }
    XCTAssertEqual(events.map(\.kind), ["discovered", "health_changed", "stopped", "recovered"])
  }

  func testDiscoveryFailureKeepsSnapshotAndMarksStale() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let discovery = ReliabilityScriptedDiscovery(steps: [.listeners([]), .failure])
    let engine = try LocalOpsEngine(
      paths: Self.paths(in: directory),
      discovery: discovery,
      healthChecker: ReliabilityHealthyChecker()
    )

    let first = try await engine.initialize()
    XCTAssertNotNil(first.refreshedAt)
    XCTAssertEqual(first.metadata.outcome, .success)
    let second = await engine.refresh()

    XCTAssertEqual(second.services, first.services, "failed discovery must retain last snapshot")
    XCTAssertEqual(second.events, first.events)
    XCTAssertEqual(second.refreshedAt, first.refreshedAt)
    XCTAssertEqual(second.metadata.successfulAt, first.metadata.successfulAt)
    XCTAssertGreaterThan(
      second.metadata.attemptedAt ?? .distantPast,
      first.metadata.attemptedAt ?? .distantPast
    )
    XCTAssertEqual(second.metadata.outcome, .failed)
    XCTAssertEqual(second.metadata.freshness, .stale)
    XCTAssertNotNil(second.metadata.error)
    XCTAssertEqual(second.error, second.metadata.error)
  }

  func testDatabasePermissionsAndEventRetention() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("data/localops.sqlite3")
    let paths = LocalOpsPaths(applicationSupport: directory, database: database)
    try paths.prepare()
    XCTAssertEqual(try Self.permissions(at: database.deletingLastPathComponent()), 0o700)

    let store = try LocalOpsStore(path: database)
    XCTAssertEqual(try Self.permissions(at: database), 0o600)
    try await store.migrate()

    let old = Date().addingTimeInterval(-31 * 24 * 60 * 60)
    _ = try await store.commitRefresh(
      snapshots: [Self.snapshot(id: "old-event", checkedAt: old)],
      observed: [], attemptedAt: old, successfulAt: Date()
    )
    XCTAssertEqual(try Self.sqliteScalar(at: database, query: "SELECT COUNT(*) FROM events"), "0")

    let now = Date()
    let snapshots = (0...10_000).map { index in
      Self.snapshot(
        id: "retention-\(index)",
        checkedAt: now.addingTimeInterval(Double(index) / 1_000)
      )
    }
    _ = try await store.commitRefresh(
      snapshots: snapshots, observed: [], attemptedAt: now, successfulAt: now
    )
    let retention = try Self.sqliteScalar(
      at: database,
      query: "SELECT COUNT(*) || ':' || MIN(id) || ':' || MAX(id) FROM events"
    )
    let parts = retention.split(separator: ":").compactMap { Int64($0) }
    XCTAssertEqual(parts.count, 3)
    XCTAssertEqual(parts.first, 10_000, "event history is bounded to 10,000 rows")
    XCTAssertGreaterThanOrEqual((parts.last ?? 0) - (parts.dropFirst().first ?? 0), 9_999)
  }

  func testCommandRunnerTimeoutBackpressureAndOutputCap() throws {
    let runner = CommandRunner()
    let outputStart = Date()
    XCTAssertThrowsError(
      try runner.run(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "while :; do printf 'stdout-xxxxxxxxxxxxxxxx'; printf 'stderr-yyyyyyyyyyyyyyyy' >&2; done",
        ],
        timeoutSeconds: 2,
        maxOutputBytes: 32 * 1_024
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("输出超过"), "unexpected error: \(error)")
    }
    XCTAssertLessThan(
      Date().timeIntervalSince(outputStart), 3, "pipe backpressure must stay bounded")

    let timeoutStart = Date()
    XCTAssertThrowsError(
      try runner.run(
        executable: "/bin/sleep",
        arguments: ["10"],
        timeoutSeconds: 0.3,
        maxOutputBytes: 4 * 1_024
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("超时"), "unexpected error: \(error)")
    }
    XCTAssertLessThan(Date().timeIntervalSince(timeoutStart), 3, "timeout must terminate the child")
  }

  func testHealthProbeBoundsAndInvalidInputs() async throws {
    let checker = SystemHealthChecker(maxResponseBytes: 1_024)

    let invalidPort = await checker.probe(
      .init(type: .tcp, host: "127.0.0.1", port: 0, timeoutSeconds: 30)
    )
    XCTAssertEqual(invalidPort.health, .unknown)
    XCTAssertTrue(invalidPort.message?.contains("端口") == true)

    let nonLoopback = await checker.probe(
      .init(type: .tcp, host: "192.0.2.1", port: 9, timeoutSeconds: 30)
    )
    XCTAssertEqual(nonLoopback.health, .unknown)

    let invalidPID = await checker.probe(
      .init(type: .process, pid: Int(Int32.max) + 1)
    )
    XCTAssertEqual(invalidPID.health, .unknown)
    XCTAssertTrue(invalidPID.message?.contains("PID") == true)

    let redirectSession = Self.stubSession(
      status: 302,
      headers: ["Location": "http://example.com/should-not-be-requested"],
      body: Data()
    )
    let redirectChecker = SystemHealthChecker(session: redirectSession, maxResponseBytes: 1_024)
    let redirectStart = Date()
    let redirect = await redirectChecker.probe(
      .init(type: .http, url: "http://127.0.0.1/redirect", timeoutSeconds: 3)
    )
    XCTAssertEqual(redirect.statusCode, 302)
    XCTAssertNotEqual(redirect.health, .healthy, "redirects must not be treated as healthy")
    XCTAssertLessThan(Date().timeIntervalSince(redirectStart), 1)

    let hugeBody = Data(repeating: 0x41, count: 8 * 1_024)
    let bodySession = Self.stubSession(status: 200, headers: [:], body: hugeBody)
    let bodyChecker = SystemHealthChecker(session: bodySession, maxResponseBytes: 1_024)
    let bodyStart = Date()
    let oversized = await bodyChecker.probe(
      .init(type: .http, url: "http://127.0.0.1/huge", timeoutSeconds: 3)
    )
    XCTAssertEqual(oversized.health, .unhealthy)
    XCTAssertEqual(oversized.lifecycle, .stopped)
    XCTAssertEqual(oversized.freshness, .partial)
    XCTAssertLessThan(Date().timeIntervalSince(bodyStart), 1)
  }

  func testWebReadinessShutdownAndPortRelease() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = try LocalOpsEngine(
      paths: Self.paths(in: directory),
      discovery: ReliabilityScriptedDiscovery(steps: [.listeners([]), .failure]),
      healthChecker: ReliabilityHealthyChecker()
    )
    let web = try LocalWebServer(engine: engine, port: 0)
    guard case .running(let baseURL) = await web.start(), let port = baseURL.port else {
      XCTFail("web server did not start")
      return
    }
    let notReadyStatus = try await Self.httpStatus(baseURL.appendingPathComponent("readyz"))
    XCTAssertEqual(notReadyStatus, 503)

    _ = try await engine.initialize()
    let readyStatus = try await Self.httpStatus(baseURL.appendingPathComponent("readyz"))
    XCTAssertEqual(readyStatus, 200)

    let staleOverview = await engine.refresh()
    XCTAssertEqual(staleOverview.metadata.outcome, .failed)
    let staleStatus = try await Self.httpStatus(baseURL.appendingPathComponent("readyz"))
    XCTAssertEqual(staleStatus, 503, "stale snapshots must not report ready")

    let conflict = try LocalWebServer(engine: engine, port: UInt16(port))
    guard case .failed(let conflictMessage) = await conflict.start() else {
      XCTFail("a duplicate Web listener must fail instead of creating a second owner")
      await conflict.stop()
      return
    }
    XCTAssertTrue(
      conflictMessage.localizedCaseInsensitiveContains("端口")
        || conflictMessage.localizedCaseInsensitiveContains("占用")
        || conflictMessage.localizedCaseInsensitiveContains("in use")
        || conflictMessage.localizedCaseInsensitiveContains("address")
        || conflictMessage.localizedCaseInsensitiveContains("used"),
      "duplicate listener error was not actionable: \(conflictMessage)"
    )

    await web.stop()
    let stoppedState = await web.state()
    XCTAssertEqual(stoppedState, .stopped)

    // The App's retry action reuses the same failed server actor. Verify that
    // retrying that object, rather than constructing a replacement, really
    // reclaims the original fixed port and serves healthz.
    guard case .running(let retryURL) = await conflict.start() else {
      XCTFail("failed Web server did not recover on retry")
      await conflict.stop()
      return
    }
    XCTAssertEqual(retryURL.port, port)
    let retryHealthStatus = try await Self.httpStatus(
      retryURL.appendingPathComponent("healthz")
    )
    XCTAssertEqual(retryHealthStatus, 200)
    await conflict.stop()
  }

  func testMigrationMarkerIntegrityAndBackup() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("localops.sqlite3")
    let store = try LocalOpsStore(path: database)
    try await store.migrate()
    let ready = await store.isReady()
    XCTAssertTrue(ready)
    let markerInitiallyPresent = try await store.hasMigrationMarker("reliability-test")
    XCTAssertFalse(markerInitiallyPresent)
    try await store.markMigration("reliability-test")
    let markerPresent = try await store.hasMigrationMarker("reliability-test")
    XCTAssertTrue(markerPresent)
    try await store.markMigration("reliability-test")
    let markerStillPresent = try await store.hasMigrationMarker("reliability-test")
    XCTAssertTrue(markerStillPresent)

    let backup = directory.appendingPathComponent("preflight.sqlite3")
    try await store.backupIfNeeded(to: backup)
    XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    let backupSize =
      (try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? NSNumber)?.intValue
      ?? 0
    XCTAssertGreaterThan(backupSize, 0)
    XCTAssertEqual(try Self.permissions(at: backup), 0o600)
    XCTAssertEqual(
      try Self.sqliteScalar(at: database, query: "PRAGMA integrity_check;").lowercased(),
      "ok"
    )

    // Opening the backup through the same migrator verifies that the backup
    // is a complete SQLite image, not a copied main file missing WAL pages.
    let restoredPath = directory.appendingPathComponent("restored.sqlite3")
    try FileManager.default.copyItem(at: backup, to: restoredPath)
    let restoredStore = try LocalOpsStore(path: restoredPath)
    try await restoredStore.migrate()
    let restoredMarker = try await restoredStore.hasMigrationMarker("reliability-test")
    XCTAssertTrue(restoredMarker)
  }

  func testTwentyServiceProbeBudget() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = Self.paths(in: directory)
    let store = try LocalOpsStore(path: paths.database)
    try await store.migrate()

    let serviceIDs = (0..<20).map { "budget-\($0)" }
    for (index, id) in serviceIDs.enumerated() {
      try await store.saveDefinition(
        ServiceDefinition(
          id: id,
          name: "Budget \(index)",
          group: "性能",
          endpoints: [
            ServiceEndpoint(name: "入口", url: "http://127.0.0.1:\(20_000 + index)/")
          ],
          health: .init(type: .none)
        )
      )
    }

    let tracker = ReliabilityProbeBudgetTracker()
    let engine = try LocalOpsEngine(
      paths: paths,
      discovery: ReliabilityScriptedDiscovery(steps: [.listeners([])]),
      healthChecker: ReliabilityDelayedHealthChecker(
        tracker: tracker,
        delayNanoseconds: 100_000_000
      )
    )
    let startedAt = Date()
    let overview = try await engine.initialize()
    let elapsed = Date().timeIntervalSince(startedAt)
    let generatedIDs = Set(
      overview.services.filter { serviceIDs.contains($0.id) }.map(\.id)
    )

    XCTAssertEqual(generatedIDs, Set(serviceIDs), "all 20 configured services need snapshots")
    XCTAssertLessThan(elapsed, 5, "20-service probe budget exceeded 5 seconds")
    let maximumConcurrency = await tracker.maximumConcurrency()
    XCTAssertGreaterThanOrEqual(maximumConcurrency, 2, "probe work did not run concurrently")
    XCTAssertLessThanOrEqual(maximumConcurrency, 8, "probe concurrency exceeded the engine bound")
  }

  func testLegacyWALImportPreservesRowsAndDestinationSafety() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let legacy = directory.appendingPathComponent("cockpit.sqlite3")
    let database = directory.appendingPathComponent("localops.sqlite3")
    let session = try ReliabilitySQLiteSession(database: legacy)
    defer { session.stop() }
    try Self.waitForLegacyWALFixture(legacy)

    let wal = URL(fileURLWithPath: legacy.path + "-wal")
    XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path), "legacy WAL is missing")
    let walSize =
      (try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue
      ?? 0
    XCTAssertGreaterThan(walSize, 0, "the committed fixture row must remain in WAL")

    let paths = LocalOpsPaths(
      applicationSupport: directory,
      database: database,
      legacyDatabase: legacy
    )
    try paths.prepare()
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "legacy DB was removed")
    XCTAssertEqual(
      try Self.sqliteScalar(
        at: database,
        query: "SELECT value FROM legacy_rows WHERE id = 'wal-row';"
      ),
      "committed",
      "VACUUM INTO must include committed WAL rows"
    )
    XCTAssertEqual(
      try Self.sqliteScalar(at: database, query: "PRAGMA integrity_check;").lowercased(),
      "ok"
    )
    XCTAssertEqual(try Self.permissions(at: database), 0o600)

    let failedDirectory = directory.appendingPathComponent("failed", isDirectory: true)
    try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
    let invalidLegacy = failedDirectory.appendingPathComponent("cockpit.sqlite3")
    let failedDatabase = failedDirectory.appendingPathComponent("localops.sqlite3")
    let invalidBytes = Data("not-a-sqlite-database".utf8)
    try invalidBytes.write(to: invalidLegacy, options: .atomic)
    let failedPaths = LocalOpsPaths(
      applicationSupport: failedDirectory,
      database: failedDatabase,
      legacyDatabase: invalidLegacy
    )
    XCTAssertThrowsError(try failedPaths.prepare())
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: failedDatabase.path),
      "failed import must not leave a destination"
    )
    XCTAssertEqual(try Data(contentsOf: invalidLegacy), invalidBytes, "legacy DB was altered")

    let existingDirectory = directory.appendingPathComponent("existing", isDirectory: true)
    try FileManager.default.createDirectory(
      at: existingDirectory,
      withIntermediateDirectories: true
    )
    let existingLegacy = existingDirectory.appendingPathComponent("cockpit.sqlite3")
    let existingDatabase = existingDirectory.appendingPathComponent("localops.sqlite3")
    let sentinel = Data("existing-destination".utf8)
    try sentinel.write(to: existingDatabase, options: .atomic)
    try Data("legacy-source".utf8).write(to: existingLegacy, options: .atomic)
    let existingPaths = LocalOpsPaths(
      applicationSupport: existingDirectory,
      database: existingDatabase,
      legacyDatabase: existingLegacy
    )
    try existingPaths.prepare()
    XCTAssertEqual(
      try Data(contentsOf: existingDatabase), sentinel,
      "an existing destination must never be overwritten"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: existingLegacy.path))
  }

  func testValidatedDefinitionLoopbackURLBoundaries() {
    let acceptedHosts = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
    var caseNumber = 0
    for host in acceptedHosts {
      let urlHost = host.contains(":") ? "[\(host)]" : host
      for scheme in ["http", "https"] {
        let url = "\(scheme)://\(urlHost):19999/health"
        let definition = ServiceDefinition(
          id: "accepted-\(caseNumber)",
          name: "Accepted \(caseNumber)",
          endpoints: [ServiceEndpoint(name: "入口", url: url)],
          health: .init(type: .http, url: url, host: host, timeoutSeconds: 1)
        )
        XCTAssertNoThrow(try definition.validated(), "valid \(scheme) URL rejected: \(url)")
        caseNumber += 1
      }

      let tcp = ServiceDefinition(
        id: "accepted-tcp-\(caseNumber)",
        name: "Accepted TCP \(caseNumber)",
        health: .init(type: .tcp, host: host, port: 19_999, timeoutSeconds: 1)
      )
      XCTAssertNoThrow(try tcp.validated(), "valid TCP host rejected: \(host)")
      caseNumber += 1
    }

    let rejectedEntrypoints = [
      "file:///tmp/localops",
      "javascript:alert(1)",
      "http://user:password@localhost:19999/health",
      "http://192.168.1.20:19999/health",
      "https://8.8.8.8:19999/health",
      "http://169.254.169.254:19999/latest",
    ]
    for (index, url) in rejectedEntrypoints.enumerated() {
      let definition = ServiceDefinition(
        id: "rejected-entrypoint-\(index)",
        name: "Rejected entrypoint \(index)",
        endpoints: [ServiceEndpoint(name: "入口", url: url)]
      )
      XCTAssertThrowsError(try definition.validated(), "unsafe entrypoint accepted: \(url)")
    }

    let rejectedHealthHosts = ["192.168.1.20", "8.8.8.8", "169.254.169.254", "example.com"]
    for (index, host) in rejectedHealthHosts.enumerated() {
      let tcp = ServiceDefinition(
        id: "rejected-tcp-\(index)",
        name: "Rejected TCP \(index)",
        health: .init(type: .tcp, host: host, port: 19_999, timeoutSeconds: 1)
      )
      XCTAssertThrowsError(try tcp.validated(), "non-loopback TCP host accepted: \(host)")

      let httpHost = host.contains(":") ? "[\(host)]" : host
      let httpURL = "http://\(httpHost):19999/health"
      let http = ServiceDefinition(
        id: "rejected-http-\(index)",
        name: "Rejected HTTP \(index)",
        health: .init(type: .http, url: httpURL, host: host, timeoutSeconds: 1)
      )
      XCTAssertThrowsError(try http.validated(), "non-loopback HTTP host accepted: \(host)")
    }
  }

  func testSnapshotProjectionReadinessTable() {
    let now = Date(timeIntervalSince1970: 1_000)
    let service = Self.snapshot(id: "projection", checkedAt: now)
    let cases: [(String, LocalOpsOverview, Date, TimeInterval, LocalOpsSnapshotState, Bool)] = [
      (
        "starting",
        LocalOpsOverview.empty,
        now,
        10,
        .starting,
        false
      ),
      (
        "core-error",
        Self.overview(
          services: [],
          metadata: SnapshotMetadata(
            generation: 0,
            attemptedAt: now,
            successfulAt: nil,
            freshness: .unknown,
            outcome: .failed,
            error: "数据库不可用"
          )
        ),
        now,
        10,
        .coreError,
        false
      ),
      (
        "empty",
        Self.overview(
          services: [],
          metadata: SnapshotMetadata(
            generation: 1,
            attemptedAt: now,
            successfulAt: now,
            freshness: .fresh,
            outcome: .success
          )
        ),
        now,
        10,
        .empty,
        true
      ),
      (
        "fresh",
        Self.overview(
          services: [service],
          metadata: SnapshotMetadata(
            generation: 1,
            attemptedAt: now,
            successfulAt: now,
            freshness: .fresh,
            outcome: .success
          )
        ),
        now,
        10,
        .fresh,
        true
      ),
      (
        "partial",
        Self.overview(
          services: [service],
          metadata: SnapshotMetadata(
            generation: 1,
            attemptedAt: now,
            successfulAt: now,
            freshness: .partial,
            outcome: .partial
          )
        ),
        now,
        10,
        .partial,
        true
      ),
      (
        "failed-old",
        Self.overview(
          services: [service],
          metadata: SnapshotMetadata(
            generation: 1,
            attemptedAt: now,
            successfulAt: now.addingTimeInterval(-2),
            freshness: .stale,
            outcome: .failed,
            error: "扫描失败"
          )
        ),
        now,
        10,
        .stale,
        false
      ),
      (
        "age-equal-threshold",
        Self.overview(
          services: [service],
          metadata: SnapshotMetadata(
            generation: 1,
            attemptedAt: now.addingTimeInterval(-10),
            successfulAt: now.addingTimeInterval(-10),
            freshness: .fresh,
            outcome: .success
          )
        ),
        now,
        10,
        .fresh,
        true
      ),
      (
        "age-over-threshold",
        Self.overview(
          services: [service],
          metadata: SnapshotMetadata(
            generation: 1,
            attemptedAt: now.addingTimeInterval(-11),
            successfulAt: now.addingTimeInterval(-11),
            freshness: .fresh,
            outcome: .success
          )
        ),
        now,
        10,
        .stale,
        false
      ),
      (
        "invalid-threshold-uses-safe-default",
        Self.overview(
          services: [service],
          metadata: SnapshotMetadata(
            generation: 1,
            attemptedAt: now.addingTimeInterval(-20),
            successfulAt: now.addingTimeInterval(-20),
            freshness: .fresh,
            outcome: .success
          )
        ),
        now,
        .nan,
        .fresh,
        true
      ),
    ]

    for (name, overview, timestamp, threshold, expectedState, expectedReady) in cases {
      let projection = overview.snapshotProjection(now: timestamp, staleAfter: threshold)
      XCTAssertEqual(projection.state, expectedState, name)
      XCTAssertEqual(projection.ready, expectedReady, name)
    }

    let unknown = Self.overview(
      services: [service],
      metadata: SnapshotMetadata(
        generation: 1,
        attemptedAt: now,
        successfulAt: now,
        freshness: .unknown,
        outcome: .success
      )
    )
    let unknownProjection = unknown.snapshotProjection(now: now, staleAfter: 10)
    XCTAssertEqual(unknownProjection.state, .partial)
    XCTAssertFalse(unknownProjection.ready, "unknown freshness must never be ready")
  }

  func testHealthCheckerDefaultResponseAndRedactionBounds() async throws {
    let exactBody = Data(repeating: 0x41, count: 64 * 1_024)
    let exactChecker = SystemHealthChecker(
      session: Self.stubSession(
        status: 200,
        headers: ["Content-Type": "text/plain"],
        body: exactBody
      ))
    let exact = await exactChecker.probe(
      .init(type: .http, url: "http://127.0.0.1/exact", timeoutSeconds: 1)
    )
    XCTAssertEqual(exact.health, .healthy, "64 KiB must be accepted")

    let oversizedChecker = SystemHealthChecker(
      session: Self.stubSession(
        status: 200,
        headers: ["Content-Type": "text/plain"],
        body: Data(repeating: 0x42, count: 64 * 1_024 + 1)
      ))
    let oversized = await oversizedChecker.probe(
      .init(type: .http, url: "http://127.0.0.1/oversized", timeoutSeconds: 1)
    )
    XCTAssertEqual(oversized.health, .unhealthy, "64 KiB + 1 must be rejected")
    XCTAssertTrue(oversized.message?.contains("上限") == true)

    let payload: [String: Any] = [
      "status": "ok",
      "password": "do-not-leak",
      "token": "secret-token",
      "api_key": "secret-key",
      "message": String(repeating: "多字节状态", count: 2_000),
    ]
    let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let checker = SystemHealthChecker(
      session: Self.stubSession(
        status: 200,
        headers: ["Content-Type": "application/json; charset=utf-8"],
        body: json
      ))
    let result = await checker.probe(
      .init(type: .http, url: "http://127.0.0.1/json", timeoutSeconds: 1)
    )
    XCTAssertEqual(result.health, .healthy)
    guard let summary = result.responseSummary else {
      XCTFail("JSON response summary missing")
      return
    }
    XCTAssertLessThanOrEqual(summary.utf8.count, 2_048)
    XCTAssertNotNil(String(data: Data(summary.utf8), encoding: .utf8))
    XCTAssertFalse(summary.contains("do-not-leak"))
    XCTAssertFalse(summary.contains("secret-token"))
    XCTAssertFalse(summary.contains("secret-key"))
    XCTAssertTrue(summary.contains("<redacted>"))
  }

  func testCommandRunnerCancellationTerminatesLongProcess() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("command.pid")
    let runner = CommandRunner()
    let task = Task {
      try runner.run(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "echo $$ > \(pidFile.path); exec /bin/sleep 30",
        ],
        timeoutSeconds: 10,
        maxOutputBytes: 4 * 1_024
      )
    }

    let pid = try await Self.waitForPIDFile(pidFile)
    let cancellationStarted = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("cancelled command unexpectedly completed")
    } catch is CancellationError {
      // Expected cancellation path.
    } catch {
      XCTFail("unexpected cancellation error: \(error)")
    }
    XCTAssertLessThan(
      Date().timeIntervalSince(cancellationStarted), 2,
      "cancellation must terminate the command promptly"
    )
    try await Self.waitForProcessExit(pid)
  }

  func testInitialDiscoveryFailureThrowsAndNextRefreshRecovers() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = try LocalOpsEngine(
      paths: Self.paths(in: directory),
      discovery: ReliabilityScriptedDiscovery(steps: [.failure, .listeners([])]),
      healthChecker: ReliabilityHealthyChecker()
    )

    do {
      _ = try await engine.initialize()
      XCTFail("initial discovery failure unexpectedly initialized")
    } catch {
      // A first refresh cannot claim readiness when discovery failed.
    }
    let failed = await engine.overview()
    XCTAssertFalse(failed.snapshotProjection().ready)
    XCTAssertEqual(failed.metadata.outcome, .failed)
    XCTAssertEqual(failed.metadata.freshness, .unknown)

    let recovered = await engine.refresh()
    XCTAssertTrue(recovered.snapshotProjection().ready)
    XCTAssertEqual(recovered.metadata.outcome, .success)
    XCTAssertGreaterThan(recovered.metadata.generation, 0)
  }

  func testEnabledPortConflictsAreAtomicAndDisabledDefinitionsRemainReadable() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("localops.sqlite3")
    let store = try LocalOpsStore(path: database)
    try await store.migrate()

    let owner = Self.definition(id: "owner", name: "Owner", port: 19_901)
    let conflict = Self.definition(id: "conflict", name: "Conflict", port: 19_901)
    try await store.saveDefinition(owner)
    do {
      try await store.saveDefinition(conflict)
      XCTFail("enabled duplicate port unexpectedly saved")
    } catch {
      // Expected conflict; the owner remains the only persisted definition.
    }
    let afterConflict = try await store.definitions()
    XCTAssertEqual(afterConflict.map(\.id), ["owner"])

    var disabled = conflict
    disabled.enabled = false
    try await store.saveDefinition(disabled)
    let withDisabled = try await store.definitions()
    XCTAssertEqual(withDisabled.map(\.id), ["conflict", "owner"])

    disabled.enabled = true
    do {
      try await store.updateDefinition(disabled)
      XCTFail("re-enabling duplicate port unexpectedly succeeded")
    } catch {
      // Expected conflict; the disabled record must remain unchanged.
    }
    let persistedDisabled = try await store.loadDefinition(id: "conflict")
    XCTAssertEqual(persistedDisabled?.enabled, false, "failed update must not half-write")
    let persistedOwner = try await store.loadDefinition(id: "owner")
    XCTAssertEqual(persistedOwner?.name, "Owner")
  }

  func testLegacyImportMarkerAndDefinitionsRollbackTogether() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("localops.sqlite3")
    let store = try LocalOpsStore(path: database)
    try await store.migrate()

    let first = Self.definition(id: "legacy-first", name: "Legacy First", port: 19_911)
    let duplicatePort = Self.definition(id: "legacy-second", name: "Legacy Second", port: 19_911)
    do {
      try await store.importLegacyDefinitions([first, duplicatePort], marker: "legacy-atomic")
      XCTFail("conflicting legacy import unexpectedly succeeded")
    } catch {
      // The marker and every definition must roll back together.
    }
    let rolledBackMarker = try await store.hasMigrationMarker("legacy-atomic")
    let rolledBackDefinitions = try await store.definitions()
    XCTAssertFalse(rolledBackMarker)
    XCTAssertTrue(rolledBackDefinitions.isEmpty)

    let second = Self.definition(id: "legacy-second", name: "Legacy Second", port: 19_912)
    try await store.importLegacyDefinitions([first, second], marker: "legacy-atomic")
    let importedMarker = try await store.hasMigrationMarker("legacy-atomic")
    XCTAssertTrue(importedMarker)
    let importedIDs = try await store.definitions().map(\.id)
    XCTAssertEqual(importedIDs, ["legacy-first", "legacy-second"])

    let malformed = directory.appendingPathComponent("services.yaml")
    try "services: [broken".write(to: malformed, atomically: true, encoding: .utf8)
    let malformedReport = LegacyServiceMigrator().loadReport(from: [malformed])
    XCTAssertFalse(malformedReport.errors.isEmpty, "broken services document was ignored")

    let empty = directory.appendingPathComponent("empty.yaml")
    let comments = directory.appendingPathComponent("comments.yaml")
    let claimed = directory.appendingPathComponent("claimed.yaml")
    try "".write(to: empty, atomically: true, encoding: .utf8)
    try "# old claimed format\n# no services here\n".write(
      to: comments,
      atomically: true,
      encoding: .utf8
    )
    try "claimed:\n  - service: legacy\n    port: 19913\n".write(
      to: claimed,
      atomically: true,
      encoding: .utf8
    )
    let shapeReport = LegacyServiceMigrator().loadReport(from: [empty, comments, claimed])
    XCTAssertTrue(shapeReport.definitions.isEmpty)
    XCTAssertTrue(shapeReport.errors.isEmpty, "claimed/empty legacy shapes were misclassified")
  }

  func testCorruptCurrentDatabaseFailsWithoutOverwritingBytes() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("localops.sqlite3")
    let original = Data("not-a-valid-sqlite-image".utf8)
    try original.write(to: database, options: .atomic)
    let paths = LocalOpsPaths(applicationSupport: directory, database: database)

    XCTAssertThrowsError(
      try LocalOpsEngine(
        paths: paths,
        discovery: ReliabilityScriptedDiscovery(steps: [.listeners([])]),
        healthChecker: ReliabilityHealthyChecker()
      )
    )
    XCTAssertEqual(try Data(contentsOf: database), original)
  }

  func testExclusiveSQLiteLockKeepsSnapshotStaleWithoutFakeOfflineAndRecovers() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = Self.paths(in: directory)
    let engine = try LocalOpsEngine(
      paths: paths,
      discovery: ReliabilityScriptedDiscovery(steps: [.listeners([]), .listeners([])]),
      healthChecker: ReliabilityHealthyChecker()
    )
    let initial = try await engine.initialize()
    XCTAssertTrue(initial.snapshotProjection().ready)
    XCTAssertEqual(initial.summary.offlineHistory, 0)

    let marker = directory.appendingPathComponent("sqlite-locked.marker")
    let lock = try ReliabilitySQLiteLock(database: paths.database, marker: marker)
    defer { lock.stop() }
    try await Self.waitForMarker(marker, expected: "LOCKED")

    let locked = await engine.refresh()
    XCTAssertEqual(locked.services, initial.services, "SQLite lock must retain the old snapshot")
    XCTAssertEqual(locked.metadata.outcome, .failed)
    XCTAssertEqual(locked.metadata.freshness, .stale)
    XCTAssertEqual(locked.summary.offlineHistory, 0, "a lock must not fake offline history")

    lock.stop()
    let recovered = await engine.refresh()
    XCTAssertEqual(recovered.metadata.outcome, .success)
    XCTAssertTrue(recovered.snapshotProjection().ready)
    XCTAssertEqual(recovered.summary.offlineHistory, 0)
  }

  func testClearCurrentDirectoryDataResetsCatalogKeepsRollbackSourcesAndReseedsDefaults()
    async throws
  {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appendingPathComponent("services.yaml")
    try """
    version: 1
    services:
      - id: legacy-clear
        name: Legacy Clear
        endpoints:
          - name: 入口
            url: http://127.0.0.1:19922/
        health:
          type: tcp
          host: 127.0.0.1
          port: 19922
    """.write(to: legacy, atomically: true, encoding: .utf8)

    let listener = ListeningService(
      pid: 701,
      processName: "clear-server",
      host: "127.0.0.1",
      port: 19_921,
      address: "127.0.0.1:19921",
      executablePath: "/tmp/clear-server"
    )
    let paths = LocalOpsPaths(
      applicationSupport: directory,
      database: directory.appendingPathComponent("localops.sqlite3"),
      legacyServices: [legacy]
    )
    let engine = try LocalOpsEngine(
      paths: paths,
      discovery: ReliabilityScriptedDiscovery(steps: [.listeners([listener]), .listeners([])]),
      healthChecker: ReliabilityHealthyChecker()
    )
    let initial = try await engine.initialize()
    XCTAssertTrue(initial.snapshotProjection().ready)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: paths.database.appendingPathExtension("preflight.sqlite3").path
      ))

    let sidecarStore = try LocalOpsStore(path: paths.database)
    let custom = Self.definition(id: "clear-custom", name: "Clear Custom", port: 19_921)
    try await sidecarStore.saveDefinition(custom)
    _ = try await sidecarStore.commitRefresh(
      snapshots: [
        Self.snapshot(
          id: custom.id,
          lifecycle: .stopped,
          health: .unhealthy,
          checkedAt: Date()
        )
      ],
      observed: [listener],
      attemptedAt: Date(),
      successfulAt: Date()
    )
    try Self.sqliteExecute(
      at: paths.database,
      sql: """
        INSERT INTO action_audit
          (occurred_at, request_id, service_id, service_name, manager, action, succeeded, message)
        VALUES (datetime('now'), 'clear-request', 'clear-custom', 'Clear Custom', 'manual',
                'test', 1, 'before clear');
        """
    )
    XCTAssertEqual(
      try Self.sqliteScalar(
        at: paths.database,
        query: "SELECT COUNT(*) FROM action_audit"
      ), "1")

    let beforeGeneration = initial.metadata.generation
    XCTAssertGreaterThan(beforeGeneration, 0)
    let markerBeforeClear = try await sidecarStore.hasMigrationMarker("legacy-services-v1")
    XCTAssertTrue(markerBeforeClear)

    let cleared = try await engine.clearCurrentDirectoryData()
    XCTAssertEqual(cleared.metadata.generation, 1, "clear must reset then create one new snapshot")
    XCTAssertTrue(cleared.snapshotProjection().ready)

    let defaults = try LocalOpsEngine.loadDefaultDefinitions().map(\.id)
    let currentDefinitions = try await sidecarStore.definitions()
    XCTAssertEqual(Set(currentDefinitions.map(\.id)), Set(defaults))
    XCTAssertEqual(
      currentDefinitions.map(\.id),
      currentDefinitions.sorted {
        ($0.group, $0.name, $0.id) < ($1.group, $1.name, $1.id)
      }.map(\.id)
    )
    XCTAssertFalse(currentDefinitions.contains { $0.id == custom.id })
    let markerAfterClear = try await sidecarStore.hasMigrationMarker("legacy-services-v1")
    XCTAssertTrue(markerAfterClear)
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "legacy source was removed")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: paths.database.appendingPathExtension("preflight.sqlite3").path
      ))
    XCTAssertEqual(try Self.permissions(at: paths.database), 0o600)
    XCTAssertEqual(
      try Self.sqliteScalar(at: paths.database, query: "PRAGMA integrity_check;").lowercased(),
      "ok"
    )
    XCTAssertEqual(
      try Self.sqliteScalar(
        at: paths.database,
        query: "SELECT COUNT(*) FROM events WHERE service_id = 'clear-custom'"
      ), "0")
    XCTAssertEqual(
      try Self.sqliteScalar(
        at: paths.database,
        query: "SELECT COUNT(*) FROM service_failure_state WHERE service_id = 'clear-custom'"
      ), "0")
    XCTAssertEqual(
      try Self.sqliteScalar(
        at: paths.database,
        query: "SELECT COUNT(*) FROM action_audit"
      ), "0")
    XCTAssertEqual(
      try Self.sqliteScalar(
        at: paths.database,
        query: "SELECT COUNT(*) FROM service_catalog WHERE id = '\(listener.stableId)'"
      ), "0")
  }

  func testPIDReuseChangesIdentityAndAmbiguousPortNeverClaimsPID() {
    let first = ListeningService(
      pid: 811,
      processName: "server",
      host: "127.0.0.1",
      port: 19_931,
      address: "127.0.0.1:19931",
      executablePath: "/opt/old/server"
    )
    let reusedPID = ListeningService(
      pid: 811,
      processName: "server",
      host: "127.0.0.1",
      port: 19_931,
      address: "127.0.0.1:19931",
      executablePath: "/opt/new/server"
    )
    XCTAssertNotEqual(first.stableId, reusedPID.stableId, "PID reuse must not retain identity")

    let secondProcess = ListeningService(
      pid: 812,
      processName: "other-server",
      host: "127.0.0.1",
      port: 19_931,
      address: "127.0.0.1:19931",
      executablePath: "/opt/other/server"
    )
    let match = matchListenerDetailed(
      ports: [19_931],
      listeners: [first, secondProcess],
      hosts: ["127.0.0.1"]
    )
    guard case .ambiguous = match else {
      XCTFail("same host+port listeners must remain ambiguous")
      return
    }
    XCTAssertNil(
      matchListener(
        ports: [19_931],
        listeners: [first, secondProcess],
        hosts: ["127.0.0.1"]
      ),
      "ambiguous port attribution must not claim a PID"
    )
  }

  func testObservationCompatibilityConfidenceFingerprintsAndTypedValidation() async throws {
    let oldJSON = Data(
      """
      {"state":"observed","freshness":"fresh","host":"127.0.0.1","port":19941,"pid":811,"processName":"server","executablePath":"/opt/server"}
      """.utf8
    )
    let oldObservation = try JSONDecoder().decode(ObservationEvidence.self, from: oldJSON)
    XCTAssertNil(oldObservation.processFingerprint)
    XCTAssertEqual(oldObservation.matchConfidence, .none)

    let sameIdentity = ListeningService(
      pid: 901,
      processName: "server",
      host: "127.0.0.1",
      port: 19_941,
      address: "127.0.0.1:19941",
      executablePath: "/opt/server"
    )
    var reusedPID = sameIdentity
    reusedPID.pid = 902
    var differentExecutable = sameIdentity
    differentExecutable.executablePath = "/opt/other-server"
    XCTAssertEqual(sameIdentity.processFingerprint, reusedPID.processFingerprint)
    XCTAssertNotEqual(sameIdentity.processFingerprint, differentExecutable.processFingerprint)
    XCTAssertFalse(sameIdentity.processFingerprint.contains("901"))
    XCTAssertFalse(sameIdentity.processFingerprint.contains("902"))

    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = Self.paths(in: directory)
    let sidecarStore = try LocalOpsStore(path: paths.database)
    try await sidecarStore.migrate()
    try await sidecarStore.saveDefinition(
      ServiceDefinition(
        id: "matched",
        name: "Matched",
        endpoints: [ServiceEndpoint(name: "入口", url: "http://127.0.0.1:19941/")],
        health: .init(type: .none)
      ))
    try await sidecarStore.saveDefinition(
      ServiceDefinition(
        id: "ambiguous",
        name: "Ambiguous",
        endpoints: [ServiceEndpoint(name: "入口", url: "http://127.0.0.1:19942/")],
        health: .init(type: .none)
      ))
    let ambiguousA = ListeningService(
      pid: 903,
      processName: "ambiguous-a",
      host: "127.0.0.1",
      port: 19_942,
      address: "127.0.0.1:19942",
      executablePath: "/opt/a"
    )
    let ambiguousB = ListeningService(
      pid: 904,
      processName: "ambiguous-b",
      host: "127.0.0.1",
      port: 19_942,
      address: "127.0.0.1:19942",
      executablePath: "/opt/b"
    )
    let engine = try LocalOpsEngine(
      paths: paths,
      discovery: ReliabilityScriptedDiscovery(steps: [
        .listeners([sameIdentity, ambiguousA, ambiguousB])
      ]),
      healthChecker: ReliabilityHealthyChecker()
    )
    let overview = try await engine.initialize()
    let matched = try XCTUnwrap(overview.services.first { $0.id == "matched" })
    XCTAssertEqual(matched.observation.matchConfidence, .hostPort)
    XCTAssertEqual(matched.observation.processFingerprint, sameIdentity.processFingerprint)
    let ambiguous = try XCTUnwrap(overview.services.first { $0.id == "ambiguous" })
    XCTAssertEqual(ambiguous.observation.matchConfidence, .ambiguous)
    XCTAssertNil(ambiguous.observation.processFingerprint)

    let noneWithStaleFields = ServiceDefinition(
      id: "none-health",
      name: "None Health",
      health: .init(
        type: .none, url: "file:///ignored", host: "public.example", port: 19_943, pid: 999)
    )
    XCTAssertNoThrow(try noneWithStaleFields.validated())
    XCTAssertTrue(noneWithStaleFields.ports.isEmpty)
    let processWithStalePort = ServiceDefinition(
      id: "process-health",
      name: "Process Health",
      health: .init(type: .process, host: "public.example", port: 19_944, pid: 999)
    )
    XCTAssertNoThrow(try processWithStalePort.validated())
    XCTAssertTrue(processWithStalePort.ports.isEmpty)
    let endpointWithNoneHealth = ServiceDefinition(
      id: "endpoint-health",
      name: "Endpoint Health",
      endpoints: [ServiceEndpoint(name: "入口", url: "http://127.0.0.1:19945/")],
      health: .init(type: .none, port: 19_946)
    )
    XCTAssertNoThrow(try endpointWithNoneHealth.validated())
    XCTAssertEqual(endpointWithNoneHealth.ports, [19_945])

    XCTAssertThrowsError(
      try ServiceDefinition(
        id: "missing-http",
        name: "Missing HTTP",
        health: .init(type: .http)
      ).validated()
    )
    XCTAssertThrowsError(
      try ServiceDefinition(
        id: "missing-tcp",
        name: "Missing TCP",
        health: .init(type: .tcp, host: "127.0.0.1")
      ).validated()
    )
    XCTAssertThrowsError(
      try ServiceDefinition(
        id: "missing-process",
        name: "Missing Process",
        health: .init(type: .process)
      ).validated()
    )
  }

  func testWebAgeReadinessThresholdUpdatesAndGETOnlyDoesNotScan() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = ReliabilityDiscoveryCounter()
    let paths = Self.paths(in: directory)
    let sensitiveNote = "RECOVERY_NOTE_PRIVATE_\(UUID().uuidString)"
    let setupStore = try LocalOpsStore(path: paths.database)
    try await setupStore.migrate()
    try await setupStore.saveDefinition(
      ServiceDefinition(
        id: "privacy-fixture",
        name: "Privacy Fixture",
        description: "A service used to verify read-only API privacy.",
        health: .init(type: .none),
        recoveryNote: sensitiveNote
      )
    )
    let engine = try LocalOpsEngine(
      paths: paths,
      discovery: ReliabilityCountingDiscovery(counter: counter, listeners: []),
      healthChecker: ReliabilityHealthyChecker()
    )
    _ = try await engine.initialize()
    let scansAfterInitialize = await counter.value()
    XCTAssertEqual(scansAfterInitialize, 1)
    let definitionsBefore = try await engine.definitions()
    let overviewBefore = await engine.overview()
    let eventsBefore = overviewBefore.events

    let web = try LocalWebServer(engine: engine, port: 0, staleAfter: 3_600)
    guard case .running(let baseURL) = await web.start() else {
      XCTFail("web server did not start")
      return
    }
    defer { Task { await web.stop() } }

    let readyURL = baseURL.appendingPathComponent("readyz")
    let initialResponse = try await Self.httpRequest(readyURL, method: "GET")
    XCTAssertEqual(initialResponse.status, 200)
    let initialPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: initialResponse.data) as? [String: Any]
    )
    XCTAssertEqual(initialPayload["ready"] as? Bool, true)
    XCTAssertNotNil(initialPayload["age_seconds"] as? NSNumber)
    XCTAssertEqual(initialPayload["stale_after_seconds"] as? NSNumber, 3_600)

    let initialOverviewResponse = try await Self.httpRequest(
      baseURL.appendingPathComponent("api/v1/overview"),
      method: "GET"
    )
    XCTAssertEqual(initialOverviewResponse.status, 200)
    let initialOverviewPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: initialOverviewResponse.data) as? [String: Any]
    )
    let initialTypedState = try XCTUnwrap(
      initialOverviewPayload["typed_state"] as? [String: Any]
    )
    XCTAssertEqual(initialTypedState["stale_after_seconds"] as? NSNumber, 3_600)

    await web.setStaleAfter(1)
    let staleStatus = try await Self.waitForHTTPStatus(
      readyURL,
      expected: 503,
      timeout: 3
    )
    XCTAssertEqual(staleStatus, 503)
    let staleResponse = try await Self.httpRequest(readyURL, method: "GET")
    let stalePayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: staleResponse.data) as? [String: Any]
    )
    XCTAssertEqual(stalePayload["ready"] as? Bool, false)
    XCTAssertEqual(stalePayload["state"] as? String, "stale")
    XCTAssertEqual(stalePayload["stale_after_seconds"] as? NSNumber, 1)

    let staleOverviewResponse = try await Self.httpRequest(
      baseURL.appendingPathComponent("api/v1/overview"),
      method: "GET"
    )
    let staleOverviewPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: staleOverviewResponse.data) as? [String: Any]
    )
    let staleTypedState = try XCTUnwrap(staleOverviewPayload["typed_state"] as? [String: Any])
    XCTAssertEqual(staleTypedState["stale_after_seconds"] as? NSNumber, 1)

    await web.setStaleAfter(3_600)
    let recoveredStatus = try await Self.waitForHTTPStatus(
      readyURL,
      expected: 200,
      timeout: 1
    )
    XCTAssertEqual(recoveredStatus, 200)

    // Every read-only route, including the service detail endpoint, must
    // preserve the snapshot without exposing the local recovery note.
    let readOnlyPaths = [
      "",
      "healthz",
      "api/v1/overview",
      "api/v1/services",
      "api/v1/services/privacy-fixture",
      "api/v1/events",
      "static/localops.css",
      "static/localops.js",
    ]
    for path in readOnlyPaths {
      let response = try await Self.httpRequest(
        baseURL.appendingPathComponent(path),
        method: "GET"
      )
      XCTAssertEqual(response.status, 200, "read-only route failed: GET /\(path)")
      let body = String(decoding: response.data, as: UTF8.self)
      XCTAssertFalse(
        body.contains(sensitiveNote), "recovery note leaked on GET /\(path)"
      )
      XCTAssertFalse(
        body.contains("recoveryNote"), "camel-case recovery key leaked on GET /\(path)"
      )
      XCTAssertFalse(
        body.contains("recovery_note"), "snake-case recovery key leaked on GET /\(path)"
      )
    }

    for path in readOnlyPaths {
      for method in ["POST", "PUT", "PATCH", "DELETE"] {
        let response = try await Self.httpRequest(
          baseURL.appendingPathComponent(path),
          method: method
        )
        XCTAssertEqual(response.status, 404, "mutating route exposed: \(method) /\(path)")
      }
    }

    let scansAfterGET = await counter.value()
    XCTAssertEqual(scansAfterGET, scansAfterInitialize, "GET API triggered discovery")
    let definitionsAfter = try await engine.definitions()
    XCTAssertEqual(definitionsAfter, definitionsBefore)
    let overviewAfter = await engine.overview()
    XCTAssertEqual(overviewAfter.metadata.generation, overviewBefore.metadata.generation)
    XCTAssertEqual(overviewAfter.events, eventsBefore)
    await web.stop()
  }

  // MARK: - Helpers

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalOpsReliability-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func paths(in directory: URL) -> LocalOpsPaths {
    LocalOpsPaths(
      applicationSupport: directory,
      database: directory.appendingPathComponent("localops.sqlite3")
    )
  }

  private static func snapshot(
    id: String,
    lifecycle: ServiceLifecycle = .running,
    health: ServiceHealth = .healthy,
    checkedAt: Date = Date()
  ) -> ServiceSnapshot {
    ServiceSnapshot(
      id: id,
      name: id,
      group: "测试",
      description: "可靠性测试",
      source: .registered,
      lifecycle: lifecycle,
      health: health,
      endpoints: [ServiceEndpoint(name: "入口", url: "http://127.0.0.1:19001/")],
      checkedAt: checkedAt,
      presence: lifecycle == .running ? .online : .offline,
      observation: ObservationEvidence(
        state: .notObserved,
        freshness: .fresh,
        observedAt: checkedAt
      )
    )
  }

  private static func overview(
    services: [ServiceSnapshot],
    metadata: SnapshotMetadata
  ) -> LocalOpsOverview {
    LocalOpsOverview(
      services: services,
      summary: .empty,
      system: .empty,
      groups: [],
      events: [],
      refreshedAt: metadata.successfulAt,
      error: metadata.error,
      metadata: metadata
    )
  }

  private static func definition(
    id: String,
    name: String,
    port: Int,
    enabled: Bool = true
  ) -> ServiceDefinition {
    ServiceDefinition(
      id: id,
      name: name,
      enabled: enabled,
      endpoints: [ServiceEndpoint(name: "入口", url: "http://127.0.0.1:\(port)/")],
      health: .init(type: .tcp, host: "127.0.0.1", port: port, timeoutSeconds: 1)
    )
  }

  private static func permissions(at url: URL) throws -> Int {
    let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    guard let number = value as? NSNumber else {
      throw LocalOpsError.commandFailed("无法读取权限：\(url.path)")
    }
    return number.intValue & 0o777
  }

  private static func waitForPIDFile(_ url: URL) async throws -> pid_t {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let text = try? String(contentsOf: url, encoding: .utf8),
        let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        value > 0
      {
        return pid_t(value)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw LocalOpsError.commandFailed("命令 PID fixture 未就绪")
  }

  private static func waitForProcessExit(_ pid: pid_t) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      errno = 0
      if kill(pid, 0) != 0, errno == ESRCH { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw LocalOpsError.commandFailed("取消后命令进程仍在运行：\(pid)")
  }

  private static func waitForMarker(_ url: URL, expected: String) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let value = try? String(contentsOf: url, encoding: .utf8),
        value.trimmingCharacters(in: .whitespacesAndNewlines) == expected
      {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw LocalOpsError.commandFailed("SQLite lock fixture 未就绪")
  }

  private static func sqliteScalar(at database: URL, query: String) throws -> String {
    let candidates = ["/usr/bin/sqlite3", "/bin/sqlite3"]
    guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    else {
      throw LocalOpsError.commandFailed("测试机缺少 sqlite3 CLI")
    }
    let result = try CommandRunner().run(
      executable: executable,
      arguments: [database.path, query],
      timeoutSeconds: 5,
      maxOutputBytes: 128 * 1_024
    )
    guard result.status == 0 else {
      throw LocalOpsError.commandFailed("sqlite3 失败：\(result.stderr)")
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func sqliteExecute(at database: URL, sql: String) throws {
    let candidates = ["/usr/bin/sqlite3", "/bin/sqlite3"]
    guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    else {
      throw LocalOpsError.commandFailed("测试机缺少 sqlite3 CLI")
    }
    let result = try CommandRunner().run(
      executable: executable,
      arguments: [database.path, sql],
      timeoutSeconds: 5,
      maxOutputBytes: 128 * 1_024
    )
    guard result.status == 0 else {
      throw LocalOpsError.commandFailed("sqlite3 写入失败：(result.stderr)")
    }
  }

  private static func waitForLegacyWALFixture(_ database: URL) throws {
    let wal = URL(fileURLWithPath: database.path + "-wal")
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let walSize =
        (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue
        ?? 0
      if walSize > 0,
        (try? sqliteScalar(
          at: database,
          query: "SELECT value FROM legacy_rows WHERE id = 'wal-row';"
        )) == "committed"
      {
        return
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw LocalOpsError.commandFailed("legacy WAL fixture 未提交")
  }

  private static func httpStatus(_ url: URL) async throws -> Int {
    let response = try await httpRequest(url, method: "GET")
    return response.status
  }

  private static func httpRequest(
    _ url: URL,
    method: String
  ) async throws -> (status: Int, data: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw LocalOpsError.commandFailed("HTTP 响应缺少状态码")
    }
    return (status, data)
  }

  private static func waitForHTTPStatus(
    _ url: URL,
    expected: Int,
    timeout: TimeInterval
  ) async throws -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    var lastStatus: Int?
    while Date() < deadline {
      if let status = try? await httpStatus(url) {
        lastStatus = status
        if status == expected { return status }
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw LocalOpsError.commandFailed(
      "HTTP 状态未达到期望值：期望 \(expected)，最后 \(lastStatus.map(String.init) ?? "无响应")"
    )
  }

  private static func stubSession(
    status: Int,
    headers: [String: String],
    body: Data
  ) -> URLSession {
    ReliabilityURLProtocol.response = .init(status: status, headers: headers, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReliabilityURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private struct ReliabilityHealthyChecker: HealthChecking {
  func probe(_ check: ServiceHealthCheck) async -> ProbeResult {
    ProbeResult(lifecycle: .running, health: .healthy)
  }
}

private final class ReliabilitySQLiteSession: @unchecked Sendable {
  private let process: Process
  private let input: Pipe
  private let output: Pipe

  init(database: URL) throws {
    let executable = ["/usr/bin/sqlite3", "/bin/sqlite3"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
    guard let executable else {
      throw LocalOpsError.commandFailed("测试机缺少 sqlite3 CLI")
    }

    process = Process()
    input = Pipe()
    output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
      "-batch",
      "-cmd",
      "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; "
        + "CREATE TABLE legacy_rows (id TEXT PRIMARY KEY, value TEXT); "
        + "INSERT INTO legacy_rows VALUES ('wal-row', 'committed');",
      database.path,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
  }

  func stop() {
    try? input.fileHandleForWriting.close()
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}

private final class ReliabilitySQLiteLock: @unchecked Sendable {
  private let process: Process
  private let input: Pipe
  private let output: Pipe

  init(database: URL, marker: URL) throws {
    let executable = ["/usr/bin/sqlite3", "/bin/sqlite3"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
    guard let executable else {
      throw LocalOpsError.commandFailed("测试机缺少 sqlite3 CLI")
    }

    process = Process()
    input = Pipe()
    output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
      "-batch",
      "-cmd",
      ".once \(marker.path)",
      "-cmd",
      "BEGIN EXCLUSIVE; SELECT 'LOCKED';",
      database.path,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
  }

  func stop() {
    try? input.fileHandleForWriting.close()
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}

private enum ReliabilityDiscoveryStep: Sendable {
  case listeners([ListeningService])
  case failure
}

/// Actor-backed scan counter used to prove that read-only web routes do not
/// trigger a fresh discovery pass.
private actor ReliabilityDiscoveryCounter {
  private var scans = 0

  func increment() {
    scans += 1
  }

  func value() -> Int {
    scans
  }
}

private struct ReliabilityCountingDiscovery: ServiceDiscovering {
  let counter: ReliabilityDiscoveryCounter
  let listeners: [ListeningService]

  func scan() async throws -> [ListeningService] {
    await counter.increment()
    return listeners
  }
}

private actor ReliabilityDiscoveryScript {
  private var steps: [ReliabilityDiscoveryStep]

  init(steps: [ReliabilityDiscoveryStep]) {
    self.steps = steps
  }

  func next() -> ReliabilityDiscoveryStep {
    if steps.isEmpty { return .listeners([]) }
    return steps.removeFirst()
  }
}

private struct ReliabilityScriptedDiscovery: ServiceDiscovering {
  let script: ReliabilityDiscoveryScript

  init(steps: [ReliabilityDiscoveryStep]) {
    script = ReliabilityDiscoveryScript(steps: steps)
  }

  func scan() async throws -> [ListeningService] {
    switch await script.next() {
    case .listeners(let listeners): return listeners
    case .failure: throw ReliabilityDiscoveryError.unavailable
    }
  }
}

private enum ReliabilityDiscoveryError: Error, LocalizedError, Sendable {
  case unavailable

  var errorDescription: String? { "测试发现器暂时不可用" }
}

private actor ReliabilityProbeBudgetTracker {
  private var active = 0
  private var maximum = 0

  func enter() {
    active += 1
    maximum = max(maximum, active)
  }

  func leave() {
    active = max(0, active - 1)
  }

  func maximumConcurrency() -> Int { maximum }
}

private struct ReliabilityDelayedHealthChecker: HealthChecking {
  let tracker: ReliabilityProbeBudgetTracker
  let delayNanoseconds: UInt64

  func probe(_ check: ServiceHealthCheck) async -> ProbeResult {
    await tracker.enter()
    try? await Task.sleep(nanoseconds: delayNanoseconds)
    await tracker.leave()
    return ProbeResult(lifecycle: .running, health: .healthy)
  }
}

private final class ReliabilityURLProtocol: URLProtocol {
  struct Response: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
  }

  nonisolated(unsafe) static var response = Response(status: 200, headers: [:], body: Data())

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let value = Self.response
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: value.status,
        httpVersion: "HTTP/1.1",
        headerFields: value.headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: ReliabilityURLProtocolError.invalidResponse)
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !value.body.isEmpty { client?.urlProtocol(self, didLoad: value.body) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private enum ReliabilityURLProtocolError: Error {
  case invalidResponse
}
