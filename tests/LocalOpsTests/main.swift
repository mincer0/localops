import Foundation
import LocalOpsCore
import LocalOpsWeb

@main
enum LocalOpsTestRunner {
  static func main() async {
    let tests: [(String, () async throws -> Void)] = [
      ("default services", testDefaultServices),
      ("address parsing", testAddressParsing),
      ("stable observed identity", testStableIdentity),
      ("legacy YAML migration", testLegacyMigration),
      ("GRDB persistence", testStore),
      ("system operations metrics", testSystemMetrics),
      ("engine aggregation and history", testEngine),
      ("discovered registration workflow", testRegistrationWorkflow),
      ("observed forget workflow", testForgetWorkflow),
      ("FlyingFox read-only routes", testWeb),
    ]

    var failures: [String] = []
    for (name, test) in tests {
      do {
        try await test()
        print("✓ \(name)")
      } catch {
        failures.append("\(name): \(error)")
        print("✗ \(name): \(error)")
      }
    }

    if failures.isEmpty {
      print("\n\(tests.count)/\(tests.count) Swift tests passed")
    } else {
      print("\n\(failures.count) test(s) failed")
      exit(1)
    }
  }

  private static func testDefaultServices() async throws {
    let services = try LocalOpsEngine.loadDefaultDefinitions()
    try check(Set(services.map(\.id)).count == services.count, "duplicate default id")
    try check(services.contains { $0.id == "omlx" && $0.health.type == .http }, "oMLX missing")
  }

  private static func testAddressParsing() async throws {
    try check(parseListeningAddress("127.0.0.1:8042")?.host == "127.0.0.1", "IPv4")
    try check(parseListeningAddress("[::1]:9000")?.port == 9000, "IPv6")
    try check(parseListeningAddress("*:7860")?.host == "*", "wildcard")
    try check(parseListeningAddress("broken") == nil, "invalid address")
  }

  private static func testStableIdentity() async throws {
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
    try check(first.stableId == restarted.stableId, "identity changed with PID")
  }

  private static func testLegacyMigration() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("services.yaml")
    try legacyYAML.write(to: file, atomically: true, encoding: .utf8)
    let result = LegacyServiceMigrator().load(from: [file])
    try check(result.count == 1, "legacy service count")
    try check(result.first?.id == "demo", "legacy id")
    try check(result.first?.health.port == 9123, "legacy health port")
  }

  private static func testStore() async throws {
    let directory = try temporaryDirectory()
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
    try check(try await store.loadDefinitions().map(\.id) == ["demo"], "definition persistence")

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
    try check(try await store.listEvents().first?.kind == "discovered", "event persistence")

    let listener = ListeningService(
      pid: 321,
      processName: "demo-server",
      host: "127.0.0.1",
      port: 9124,
      address: "127.0.0.1:9124"
    )
    try await store.recordObserved(listener)
    try check(try await store.listObserved().first?.port == 9124, "observed persistence")
  }

  private static func testSystemMetrics() async throws {
    let metrics = SystemMetricsReader().read()
    try check(metrics.memoryTotalGb > 0, "physical memory missing")
    try check(metrics.diskFreeGb >= 0, "invalid disk capacity")
    try check(metrics.diskTotalGb >= metrics.diskFreeGb, "invalid disk total")
    try check(metrics.cpuLoadOneMinute >= 0, "invalid CPU load")
    try check(metrics.logicalProcessorCount > 0, "processor count missing")
    try check(metrics.uptimeSeconds > 0, "uptime missing")

    let encoded = try JSONEncoder().encode(metrics)
    try check(
      try JSONDecoder().decode(LocalOpsSystemMetrics.self, from: encoded) == metrics,
      "metrics coding")
  }

  private static func testEngine() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appendingPathComponent("services.yaml")
    try legacyYAML.write(to: legacy, atomically: true, encoding: .utf8)
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
    try check(first.services.contains { $0.id == "demo" && $0.source == .registered }, "registered")
    try check(first.services.contains { $0.source == .discovered && $0.pid == 222 }, "discovered")

    let offlineEngine = try LocalOpsEngine(
      paths: paths,
      discovery: FixedDiscovery(listeners: []),
      healthChecker: FixedHealthChecker()
    )
    let second = try await offlineEngine.initialize()
    try check(
      second.services.contains { $0.source == .history && $0.id == listener.stableId }, "history")
  }

  private static func testRegistrationWorkflow() async throws {
    let directory = try temporaryDirectory()
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
    try check(
      overview.services.contains {
        $0.name == "Workflow" && $0.source == .registered && $0.endpoints.first?.port == 19_401
      },
      "registered service missing"
    )
    try check(
      !overview.services.contains { $0.id == listener.stableId && $0.source == .discovered },
      "registered listener still discovered"
    )
  }

  private static func testForgetWorkflow() async throws {
    let directory = try temporaryDirectory()
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
      throw TestFailure("online listener was forgotten")
    } catch is LocalOpsError {
      // Expected: online listeners remain discoverable until they stop.
    }

    let offline = try LocalOpsEngine(
      paths: paths,
      discovery: FixedDiscovery(listeners: []),
      healthChecker: FixedHealthChecker()
    )
    let history = try await offline.initialize()
    try check(history.services.contains { $0.id == listener.stableId }, "history missing")
    try await offline.forgetObserved(id: listener.stableId)
    try check(
      !(await offline.overview()).services.contains { $0.id == listener.stableId },
      "history was not forgotten"
    )
  }

  private static func testWeb() async throws {
    let directory = try temporaryDirectory()
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
      throw TestFailure("FlyingFox did not start")
    }

    let (page, pageResponse) = try await URLSession.shared.data(from: baseURL)
    try check((pageResponse as? HTTPURLResponse)?.statusCode == 200, "web page status")
    try check(String(decoding: page, as: UTF8.self).contains("此页只读"), "read-only page")

    let overviewURL = baseURL.appendingPathComponent("api/v1/overview")
    let (data, response) = try await URLSession.shared.data(from: overviewURL)
    try check((response as? HTTPURLResponse)?.statusCode == 200, "overview status")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    try check(json?["services"] != nil, "overview payload")
    let system = json?["system"] as? [String: Any]
    try check(system?["thermal_state"] != nil, "thermal state payload")
    try check(system?["cpu_load_one_minute"] != nil, "CPU load payload")

    var post = URLRequest(url: overviewURL)
    post.httpMethod = "POST"
    let (_, postResponse) = try await URLSession.shared.data(for: post)
    try check((postResponse as? HTTPURLResponse)?.statusCode == 404, "mutating route exists")

    let health = await SystemHealthChecker().probe(
      .init(type: .http, url: baseURL.appendingPathComponent("healthz").absoluteString)
    )
    try check(health.health == .healthy, "health route")
    await web.stop()
    try check(await web.state() == .stopped, "web stop")
  }

  private static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(message) }
  }

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

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
