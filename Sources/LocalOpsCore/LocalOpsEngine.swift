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
    do {
      try await store.backupIfNeeded(
        to: paths.database.appendingPathExtension("preflight.sqlite3")
      )
      try await store.migrate()
      try await migrateLegacyDefinitionsIfNeeded()
      try await store.seedDefaults(try Self.loadDefaultDefinitions())
      initialized = true
      let state = try await store.refreshState()
      cachedOverview.metadata.generation = state.generation
      cachedOverview.metadata.successfulAt = state.successfulAt
      let refreshed = await refresh()
      guard refreshed.snapshotProjection().ready else {
        throw LocalOpsError.commandFailed(
          refreshed.error ?? "LocalOps 首次刷新未产生可用快照"
        )
      }
      return refreshed
    } catch {
      initialized = false
      markFailure(error, attemptedAt: Date())
      throw error
    }
  }

  public func overview() -> LocalOpsOverview {
    cachedOverview
  }

  public func service(id: String) -> ServiceSnapshot? {
    cachedOverview.services.first { $0.id == id }
  }

  /// Read the persisted registration, including disabled services that are not
  /// present in the current runtime overview.
  public func definition(id: String) async throws -> ServiceDefinition? {
    try await store.loadDefinition(id: id)
  }

  /// Read the complete editable registration catalog, including disabled
  /// services. The result is validated and stably sorted by Core; this method
  /// never probes, starts, stops, or otherwise controls a user service.
  public func definitions() async throws -> [ServiceDefinition] {
    try await store.definitions()
  }

  /// Update registration metadata only. This operation validates and persists
  /// the definition, then refreshes observations; it never invokes a process,
  /// launchd, container, CLI, or recovery command.
  public func updateRegisteredDefinition(_ definition: ServiceDefinition) async throws {
    let value = try definition.validated()
    guard try await store.loadDefinition(id: value.id) != nil else {
      throw LocalOpsError.invalidService("找不到登记服务：\(value.id)")
    }
    try await store.updateDefinition(value)
    _ = await refresh()
  }

  /// Clear only LocalOps' current database catalog, preserving the schema,
  /// migration markers, legacy YAML, and legacy SQLite rollback source. The
  /// built-in bundle is loaded and validated before the destructive operation;
  /// deletion and reseeding then happen in one Store transaction. Once the
  /// transaction, checkpoint/VACUUM, and preflight-backup cleanup complete, a
  /// refresh is attempted and its overview is returned. A thrown error means
  /// one of those steps failed; a successful return means the clear committed,
  /// while `overview.error`/metadata may still report that the best-effort
  /// refresh could not collect a fresh snapshot. No user process or service
  /// manager is touched by this API.
  @discardableResult
  public func clearCurrentDirectoryData() async throws -> LocalOpsOverview {
    let defaults = try Self.loadDefaultDefinitions()
    let attemptedAt = Date()
    do {
      try await store.clearCurrentDirectoryData(seeding: defaults, completedAt: attemptedAt)
      try await store.checkpointAndVacuum()
      try removePreflightBackup()

      // Do not expose snapshots from before the clear if discovery fails. A
      // failed post-clear refresh therefore returns an empty overview with a
      // failed/unknown projection, allowing the caller to distinguish it
      // from a successful fresh refresh without claiming false service state.
      initialized = true
      cachedOverview = .empty
      return await refresh()
    } catch {
      initialized = false
      markFailure(error, attemptedAt: attemptedAt)
      throw error
    }
  }

  @discardableResult
  public func refresh() async -> LocalOpsOverview {
    // Initialization is retryable.  This is important for a transient file
    // permission/SQLite failure: callers need not restart the App to recover.
    if !initialized {
      do {
        return try await initialize()
      } catch {
        markFailure(error, attemptedAt: Date())
        return cachedOverview
      }
    }

    let attemptedAt = Date()
    do {
      let definitions = try await store.loadDefinitions()
      let listeners: [ListeningService]
      do {
        listeners = try await discovery.scan()
      } catch {
        // A failed scan cannot prove anything about process presence.  Keep
        // the last successful snapshot rather than replacing it with false
        // offline states.
        markFailure(error, attemptedAt: attemptedAt)
        return cachedOverview
      }

      let probes = await probe(definitions)
      let now = Date()
      var registered: [ServiceSnapshot] = []
      var refreshWasPartial = false
      for (definition, result) in zip(definitions, probes) {
        // `.none` deliberately reports unknown health/lifecycle because no
        // check was configured; that expected state does not make this
        // otherwise successful refresh partial. Probe freshness for actual
        // checks, plus ambiguous process attribution, does.
        if definition.health.type != .none,
          result.freshness == .partial || result.freshness == .unknown
        {
          refreshWasPartial = true
        }
        let match = matchListenerDetailed(
          ports: definition.ports,
          listeners: listeners,
          hosts: definition.hosts
        )
        registered.append(
          registeredSnapshot(definition: definition, probe: result, match: match)
        )
        if case .ambiguous = match {
          refreshWasPartial = true
        }
      }

      let knownPorts = Set(definitions.flatMap(\.ports))
      let candidates = discoveryCandidates(from: listeners, knownPorts: knownPorts)
      let discovered = candidates.map { discoveredSnapshot($0, seenAt: now) }

      let commit = try await store.commitRefresh(
        snapshots: registered,
        observed: candidates,
        attemptedAt: attemptedAt,
        successfulAt: now
      )
      let generation = commit.generation
      registered = commit.snapshots
      let onlineObservedIds = Set(discovered.map(\.id))
      let observed = try await store.listObserved()
      let history = observed.compactMap { record -> ServiceSnapshot? in
        guard !onlineObservedIds.contains(record.id), !knownPorts.contains(record.port) else {
          return nil
        }
        return historySnapshot(record)
      }
      let events = try await store.listEvents(limit: 50)
      let allServices = registered + discovered + history
      let metadata = SnapshotMetadata(
        generation: generation,
        attemptedAt: attemptedAt,
        successfulAt: now,
        freshness: refreshWasPartial ? .partial : .fresh,
        outcome: refreshWasPartial ? .partial : .success,
        error: nil
      )
      let summary = LocalOpsSummary(
        total: registered.count,
        healthy: registered.count { $0.health == .healthy },
        attention: registered.count {
          $0.health == .unhealthy || $0.health == .degraded
        },
        stopped: registered.count { $0.lifecycle == .stopped },
        discovered: discovered.count,
        offlineHistory: history.count,
        unknown: registered.count {
          $0.lifecycle == .unknown || $0.health == .unknown
        },
        stale: allServices.count {
          $0.observation.freshness == .stale || $0.observation.freshness == .partial
        }
      )
      cachedOverview = LocalOpsOverview(
        services: allServices,
        summary: summary,
        system: metricsReader.read(),
        groups: Array(Set(registered.map(\.group))).sorted(),
        events: events,
        refreshedAt: now,
        error: nil,
        metadata: metadata
      )
    } catch {
      markFailure(error, attemptedAt: attemptedAt)
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

  private func removePreflightBackup() throws {
    let backup = paths.database.appendingPathExtension("preflight.sqlite3")
    guard FileManager.default.fileExists(atPath: backup.path) else { return }
    try FileManager.default.removeItem(at: backup)
  }

  private func migrateLegacyDefinitionsIfNeeded() async throws {
    let marker = "legacy-services-v1"
    guard !(try await store.hasMigrationMarker(marker)) else { return }
    let report = LegacyServiceMigrator().loadReport(from: paths.legacyServices)
    guard report.errors.isEmpty else {
      throw LocalOpsError.commandFailed(
        "旧版服务迁移失败：" + report.errors.joined(separator: "；")
      )
    }
    try await store.importLegacyDefinitions(report.definitions, marker: marker)
  }

  private func probe(_ definitions: [ServiceDefinition]) async -> [ProbeResult] {
    guard !definitions.isEmpty else { return [] }
    let workerCount = min(8, definitions.count)
    return await withTaskGroup(of: [(Int, ProbeResult)].self, returning: [ProbeResult].self) {
      group in
      for worker in 0..<workerCount {
        group.addTask { [healthChecker] in
          var values: [(Int, ProbeResult)] = []
          var index = worker
          while index < definitions.count {
            if Task.isCancelled { break }
            values.append((index, await healthChecker.probe(definitions[index].health)))
            index += workerCount
          }
          return values
        }
      }
      var output = [ProbeResult?](repeating: nil, count: definitions.count)
      for await values in group {
        for (index, result) in values { output[index] = result }
      }
      return output.map {
        $0
          ?? ProbeResult(
            lifecycle: .unknown,
            health: .unknown,
            message: "检查未完成",
            freshness: .unknown
          )
      }
    }
  }

  private func registeredSnapshot(
    definition: ServiceDefinition,
    probe: ProbeResult,
    match: ListenerMatch
  ) -> ServiceSnapshot {
    var lifecycle = probe.lifecycle
    var listener: ListeningService?
    let observation: ObservationEvidence
    switch match {
    case .matched(let value):
      listener = value
      if lifecycle == .stopped || lifecycle == .unknown { lifecycle = .running }
      observation = ObservationEvidence(
        state: .observed,
        freshness: .fresh,
        host: value.normalizedHost,
        port: value.port,
        pid: value.pid,
        processFingerprint: value.processFingerprint,
        processName: value.processName,
        executablePath: value.executablePath,
        observedAt: probe.checkedAt,
        matchConfidence: .hostPort
      )
    case .ambiguous:
      if lifecycle == .unknown { lifecycle = .unknown }
      observation = ObservationEvidence(
        state: .ambiguous,
        freshness: .partial,
        message: "同一主机和端口存在多个监听进程，未归属 PID",
        matchConfidence: .ambiguous
      )
    case .none:
      observation = ObservationEvidence(
        state: probe.lifecycle == .unknown ? .unknown : .notObserved,
        freshness: .fresh,
        observedAt: probe.checkedAt,
        matchConfidence: .none
      )
    }
    let presence: ServicePresence =
      switch lifecycle {
      case .running: .online
      case .stopped: .offline
      case .unknown: .unknown
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
      message: probe.message ?? observation.message,
      pid: listener?.pid,
      processName: listener?.processName,
      executablePath: listener?.executablePath,
      workingDirectory: listener?.workingDirectory,
      memoryMb: listener?.memoryMb,
      cpuPercent: listener?.cpuPercent,
      presence: presence,
      lastSeenAt: lifecycle == .stopped ? nil : probe.checkedAt,
      responseSummary: probe.responseSummary,
      observation: observation
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
      lastSeenAt: seenAt,
      observation: ObservationEvidence(
        state: .observed,
        freshness: .fresh,
        host: listener.normalizedHost,
        port: listener.port,
        pid: listener.pid,
        processFingerprint: listener.processFingerprint,
        processName: listener.processName,
        executablePath: listener.executablePath,
        observedAt: seenAt,
        matchConfidence: .hostPort
      )
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
      lastSeenAt: record.lastSeenAt,
      observation: ObservationEvidence(
        state: .notObserved,
        freshness: .stale,
        host: record.host,
        port: record.port,
        pid: record.lastPid,
        processName: record.processName,
        executablePath: record.executablePath,
        observedAt: record.lastSeenAt,
        message: "当前扫描未发现监听进程",
        matchConfidence: .none
      )
    )
  }

  private func markFailure(_ error: Error, attemptedAt: Date) {
    let hasSuccessful =
      cachedOverview.metadata.successfulAt != nil || cachedOverview.refreshedAt != nil
    cachedOverview.metadata.attemptedAt = attemptedAt
    cachedOverview.metadata.outcome = .failed
    cachedOverview.metadata.freshness = hasSuccessful ? .stale : .unknown
    cachedOverview.metadata.error = error.localizedDescription
    cachedOverview.error = error.localizedDescription
    // `refreshedAt` deliberately remains the last successful timestamp.
  }

  private func uniqueServiceId(name: String, observedId: String) -> String {
    let normalized = name.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let base = normalized.isEmpty ? "service" : String(normalized.prefix(40))
    return "\(base)-\(observedId.suffix(6))"
  }
}
