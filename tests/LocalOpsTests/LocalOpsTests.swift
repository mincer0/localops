import Foundation
import LocalOpsCore
import LocalOpsWeb
import XCTest

final class LocalOpsTests: XCTestCase {
  func testDefaultServices() throws {
    let services = try LocalOpsEngine.loadDefaultDefinitions()
    XCTAssertEqual(Set(services.map(\.id)).count, services.count, "duplicate default id")
    XCTAssertTrue(services.contains { $0.id == "omlx" && $0.health.type == .http }, "oMLX missing")
  }

  func testAddressParsing() {
    XCTAssertEqual(parseListeningAddress("127.0.0.1:8042")?.host, "127.0.0.1")
    XCTAssertEqual(parseListeningAddress("[::1]:9000")?.port, 9000)
    XCTAssertEqual(parseListeningAddress("*:7860")?.host, "*")
    XCTAssertNil(parseListeningAddress("broken"))
  }

  func testStableIdentity() {
    let first = ListeningService(
      pid: 100,
      processName: "python",
      host: "::1",
      port: 9000,
      address: "[::1]:9000",
      executablePath: "/tmp/python"
    )
    var restarted = first
    restarted.pid = 200
    restarted.host = "127.0.0.1"
    XCTAssertEqual(first.stableId, restarted.stableId, "identity changed with PID")
  }

  func testLegacyMigration() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("services.yaml")
    try Self.legacyYAML.write(to: file, atomically: true, encoding: .utf8)

    let result = LegacyServiceMigrator().load(from: [file])
    XCTAssertEqual(result.count, 1, "legacy service count")
    XCTAssertEqual(result.first?.id, "demo", "legacy id")
    XCTAssertEqual(result.first?.health.port, 9123, "legacy health port")
  }

  func testStore() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LocalOpsStore(path: directory.appendingPathComponent("localops.sqlite3"))
    try await store.migrate()
    let definition = ServiceDefinition(
      id: "demo",
      name: "Demo",
      group: "开发",
      endpoints: [.init(name: "Web", url: "http://127.0.0.1:9123/")],
      health: .init(type: .tcp, port: 9123)
    )
    try await store.saveDefinition(definition)
    let definitions = try await store.loadDefinitions()
    XCTAssertEqual(definitions.map(\.id), ["demo"], "definition persistence")

    try await store.record(
      ServiceSnapshot(
        id: "demo",
        name: "Demo",
        group: "开发",
        description: "",
        source: .registered,
        lifecycle: .stopped,
        health: .unhealthy,
        checkedAt: Date(),
        message: "offline",
        presence: .offline
      ))
    let firstEventKind = try await store.listEvents().first?.kind
    XCTAssertEqual(firstEventKind, "discovered", "event persistence")

    let listener = ListeningService(
      pid: 321,
      processName: "demo-server",
      host: "127.0.0.1",
      port: 9124,
      address: "127.0.0.1:9124"
    )
    try await store.recordObserved(listener)
    let observedPort = try await store.listObserved().first?.port
    XCTAssertEqual(observedPort, 9124, "observed persistence")
  }

  func testSystemMetrics() throws {
    let metrics = SystemMetricsReader().read()
    XCTAssertGreaterThan(metrics.memoryTotalGb, 0, "physical memory missing")
    XCTAssertGreaterThanOrEqual(metrics.diskFreeGb, 0, "invalid disk capacity")
    XCTAssertGreaterThanOrEqual(metrics.diskTotalGb, metrics.diskFreeGb, "invalid disk total")
    XCTAssertGreaterThanOrEqual(metrics.cpuLoadOneMinute, 0, "invalid CPU load")
    XCTAssertGreaterThan(metrics.logicalProcessorCount, 0, "processor count missing")
    XCTAssertGreaterThan(metrics.uptimeSeconds, 0, "uptime missing")

    let encoded = try JSONEncoder().encode(metrics)
    XCTAssertEqual(
      try JSONDecoder().decode(LocalOpsSystemMetrics.self, from: encoded),
      metrics,
      "metrics coding"
    )
  }

  func testEngine() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appendingPathComponent("services.yaml")
    try Self.legacyYAML.write(to: legacy, atomically: true, encoding: .utf8)
    let paths = LocalOpsPaths(
      applicationSupport: directory,
      database: directory.appendingPathComponent("localops.sqlite3"),
      legacyServices: [legacy]
    )
    let listener = ListeningService(
      pid: 222,
      processName: "new-server",
      host: "127.0.0.1",
      port: 9555,
      address: "127.0.0.1:9555"
    )
    let engine = try LocalOpsEngine(
      paths: paths,
      discovery: FixedDiscovery(listeners: [listener]),
      healthChecker: FixedHealthChecker()
    )
    let first = try await engine.initialize()
    XCTAssertTrue(
      first.services.contains { $0.id == "demo" && $0.source == .registered },
      "registered"
    )
    XCTAssertTrue(
      first.services.contains { $0.source == .discovered && $0.pid == 222 },
      "discovered"
    )

    let offlineEngine = try LocalOpsEngine(
      paths: paths,
      discovery: FixedDiscovery(listeners: []),
      healthChecker: FixedHealthChecker()
    )
    let second = try await offlineEngine.initialize()
    XCTAssertTrue(
      second.services.contains { $0.source == .history && $0.id == listener.stableId },
      "history"
    )
  }

  func testRegistrationWorkflow() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let listener = ListeningService(
      pid: 401,
      processName: "workflow-server",
      host: "127.0.0.1",
      port: 19_401,
      address: "127.0.0.1:19401"
    )
    let engine = try LocalOpsEngine(
      paths: LocalOpsPaths(
        applicationSupport: directory,
        database: directory.appendingPathComponent("localops.sqlite3")
      ),
      discovery: FixedDiscovery(listeners: [listener]),
      healthChecker: FixedHealthChecker()
    )
    _ = try await engine.initialize()
    try await engine.registerObserved(id: listener.stableId, name: "Workflow", group: "测试")
    let overview = await engine.overview()
    XCTAssertTrue(
      overview.services.contains {
        $0.name == "Workflow" && $0.source == .registered && $0.endpoints.first?.port == 19_401
      },
      "registered service missing"
    )
    XCTAssertFalse(
      overview.services.contains { $0.id == listener.stableId && $0.source == .discovered },
      "registered listener still discovered"
    )
  }

  func testForgetWorkflow() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = LocalOpsPaths(
      applicationSupport: directory,
      database: directory.appendingPathComponent("localops.sqlite3")
    )
    let listener = ListeningService(
      pid: 402,
      processName: "forget-server",
      host: "127.0.0.1",
      port: 19_402,
      address: "127.0.0.1:19402"
    )
    let online = try LocalOpsEngine(
      paths: paths,
      discovery: FixedDiscovery(listeners: [listener]),
      healthChecker: FixedHealthChecker()
    )
    _ = try await online.initialize()
    do {
      try await online.forgetObserved(id: listener.stableId)
      XCTFail("online listener was forgotten")
    } catch is LocalOpsError {
      // Expected: online listeners remain discoverable until they stop.
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    let offline = try LocalOpsEngine(
      paths: paths,
      discovery: FixedDiscovery(listeners: []),
      healthChecker: FixedHealthChecker()
    )
    let history = try await offline.initialize()
    XCTAssertTrue(history.services.contains { $0.id == listener.stableId }, "history missing")
    try await offline.forgetObserved(id: listener.stableId)
    let forgottenOverview = await offline.overview()
    XCTAssertFalse(
      forgottenOverview.services.contains { $0.id == listener.stableId },
      "history was not forgotten"
    )
  }

  func testWeb() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = try LocalOpsEngine(
      paths: LocalOpsPaths(
        applicationSupport: directory,
        database: directory.appendingPathComponent("localops.sqlite3")
      ),
      discovery: FixedDiscovery(listeners: []),
      healthChecker: FixedHealthChecker()
    )
    _ = try await engine.initialize()
    let web = try LocalWebServer(engine: engine, port: 0)
    guard case .running(let baseURL) = await web.start() else {
      XCTFail("FlyingFox did not start")
      return
    }

    let (page, pageResponse) = try await URLSession.shared.data(from: baseURL)
    XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200, "web page status")
    let html = String(decoding: page, as: UTF8.self)
    XCTAssertTrue(html.contains("此页只读"), "read-only page")
    XCTAssertEqual(
      html.components(separatedBy: #"aria-pressed="true""#).count - 1,
      1,
      "the initial filter selection must have one pressed button"
    )
    XCTAssertEqual(
      html.components(separatedBy: #"aria-pressed="false""#).count - 1,
      3,
      "the initial filter selection must expose the other three buttons"
    )

    let scriptURL = baseURL.appendingPathComponent("static/localops.js")
    let (script, scriptResponse) = try await URLSession.shared.data(from: scriptURL)
    XCTAssertEqual((scriptResponse as? HTTPURLResponse)?.statusCode, 200, "script status")
    let javascript = String(decoding: script, as: UTF8.self)
    for marker in [
      #"item.setAttribute("aria-pressed", String(selected));"#,
      "const staleAfterSeconds = Number(typedState.stale_after_seconds);",
      "const stale = disconnected || kind === \"stale\" || pastThreshold;",
      "const ageText = formatAge(ageSeconds);",
      "连接不可用",
    ] {
      XCTAssertTrue(javascript.contains(marker), "Web script regression missing: \(marker)")
    }

    let overviewURL = baseURL.appendingPathComponent("api/v1/overview")
    let (data, response) = try await URLSession.shared.data(from: overviewURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "overview status")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertNotNil(json?["services"], "overview payload")
    let system = json?["system"] as? [String: Any]
    XCTAssertNotNil(system?["thermal_state"], "thermal state payload")
    XCTAssertNotNil(system?["cpu_load_one_minute"], "CPU load payload")

    for method in ["POST", "PUT", "PATCH", "DELETE"] {
      var request = URLRequest(url: overviewURL)
      request.httpMethod = method
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual(
        (response as? HTTPURLResponse)?.statusCode,
        404,
        "mutating route exists for \(method)"
      )
    }

    let health = await SystemHealthChecker().probe(
      .init(type: .http, url: baseURL.appendingPathComponent("healthz").absoluteString)
    )
    XCTAssertEqual(health.health, .healthy, "health route")
    await web.stop()
    let stoppedState = await web.state()
    XCTAssertEqual(stoppedState, .stopped, "web stop")
  }

  // MARK: - Fixtures

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalOpsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static let legacyYAML = """
    version: 1
    services:
      - id: demo
        name: Demo
        group: 开发
        description: Legacy service
        manager:
          type: observe
        endpoints:
          - name: Web
            url: http://127.0.0.1:9123/
        health:
          type: tcp
          host: 127.0.0.1
          port: 9123
          timeout_seconds: 2
    """
}

private struct FixedDiscovery: ServiceDiscovering {
  let listeners: [ListeningService]

  func scan() async throws -> [ListeningService] { listeners }
}

private struct FixedHealthChecker: HealthChecking {
  func probe(_ check: ServiceHealthCheck) async -> ProbeResult {
    ProbeResult(lifecycle: .running, health: .healthy, latencyMs: 1)
  }
}
