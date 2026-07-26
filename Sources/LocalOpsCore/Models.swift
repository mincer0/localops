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
}

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
    self.timeoutSeconds = min(max(timeoutSeconds, 0.2), 30)
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

  public init(
    id: String,
    name: String,
    group: String = "其他",
    description: String = "",
    enabled: Bool = true,
    endpoints: [ServiceEndpoint] = [],
    health: ServiceHealthCheck = .init()
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.description = description
    self.enabled = enabled
    self.endpoints = endpoints
    self.health = health
  }

  public var ports: Set<Int> {
    var values = Set(endpoints.compactMap(\.port))
    if let port = health.port { values.insert(port) }
    if let url = health.url, let port = URL(string: url)?.port ?? URL(string: url)?.defaultPort {
      values.insert(port)
    }
    return values
  }

  public func validated() throws -> ServiceDefinition {
    guard id.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else {
      throw LocalOpsError.invalidService("服务 id \(id) 无效")
    }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalOpsError.invalidService("\(id) 缺少名称")
    }
    if health.type == .http {
      guard let rawURL = health.url, let url = URL(string: rawURL), url.host != nil else {
        throw LocalOpsError.invalidService("\(id) 的 HTTP 健康地址无效")
      }
    }
    if health.type == .tcp, !(1...65_535).contains(health.port ?? 0) {
      throw LocalOpsError.invalidService("\(id) 的 TCP 端口无效")
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
    responseSummary: String? = nil
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
    self.presence = presence
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
    self.responseSummary = responseSummary
  }
}

public struct LocalOpsSummary: Codable, Equatable, Sendable {
  public var total: Int
  public var healthy: Int
  public var attention: Int
  public var stopped: Int
  public var discovered: Int
  public var offlineHistory: Int

  public static let empty = LocalOpsSummary(
    total: 0,
    healthy: 0,
    attention: 0,
    stopped: 0,
    discovered: 0,
    offlineHistory: 0
  )
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

  public static let empty = LocalOpsOverview(
    services: [],
    summary: .empty,
    system: .empty,
    groups: [],
    events: [],
    refreshedAt: nil,
    error: nil
  )
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
