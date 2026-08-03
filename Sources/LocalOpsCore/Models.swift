import Foundation

public enum ServiceSource: String, Codable, Sendable {
  case registered
  case discovered
  case history
}

public enum ServiceLifecycle: String, Codable, Sendable {
  case unknown
  case stopped
  case running
}

public enum ServiceHealth: String, Codable, Sendable {
  case unknown
  case healthy
  case degraded
  case unhealthy
}

public enum ServicePresence: String, Codable, Sendable {
  case online
  case offline
  case unknown
}

/// How a registered service is managed.  This is descriptive metadata only:
/// editing a definition never invokes the corresponding manager or executes
/// recovery commands.
public enum ServiceManagementKind: String, Codable, Sendable {
  case unknown
  case app
  case cli
  case launchd
  case container
  case manual
}

/// The freshness of an observation.  `unknown` is intentionally distinct from
/// `stale`: stale data is a last-known value, while unknown means that no
/// trustworthy value has ever been collected.
public enum ObservationFreshness: String, Codable, Equatable, Sendable {
  case fresh
  case partial
  case stale
  case unknown
}

public enum ObservationState: String, Codable, Equatable, Sendable {
  case observed
  case ambiguous
  case notObserved
  case unknown
}

/// Confidence assigned to process attribution. A PID by itself is not a
/// process identity because macOS may reuse it; host/port evidence and the
/// stable executable/name fingerprint are kept separate for callers that need
/// to explain an attribution decision.
public enum ObservationMatchConfidence: String, Codable, Equatable, Sendable {
  case none
  case ambiguous
  case portOnly
  case hostPort
  case processFingerprint

  /// Compatibility spellings for clients that prefer shorter labels.
  public static var port: Self { .portOnly }
  public static var fingerprint: Self { .processFingerprint }
}

public struct ObservationEvidence: Codable, Hashable, Sendable {
  public var state: ObservationState
  public var freshness: ObservationFreshness
  public var host: String?
  public var port: Int?
  public var pid: Int?
  /// Stable identity material for the observed process. It intentionally does
  /// not include PID, which can be reused after a process exits.
  public var processFingerprint: String?
  public var processName: String?
  public var executablePath: String?
  public var observedAt: Date?
  public var message: String?
  public var matchConfidence: ObservationMatchConfidence

  private enum CodingKeys: String, CodingKey {
    case state, freshness, host, port, pid, processFingerprint
    case processName, executablePath, observedAt, message, matchConfidence
  }

  public init(
    state: ObservationState = .unknown,
    freshness: ObservationFreshness = .unknown,
    host: String? = nil,
    port: Int? = nil,
    pid: Int? = nil,
    processFingerprint: String? = nil,
    processName: String? = nil,
    executablePath: String? = nil,
    observedAt: Date? = nil,
    message: String? = nil,
    matchConfidence: ObservationMatchConfidence = .none
  ) {
    self.state = state
    self.freshness = freshness
    self.host = host
    self.port = port
    self.pid = pid
    self.processFingerprint = processFingerprint
    self.processName = processName
    self.executablePath = executablePath
    self.observedAt = observedAt
    self.message = message
    self.matchConfidence = matchConfidence
  }

  /// Decode snapshots written before process fingerprints and confidence were
  /// introduced. Missing fields intentionally fall back to unknown/none so
  /// old JSON and SQLite details remain readable.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      state: try container.decodeIfPresent(ObservationState.self, forKey: .state) ?? .unknown,
      freshness: try container.decodeIfPresent(ObservationFreshness.self, forKey: .freshness)
        ?? .unknown,
      host: try container.decodeIfPresent(String.self, forKey: .host),
      port: try container.decodeIfPresent(Int.self, forKey: .port),
      pid: try container.decodeIfPresent(Int.self, forKey: .pid),
      processFingerprint: try container.decodeIfPresent(String.self, forKey: .processFingerprint),
      processName: try container.decodeIfPresent(String.self, forKey: .processName),
      executablePath: try container.decodeIfPresent(String.self, forKey: .executablePath),
      observedAt: try container.decodeIfPresent(Date.self, forKey: .observedAt),
      message: try container.decodeIfPresent(String.self, forKey: .message),
      matchConfidence: try container.decodeIfPresent(
        ObservationMatchConfidence.self,
        forKey: .matchConfidence
      ) ?? .none
    )
  }
}

public enum SnapshotOutcome: String, Codable, Equatable, Sendable {
  case success
  case partial
  case failed
}

public struct SnapshotMetadata: Codable, Equatable, Sendable {
  public var generation: Int64
  public var attemptedAt: Date?
  public var successfulAt: Date?
  public var freshness: ObservationFreshness
  public var outcome: SnapshotOutcome
  public var error: String?

  public init(
    generation: Int64 = 0,
    attemptedAt: Date? = nil,
    successfulAt: Date? = nil,
    freshness: ObservationFreshness = .unknown,
    outcome: SnapshotOutcome = .failed,
    error: String? = nil
  ) {
    self.generation = max(0, generation)
    self.attemptedAt = attemptedAt
    self.successfulAt = successfulAt
    self.freshness = freshness
    self.outcome = outcome
    self.error = error
  }

  public static let empty = SnapshotMetadata()
}

public enum LocalOpsSnapshotState: String, Codable, Equatable, Sendable {
  case starting
  case empty
  case fresh
  case partial
  case stale
  case coreError
}

/// A deterministic, UI-neutral view of snapshot readiness. All properties are
/// immutable so callers cannot accidentally mutate the Core's trust decision.
public struct LocalOpsSnapshotProjection: Equatable, Sendable {
  public let state: LocalOpsSnapshotState
  public let generation: Int64
  public let attemptedAt: Date?
  public let successfulAt: Date?
  public let age: TimeInterval?
  public let error: String?
  public let outcome: SnapshotOutcome
  public let freshness: ObservationFreshness
  public let ready: Bool

  public var updatedAt: Date? { successfulAt }

  public init(
    state: LocalOpsSnapshotState,
    generation: Int64,
    attemptedAt: Date?,
    successfulAt: Date?,
    age: TimeInterval?,
    error: String?,
    outcome: SnapshotOutcome,
    freshness: ObservationFreshness,
    ready: Bool
  ) {
    self.state = state
    self.generation = max(0, generation)
    self.attemptedAt = attemptedAt
    self.successfulAt = successfulAt
    self.age = age
    self.error = error
    self.outcome = outcome
    self.freshness = freshness
    self.ready = ready
  }

  public static let starting = LocalOpsSnapshotProjection(
    state: .starting,
    generation: 0,
    attemptedAt: nil,
    successfulAt: nil,
    age: nil,
    error: nil,
    outcome: .failed,
    freshness: .unknown,
    ready: false
  )
}

/// Compatibility spelling for clients that previously called this metadata
/// projection. It aliases the single Core projection type.
public typealias LocalOpsMetadataProjection = LocalOpsSnapshotProjection

public enum HealthCheckType: String, Codable, Sendable {
  case http
  case tcp
  case process
  case none
}

public struct ServiceEndpoint: Codable, Hashable, Sendable {
  public var name: String
  public var url: String

  public init(name: String, url: String) {
    self.name = name
    self.url = url
  }

  public var parsedURL: URL? { URL(string: url) }
  public var port: Int? { parsedURL?.port ?? parsedURL?.defaultPort }
}

public struct ServiceHealthCheck: Codable, Hashable, Sendable {
  public var type: HealthCheckType
  public var url: String?
  public var host: String
  public var port: Int?
  public var pid: Int?
  public var timeoutSeconds: Double

  public init(
    type: HealthCheckType = .none,
    url: String? = nil,
    host: String = "127.0.0.1",
    port: Int? = nil,
    pid: Int? = nil,
    timeoutSeconds: Double = 3
  ) {
    self.type = type
    self.url = url
    self.host = host
    self.port = port
    self.pid = pid
    // Keep the submitted value intact so `ServiceDefinition.validated()` can
    // reject non-finite or out-of-policy values. Runtime probes independently
    // apply their defensive timeout clamp before touching the network.
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct ServiceDefinition: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var group: String
  public var description: String
  public var enabled: Bool
  public var endpoints: [ServiceEndpoint]
  public var health: ServiceHealthCheck
  public var managementKind: ServiceManagementKind
  /// Local-only operator guidance.  It is intentionally not copied to
  /// snapshots or exposed as a runtime service field.
  public var recoveryNote: String
  public var notificationsMuted: Bool

  public init(
    id: String,
    name: String,
    group: String = "其他",
    description: String = "",
    enabled: Bool = true,
    endpoints: [ServiceEndpoint] = [],
    health: ServiceHealthCheck = .init(),
    managementKind: ServiceManagementKind = .unknown,
    recoveryNote: String = "",
    notificationsMuted: Bool = false
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.description = description
    self.enabled = enabled
    self.endpoints = endpoints
    self.health = health
    self.managementKind = managementKind
    self.recoveryNote = recoveryNote
    self.notificationsMuted = notificationsMuted
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, group, description, enabled, endpoints, health
    case managementKind, recoveryNote, notificationsMuted
  }

  /// Decode old catalog files that predate the editable management metadata.
  /// Unknown enum values are treated as `.unknown` so a newer catalog does
  /// not make an otherwise valid local definition unusable.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let managementKind: ServiceManagementKind
    if let raw = try container.decodeIfPresent(String.self, forKey: .managementKind) {
      managementKind = ServiceManagementKind(rawValue: raw) ?? .unknown
    } else {
      managementKind = .unknown
    }
    self.init(
      id: try container.decode(String.self, forKey: .id),
      name: try container.decode(String.self, forKey: .name),
      group: try container.decodeIfPresent(String.self, forKey: .group) ?? "其他",
      description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      endpoints: try container.decodeIfPresent([ServiceEndpoint].self, forKey: .endpoints) ?? [],
      health: try container.decodeIfPresent(ServiceHealthCheck.self, forKey: .health) ?? .init(),
      managementKind: managementKind,
      recoveryNote: try container.decodeIfPresent(String.self, forKey: .recoveryNote) ?? "",
      notificationsMuted: try container.decodeIfPresent(Bool.self, forKey: .notificationsMuted)
        ?? false
    )
  }

  public var ports: Set<Int> {
    var values = Set(endpoints.compactMap(\.port))
    switch health.type {
    case .http:
      if let url = health.url, let port = URL(string: url)?.port ?? URL(string: url)?.defaultPort {
        values.insert(port)
      }
    case .tcp:
      if let port = health.port { values.insert(port) }
    case .process, .none:
      // Process and none checks do not claim a listening port. In
      // particular, stale optional fields in old `.none` definitions must
      // not create a false cross-service conflict.
      break
    }
    return values
  }

  /// Hosts declared by the service configuration, canonicalized in the same
  /// way as listener hosts.  Matching a listener requires both a host and a
  /// port; an empty set means there is no reliable process attribution.
  public var hosts: Set<String> {
    var values = Set(endpoints.compactMap { $0.parsedURL?.host }.map(canonicalObservationHost))
    switch health.type {
    case .http:
      if let url = health.url, let host = URL(string: url)?.host {
        values.insert(canonicalObservationHost(host))
      }
    case .tcp:
      values.insert(canonicalObservationHost(health.host))
    case .process, .none:
      break
    }
    return values
  }

  public func validated() throws -> ServiceDefinition {
    guard id.count <= 128,
      id.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    else {
      throw LocalOpsError.invalidService("服务 id \(id) 无效")
    }
    guard name.count <= 200,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw LocalOpsError.invalidService("\(id) 缺少名称")
    }
    guard group.count <= 100,
      !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw LocalOpsError.invalidService("\(id) 的分组过长")
    }
    guard description.count <= 2_048 else {
      throw LocalOpsError.invalidService("\(id) 的描述过长")
    }
    guard recoveryNote.count <= 2_048 else {
      throw LocalOpsError.invalidService("\(id) 的恢复说明过长")
    }

    for endpoint in endpoints {
      guard endpoint.name.count <= 200,
        !endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        endpoint.url.count <= 2_048,
        !endpoint.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let url = URL(string: endpoint.url)
      else {
        throw LocalOpsError.invalidService("\(id) 的服务入口无效")
      }
      if let port = url.port, !(1...65_535).contains(port) {
        throw LocalOpsError.invalidService("\(id) 的服务入口端口无效")
      }
      guard localOpsAllowedLoopbackURL(url) else {
        throw LocalOpsError.invalidService("\(id) 的服务入口必须是本机 HTTP 地址")
      }
    }

    guard health.timeoutSeconds.isFinite,
      (1...30).contains(health.timeoutSeconds)
    else {
      throw LocalOpsError.invalidService("\(id) 的健康检查超时必须为 1 到 30 秒")
    }
    switch health.type {
    case .http:
      guard let rawURL = health.url,
        rawURL.count <= 2_048,
        !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let url = URL(string: rawURL)
      else {
        throw LocalOpsError.invalidService("\(id) 缺少有效 HTTP 健康地址")
      }
      if let port = url.port, !(1...65_535).contains(port) {
        throw LocalOpsError.invalidService("\(id) 的健康检查地址端口无效")
      }
      guard localOpsAllowedLoopbackURL(url) else {
        throw LocalOpsError.invalidService("\(id) 的健康检查地址必须是本机 HTTP 地址")
      }
    case .tcp:
      guard health.host.count <= 253,
        localOpsCanonicalLoopbackHost(health.host) != nil
      else {
        throw LocalOpsError.invalidService("\(id) 的 TCP 健康检查主机必须是本机")
      }
      guard let port = health.port, (1...65_535).contains(port) else {
        throw LocalOpsError.invalidService("\(id) 缺少有效 TCP 健康检查端口")
      }
    case .process:
      guard let pid = health.pid, (1...Int(Int32.max)).contains(pid) else {
        throw LocalOpsError.invalidService("\(id) 缺少有效进程 PID")
      }
    case .none:
      // No network/process probe is configured. Ignore legacy optional host,
      // URL, port, and PID fields rather than validating or claiming them as
      // runtime evidence.
      break
    }
    return self
  }
}

public struct ServiceSnapshot: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var group: String
  public var description: String
  public var source: ServiceSource
  public var lifecycle: ServiceLifecycle
  public var health: ServiceHealth
  public var endpoints: [ServiceEndpoint]
  public var latencyMs: Double?
  public var checkedAt: Date?
  public var message: String?
  public var pid: Int?
  public var processName: String?
  public var executablePath: String?
  public var workingDirectory: String?
  public var memoryMb: Double?
  public var cpuPercent: Double?
  public var presence: ServicePresence
  public var firstSeenAt: Date?
  public var lastSeenAt: Date?
  public var responseSummary: String?
  public var observation: ObservationEvidence

  public init(
    id: String,
    name: String,
    group: String,
    description: String,
    source: ServiceSource,
    lifecycle: ServiceLifecycle,
    health: ServiceHealth,
    endpoints: [ServiceEndpoint] = [],
    latencyMs: Double? = nil,
    checkedAt: Date? = nil,
    message: String? = nil,
    pid: Int? = nil,
    processName: String? = nil,
    executablePath: String? = nil,
    workingDirectory: String? = nil,
    memoryMb: Double? = nil,
    cpuPercent: Double? = nil,
    presence: ServicePresence = .online,
    firstSeenAt: Date? = nil,
    lastSeenAt: Date? = nil,
    responseSummary: String? = nil,
    observation: ObservationEvidence = .init()
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.description = description
    self.source = source
    self.lifecycle = lifecycle
    self.health = health
    self.endpoints = endpoints
    self.latencyMs = latencyMs
    self.checkedAt = checkedAt
    self.message = message
    self.pid = pid
    self.processName = processName
    self.executablePath = executablePath
    self.workingDirectory = workingDirectory
    self.memoryMb = memoryMb
    self.cpuPercent = cpuPercent
    // Unknown lifecycle must never be represented as online.  Keep the old
    // initializer source-compatible while making the invariant explicit.
    self.presence = lifecycle == .unknown && presence == .online ? .unknown : presence
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
    self.responseSummary = responseSummary
    self.observation = observation
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, group, description, source, lifecycle, health, endpoints
    case latencyMs, checkedAt, message, pid, processName, executablePath
    case workingDirectory, memoryMb, cpuPercent, presence, firstSeenAt
    case lastSeenAt, responseSummary, observation
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let lifecycle = try container.decode(ServiceLifecycle.self, forKey: .lifecycle)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      name: try container.decode(String.self, forKey: .name),
      group: try container.decode(String.self, forKey: .group),
      description: try container.decode(String.self, forKey: .description),
      source: try container.decode(ServiceSource.self, forKey: .source),
      lifecycle: lifecycle,
      health: try container.decode(ServiceHealth.self, forKey: .health),
      endpoints: try container.decodeIfPresent([ServiceEndpoint].self, forKey: .endpoints) ?? [],
      latencyMs: try container.decodeIfPresent(Double.self, forKey: .latencyMs),
      checkedAt: try container.decodeIfPresent(Date.self, forKey: .checkedAt),
      message: try container.decodeIfPresent(String.self, forKey: .message),
      pid: try container.decodeIfPresent(Int.self, forKey: .pid),
      processName: try container.decodeIfPresent(String.self, forKey: .processName),
      executablePath: try container.decodeIfPresent(String.self, forKey: .executablePath),
      workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
      memoryMb: try container.decodeIfPresent(Double.self, forKey: .memoryMb),
      cpuPercent: try container.decodeIfPresent(Double.self, forKey: .cpuPercent),
      presence: try container.decodeIfPresent(ServicePresence.self, forKey: .presence)
        ?? (lifecycle == .unknown ? .unknown : .online),
      firstSeenAt: try container.decodeIfPresent(Date.self, forKey: .firstSeenAt),
      lastSeenAt: try container.decodeIfPresent(Date.self, forKey: .lastSeenAt),
      responseSummary: try container.decodeIfPresent(String.self, forKey: .responseSummary),
      observation: try container.decodeIfPresent(ObservationEvidence.self, forKey: .observation)
        ?? ObservationEvidence(
          state: lifecycle == .unknown ? .unknown : .notObserved,
          freshness: .stale
        )
    )
  }
}

public struct LocalOpsSummary: Codable, Equatable, Sendable {
  public var total: Int
  public var healthy: Int
  public var attention: Int
  public var stopped: Int
  public var discovered: Int
  public var offlineHistory: Int
  public var unknown: Int
  public var stale: Int

  public init(
    total: Int,
    healthy: Int,
    attention: Int,
    stopped: Int,
    discovered: Int,
    offlineHistory: Int,
    unknown: Int = 0,
    stale: Int = 0
  ) {
    self.total = total
    self.healthy = healthy
    self.attention = attention
    self.stopped = stopped
    self.discovered = discovered
    self.offlineHistory = offlineHistory
    self.unknown = unknown
    self.stale = stale
  }

  public static let empty = LocalOpsSummary(
    total: 0,
    healthy: 0,
    attention: 0,
    stopped: 0,
    discovered: 0,
    offlineHistory: 0,
    unknown: 0,
    stale: 0
  )

  private enum CodingKeys: String, CodingKey {
    case total, healthy, attention, stopped, discovered, offlineHistory, unknown, stale
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      total: try container.decode(Int.self, forKey: .total),
      healthy: try container.decode(Int.self, forKey: .healthy),
      attention: try container.decode(Int.self, forKey: .attention),
      stopped: try container.decode(Int.self, forKey: .stopped),
      discovered: try container.decode(Int.self, forKey: .discovered),
      offlineHistory: try container.decode(Int.self, forKey: .offlineHistory),
      unknown: try container.decodeIfPresent(Int.self, forKey: .unknown) ?? 0,
      stale: try container.decodeIfPresent(Int.self, forKey: .stale) ?? 0
    )
  }
}

public enum LocalOpsThermalState: String, Codable, Equatable, Sendable {
  case nominal
  case fair
  case serious
  case critical
  case unknown
}

public struct LocalOpsSystemMetrics: Codable, Equatable, Sendable {
  public var memoryUsedGb: Double
  public var memoryTotalGb: Double
  public var memoryPercent: Double
  public var diskFreeGb: Double
  public var diskTotalGb: Double
  public var diskPercent: Double
  public var cpuLoadOneMinute: Double
  public var cpuLoadFiveMinutes: Double
  public var cpuLoadFifteenMinutes: Double
  public var logicalProcessorCount: Int
  public var uptimeSeconds: Int
  public var thermalState: LocalOpsThermalState

  public static let empty = LocalOpsSystemMetrics(
    memoryUsedGb: 0,
    memoryTotalGb: 0,
    memoryPercent: 0,
    diskFreeGb: 0,
    diskTotalGb: 0,
    diskPercent: 0,
    cpuLoadOneMinute: 0,
    cpuLoadFiveMinutes: 0,
    cpuLoadFifteenMinutes: 0,
    logicalProcessorCount: 0,
    uptimeSeconds: 0,
    thermalState: .unknown
  )
}

public struct LocalOpsEvent: Codable, Identifiable, Hashable, Sendable {
  public var id: Int64
  public var occurredAt: Date
  public var serviceId: String
  public var serviceName: String
  public var kind: String
  public var severity: String
  public var message: String
}

public struct LocalOpsOverview: Codable, Equatable, Sendable {
  public var services: [ServiceSnapshot]
  public var summary: LocalOpsSummary
  public var system: LocalOpsSystemMetrics
  public var groups: [String]
  public var events: [LocalOpsEvent]
  public var refreshedAt: Date?
  public var error: String?
  public var metadata: SnapshotMetadata

  public init(
    services: [ServiceSnapshot],
    summary: LocalOpsSummary,
    system: LocalOpsSystemMetrics,
    groups: [String],
    events: [LocalOpsEvent],
    refreshedAt: Date?,
    error: String?,
    metadata: SnapshotMetadata = .empty
  ) {
    self.services = services
    self.summary = summary
    self.system = system
    self.groups = groups
    self.events = events
    self.refreshedAt = refreshedAt
    self.error = error
    self.metadata = metadata
  }

  public static let empty = LocalOpsOverview(
    services: [],
    summary: .empty,
    system: .empty,
    groups: [],
    events: [],
    refreshedAt: nil,
    error: nil,
    metadata: .empty
  )

  private enum CodingKeys: String, CodingKey {
    case services, summary, system, groups, events, refreshedAt, error, metadata
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      services: try container.decodeIfPresent([ServiceSnapshot].self, forKey: .services) ?? [],
      summary: try container.decodeIfPresent(LocalOpsSummary.self, forKey: .summary) ?? .empty,
      system: try container.decodeIfPresent(LocalOpsSystemMetrics.self, forKey: .system) ?? .empty,
      groups: try container.decodeIfPresent([String].self, forKey: .groups) ?? [],
      events: try container.decodeIfPresent([LocalOpsEvent].self, forKey: .events) ?? [],
      refreshedAt: try container.decodeIfPresent(Date.self, forKey: .refreshedAt),
      error: try container.decodeIfPresent(String.self, forKey: .error),
      metadata: try container.decodeIfPresent(SnapshotMetadata.self, forKey: .metadata) ?? .empty
    )
  }
}

extension LocalOpsOverview {
  /// Produce a deterministic readiness projection from Core metadata. The
  /// caller should pass `2 * pollInterval` for `staleAfter`; invalid values
  /// use a conservative 30-second default and very large values are bounded.
  public func snapshotProjection(
    now: Date = Date(),
    staleAfter: TimeInterval = 30
  ) -> LocalOpsSnapshotProjection {
    let normalizedStaleAfter = normalizedProjectionStaleAfter(staleAfter)
    let metadata = self.metadata
    let successfulAt = metadata.successfulAt ?? refreshedAt
    let hasSuccessfulSnapshot = successfulAt != nil
    let age = successfulAt.map { max(0, now.timeIntervalSince($0)) }
    let agedOut = age.map { $0.isFinite && $0 > normalizedStaleAfter } ?? false
    let failure = metadata.outcome == .failed
    let error = metadata.error ?? self.error
    let failureWithoutSuccess = failure && !hasSuccessfulSnapshot
    let initializationAttempted = metadata.attemptedAt != nil || error != nil

    let effectiveFreshness: ObservationFreshness
    if agedOut || (failure && hasSuccessfulSnapshot) || metadata.freshness == .stale {
      effectiveFreshness = .stale
    } else {
      effectiveFreshness = metadata.freshness
    }

    let state: LocalOpsSnapshotState
    if failureWithoutSuccess && initializationAttempted {
      state = .coreError
    } else if agedOut || effectiveFreshness == .stale {
      state = .stale
    } else if !hasSuccessfulSnapshot {
      state =
        metadata.freshness == .partial || metadata.outcome == .partial
        ? .partial : .starting
    } else if effectiveFreshness == .partial
      || metadata.outcome == .partial
      || effectiveFreshness == .unknown
    {
      // Unknown observations are never promoted to a fresh/ready state.
      state = .partial
    } else if services.isEmpty {
      state = .empty
    } else {
      state = .fresh
    }

    let ready =
      metadata.generation > 0
      && hasSuccessfulSnapshot
      && !agedOut
      && metadata.outcome != .failed
      && (effectiveFreshness == .fresh || effectiveFreshness == .partial)

    return LocalOpsSnapshotProjection(
      state: state,
      generation: metadata.generation,
      attemptedAt: metadata.attemptedAt,
      successfulAt: successfulAt,
      age: age,
      error: error,
      outcome: metadata.outcome,
      freshness: effectiveFreshness,
      ready: ready
    )
  }
}

public struct DefaultServiceCatalog: Codable, Sendable {
  public var version: Int
  public var services: [ServiceDefinition]
}

public enum LocalOpsError: LocalizedError, Sendable {
  case invalidService(String)
  case resourceMissing(String)
  case commandFailed(String)
  case notInitialized

  public var errorDescription: String? {
    switch self {
    case .invalidService(let message), .commandFailed(let message): message
    case .resourceMissing(let name): "缺少资源文件：\(name)"
    case .notInitialized: "LocalOps 尚未初始化"
    }
  }
}

extension URL {
  fileprivate var defaultPort: Int? {
    switch scheme?.lowercased() {
    case "http": 80
    case "https": 443
    default: nil
    }
  }
}

private func canonicalObservationHost(_ host: String) -> String {
  let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    .lowercased()
  switch value {
  case "*", "0.0.0.0", "::", "::1", "localhost": return "127.0.0.1"
  default: return value
  }
}

private func normalizedProjectionStaleAfter(_ value: TimeInterval) -> TimeInterval {
  guard value.isFinite, value > 0 else { return 30 }
  return min(value, 7 * 24 * 60 * 60)
}

/// Canonicalize the loopback spellings used by local service definitions and
/// listener observations. Unspecified/wildcard bindings are retained for
/// compatibility and normalize to the local loopback address.
func localOpsCanonicalLoopbackHost(_ host: String) -> String? {
  let value = canonicalObservationHost(host)
  return value == "127.0.0.1" ? value : nil
}

/// Validate a URL before it is used by a local health probe or displayed as a
/// configured endpoint. Keeping this pure and internal lets the runtime probe
/// apply the same boundary as `ServiceDefinition.validated()`.
func localOpsAllowedLoopbackURL(_ url: URL) -> Bool {
  guard ["http", "https"].contains(url.scheme?.lowercased()),
    url.user == nil,
    url.password == nil,
    let host = url.host,
    host.count <= 253,
    !host.contains(where: { $0.isWhitespace || $0.isNewline }),
    localOpsCanonicalLoopbackHost(host) != nil
  else { return false }
  return true
}
