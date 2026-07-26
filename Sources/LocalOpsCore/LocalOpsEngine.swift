import Foundation

public actor LocalOpsEngine {
  private let paths: LocalOpsPaths
  private let store: LocalOpsStore
  private let discovery: any ServiceDiscovering
  private let healthChecker: any HealthChecking
  private let metricsReader: SystemMetricsReader
  private var cachedOverview = LocalOpsOverview.empty
  private var initialized = false

  public init(
    paths: LocalOpsPaths,
    discovery: any ServiceDiscovering = SystemServiceDiscovery(),
    healthChecker: any HealthChecking = SystemHealthChecker(),
    metricsReader: SystemMetricsReader = SystemMetricsReader()
  ) throws {
    try paths.prepare()
    self.paths = paths
    self.store = try LocalOpsStore(path: paths.database)
    self.discovery = discovery
    self.healthChecker = healthChecker
    self.metricsReader = metricsReader
  }

  @discardableResult
  public func initialize() async throws -> LocalOpsOverview {
    try await store.migrate()
    let legacyDefinitions = LegacyServiceMigrator().load(from: paths.legacyServices)
    for definition in legacyDefinitions {
      try? await store.saveDefinition(definition, replace: false)
    }
    try await store.seedDefaults(try Self.loadDefaultDefinitions())
    initialized = true
    return await refresh()
  }

  public func overview() -> LocalOpsOverview {
    cachedOverview
  }

  public func service(id: String) -> ServiceSnapshot? {
    cachedOverview.services.first { $0.id == id }
  }

  @discardableResult
  public func refresh() async -> LocalOpsOverview {
    guard initialized else {
      cachedOverview.error = LocalOpsError.notInitialized.localizedDescription
      return cachedOverview
    }

    do {
      let definitions = try await store.loadDefinitions()
      let listeners: [ListeningService]
      var scanError: String?
      do {
        listeners = try await discovery.scan()
      } catch {
        listeners = []
        scanError = error.localizedDescription
      }

      let probes = await probe(definitions)
      let now = Date()
      var registered: [ServiceSnapshot] = []
      for (definition, result) in zip(definitions, probes) {
        let listener = matchListener(ports: definition.ports, listeners: listeners)
        let snapshot = registeredSnapshot(
          definition: definition,
          probe: result,
          listener: listener
        )
        registered.append(snapshot)
        try await store.record(snapshot)
      }

      let knownPorts = Set(definitions.flatMap(\.ports))
      let candidates = discoveryCandidates(from: listeners, knownPorts: knownPorts)
      var discovered: [ServiceSnapshot] = []
      for listener in candidates {
        try await store.recordObserved(listener, seenAt: now)
        discovered.append(discoveredSnapshot(listener, seenAt: now))
      }

      let onlineObservedIds = Set(discovered.map(\.id))
      let observed = try await store.listObserved()
      let history = observed.compactMap { record -> ServiceSnapshot? in
        guard !onlineObservedIds.contains(record.id), !knownPorts.contains(record.port) else {
          return nil
        }
        return historySnapshot(record)
      }

      let events = try await store.listEvents(limit: 50)
      let summary = LocalOpsSummary(
        total: registered.count,
        healthy: registered.count { $0.health == .healthy },
        attention: registered.count { $0.health == .unhealthy || $0.health == .degraded },
        stopped: registered.count { $0.lifecycle == .stopped },
        discovered: discovered.count,
        offlineHistory: history.count
      )
      cachedOverview = LocalOpsOverview(
        services: registered + discovered + history,
        summary: summary,
        system: metricsReader.read(),
        groups: Array(Set(registered.map(\.group))).sorted(),
        events: events,
        refreshedAt: now,
        error: scanError
      )
    } catch {
      cachedOverview.error = error.localizedDescription
      cachedOverview.refreshedAt = Date()
    }
    return cachedOverview
  }

  public func registerObserved(
    id: String,
    name: String,
    group: String = "其他"
  ) async throws {
    guard let observed = try await store.listObserved().first(where: { $0.id == id }) else {
      throw LocalOpsError.invalidService("找不到该服务记录")
    }
    let serviceId = uniqueServiceId(name: name, observedId: id)
    let definition = ServiceDefinition(
      id: serviceId,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      group: group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "其他" : group,
      description: "由 LocalOps 发现的本地服务",
      endpoints: [
        ServiceEndpoint(name: "服务入口", url: "http://\(observed.host):\(observed.port)/")
      ],
      health: ServiceHealthCheck(type: .tcp, host: observed.host, port: observed.port)
    )
    try await store.saveDefinition(definition)
    try await store.forgetObserved(id: id)
    _ = await refresh()
  }

  public func forgetObserved(id: String) async throws {
    guard let snapshot = cachedOverview.services.first(where: { $0.id == id }) else {
      throw LocalOpsError.invalidService("找不到该服务记录")
    }
    guard snapshot.source == .history else {
      throw LocalOpsError.invalidService("服务仍在监听，停止后才能忘记历史记录")
    }
    try await store.forgetObserved(id: id)
    _ = await refresh()
  }

  public func removeCustomService(id: String) async throws {
    try await store.deleteDefinition(id: id)
    _ = await refresh()
  }

  public static func loadDefaultDefinitions() throws -> [ServiceDefinition] {
    guard let url = Bundle.module.url(forResource: "DefaultServices", withExtension: "json") else {
      throw LocalOpsError.resourceMissing("DefaultServices.json")
    }
    let catalog = try JSONDecoder().decode(
      DefaultServiceCatalog.self,
      from: Data(contentsOf: url)
    )
    guard catalog.version == 1 else {
      throw LocalOpsError.invalidService("默认服务版本不支持")
    }
    return try catalog.services.map { try $0.validated() }
  }

  private func probe(_ definitions: [ServiceDefinition]) async -> [ProbeResult] {
    await withTaskGroup(of: (Int, ProbeResult).self, returning: [ProbeResult].self) { group in
      for (index, definition) in definitions.enumerated() {
        group.addTask { [healthChecker] in
          (index, await healthChecker.probe(definition.health))
        }
      }
      var values = [ProbeResult?](repeating: nil, count: definitions.count)
      for await (index, result) in group {
        values[index] = result
      }
      return values.map {
        $0 ?? ProbeResult(lifecycle: .unknown, health: .unknown, message: "检查未完成")
      }
    }
  }

  private func registeredSnapshot(
    definition: ServiceDefinition,
    probe: ProbeResult,
    listener: ListeningService?
  ) -> ServiceSnapshot {
    var lifecycle = probe.lifecycle
    if listener != nil, lifecycle == .stopped || lifecycle == .unknown {
      lifecycle = .running
    }
    return ServiceSnapshot(
      id: definition.id,
      name: definition.name,
      group: definition.group,
      description: definition.description,
      source: .registered,
      lifecycle: lifecycle,
      health: probe.health,
      endpoints: definition.endpoints,
      latencyMs: probe.latencyMs,
      checkedAt: probe.checkedAt,
      message: probe.message,
      pid: listener?.pid,
      processName: listener?.processName,
      executablePath: listener?.executablePath,
      workingDirectory: listener?.workingDirectory,
      memoryMb: listener?.memoryMb,
      cpuPercent: listener?.cpuPercent,
      presence: lifecycle == .stopped ? .offline : .online,
      lastSeenAt: lifecycle == .stopped ? nil : probe.checkedAt,
      responseSummary: probe.responseSummary
    )
  }

  private func discoveredSnapshot(_ listener: ListeningService, seenAt: Date) -> ServiceSnapshot {
    ServiceSnapshot(
      id: listener.stableId,
      name: "\(listener.processName) :\(listener.port)",
      group: "待登记",
      description: "扫描到的本机监听端口；当前只读。",
      source: .discovered,
      lifecycle: .running,
      health: .unknown,
      endpoints: [
        ServiceEndpoint(name: "服务入口", url: "http://\(listener.normalizedHost):\(listener.port)/")
      ],
      checkedAt: seenAt,
      pid: listener.pid,
      processName: listener.processName,
      executablePath: listener.executablePath,
      workingDirectory: listener.workingDirectory,
      memoryMb: listener.memoryMb,
      cpuPercent: listener.cpuPercent,
      presence: .online,
      firstSeenAt: seenAt,
      lastSeenAt: seenAt
    )
  }

  private func historySnapshot(_ record: ObservedServiceRecord) -> ServiceSnapshot {
    ServiceSnapshot(
      id: record.id,
      name: "\(record.processName) :\(record.port)",
      group: "最近掉线",
      description: "LocalOps 以前发现过该服务，当前端口已离线。",
      source: .history,
      lifecycle: .stopped,
      health: .unhealthy,
      endpoints: [
        ServiceEndpoint(name: "上次入口", url: "http://\(record.host):\(record.port)/")
      ],
      checkedAt: record.lastSeenAt,
      message: "最后在线：\(record.lastSeenAt.formatted(date: .abbreviated, time: .shortened))",
      pid: record.lastPid,
      processName: record.processName,
      executablePath: record.executablePath,
      workingDirectory: record.workingDirectory,
      presence: .offline,
      firstSeenAt: record.firstSeenAt,
      lastSeenAt: record.lastSeenAt
    )
  }

  private func uniqueServiceId(name: String, observedId: String) -> String {
    let normalized = name.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let base = normalized.isEmpty ? "service" : String(normalized.prefix(40))
    return "\(base)-\(observedId.suffix(6))"
  }
}
