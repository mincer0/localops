import Darwin
import FlyingFox
import FlyingSocks
import Foundation
import LocalOpsCore

public enum LocalWebServerState: Equatable, Sendable {
  case stopped
  case starting
  case running(URL)
  case failed(String)

  public var url: URL? {
    if case .running(let url) = self { return url }
    return nil
  }
}

public actor LocalWebServer {
  private let engine: LocalOpsEngine
  private let requestedPort: UInt16
  private let assets: WebAssets
  private var staleAfter: TimeInterval
  private var server: HTTPServer?
  private var runTask: Task<Void, Never>?
  private var currentState: LocalWebServerState = .stopped

  public init(
    engine: LocalOpsEngine,
    port: UInt16 = 8042,
    staleAfter: TimeInterval = 30
  ) throws {
    self.engine = engine
    self.requestedPort = port
    self.assets = try WebAssets.load()
    self.staleAfter = normalizedStaleAfter(staleAfter)
  }

  public func state() -> LocalWebServerState {
    currentState
  }

  public func setStaleAfter(_ value: TimeInterval) {
    staleAfter = normalizedStaleAfter(value)
  }

  @discardableResult
  public func start() async -> LocalWebServerState {
    switch currentState {
    case .starting, .running:
      return currentState
    case .stopped, .failed:
      break
    }

    currentState = .starting
    do {
      let address: sockaddr_in = try .inet(ip4: "127.0.0.1", port: requestedPort)
      try ensurePortAvailable(address, port: requestedPort)
      let server = HTTPServer(address: address, logger: .disabled)
      await installRoutes(on: server)
      self.server = server
      let task = Task { [weak self, server] in
        do {
          try await server.run()
        } catch {
          guard !Task.isCancelled else { return }
          await self?.recordFailure(error)
        }
      }
      runTask = task
      try await server.waitUntilListening(timeout: 3)
      let port = await listeningPort(of: server) ?? requestedPort
      let url = URL(string: "http://127.0.0.1:\(port)")!
      currentState = .running(url)
    } catch {
      runTask?.cancel()
      runTask = nil
      if let server { await server.stop() }
      server = nil
      currentState = .failed(webServerError(error, requestedPort: requestedPort))
    }
    return currentState
  }

  public func stop(timeout: TimeInterval = 1) async {
    runTask?.cancel()
    runTask = nil
    if let server { await server.stop(timeout: min(max(timeout, 0), 2)) }
    server = nil
    currentState = .stopped
  }

  private func recordFailure(_ error: Error) {
    currentState = .failed(webServerError(error, requestedPort: requestedPort))
    server = nil
    runTask = nil
  }

  private func installRoutes(on server: HTTPServer) async {
    let engine = self.engine
    let assets = self.assets
    let owner = self

    await server.appendRoute("GET /") { _ in
      htmlResponse(assets.index)
    }
    await server.appendRoute("GET /static/localops.css") { _ in
      assetResponse(assets.css, contentType: "text/css; charset=utf-8")
    }
    await server.appendRoute("GET /static/localops.js") { _ in
      assetResponse(assets.javascript, contentType: "text/javascript; charset=utf-8")
    }
    await server.appendRoute("GET /healthz") { _ in
      jsonResponse(Data(#"{"status":"ok"}"#.utf8))
    }
    await server.appendRoute("GET /readyz") { _ in
      let overview = await engine.overview()
      let projection = await owner.projection(for: overview)
      let readiness = readinessPayload(projection: projection, staleAfter: await owner.staleAfter)
      return jsonResponse(
        try encodeAPI(readiness),
        status: readiness.ready ? .ok : .serviceUnavailable
      )
    }
    await server.appendRoute("GET /api/v1/overview") { _ in
      let overview = await engine.overview()
      let staleAfter = await owner.staleAfter
      let projection = overview.snapshotProjection(now: Date(), staleAfter: staleAfter)
      return jsonResponse(
        try encodeAPI(
          OverviewDTO(overview, projection: projection, staleAfter: staleAfter)
        )
      )
    }
    await server.appendRoute("GET /api/v1/services") { _ in
      let overview = await engine.overview()
      let projection = await owner.projection(for: overview)
      return jsonResponse(
        try encodeAPI(overview.services.map { ServiceDTO($0, projection: projection) })
      )
    }
    await server.appendRoute("GET /api/v1/services/:id") { request in
      let overview = await engine.overview()
      guard let id = request.routeParameters["id"],
        let service = overview.services.first(where: { $0.id == id })
      else {
        return jsonResponse(
          Data(#"{"detail":"Service not found"}"#.utf8),
          status: .notFound
        )
      }
      let projection = await owner.projection(for: overview)
      return jsonResponse(try encodeAPI(ServiceDTO(service, projection: projection)))
    }
    await server.appendRoute("GET /api/v1/events") { _ in
      let overview = await engine.overview()
      return jsonResponse(try encodeAPI(overview.events.map(EventDTO.init)))
    }
  }

  private func projection(for overview: LocalOpsOverview) -> LocalOpsSnapshotProjection {
    overview.snapshotProjection(now: Date(), staleAfter: staleAfter)
  }
}

private struct WebAssets: Sendable {
  var index: Data
  var css: Data
  var javascript: Data

  static func load() throws -> WebAssets {
    WebAssets(
      index: try resource(named: "index", extension: "html"),
      css: try resource(named: "localops", extension: "css"),
      javascript: try resource(named: "localops", extension: "js")
    )
  }

  private static func resource(named name: String, extension fileExtension: String) throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Web"
      ) ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    else {
      throw LocalOpsError.resourceMissing("\(name).\(fileExtension)")
    }
    return try Data(contentsOf: url)
  }
}

private func listeningPort(of server: HTTPServer) async -> UInt16? {
  switch await server.listeningAddress {
  case .ip4(_, let port), .ip6(_, let port): port
  default: nil
  }
}

private func normalizedStaleAfter(_ value: TimeInterval) -> TimeInterval {
  guard value.isFinite else { return 30 }
  return min(3_600, max(1, value))
}

private func ensurePortAvailable(_ address: sockaddr_in, port: UInt16) throws {
  // Port zero asks the kernel to choose an ephemeral port and can never
  // conflict ahead of time. For a fixed port, probe the exact loopback bind
  // before starting FlyingFox so an occupied port fails immediately with an
  // actionable diagnostic instead of waiting for its listening timeout.
  guard port != 0 else { return }
  let probe = try Socket(domain: Int32(AF_INET))
  defer { try? probe.close() }
  try probe.setValue(true, for: .localAddressReuse)
  do {
    try probe.bind(to: address)
  } catch let error as SocketError {
    if case .failed(_, let errno, _) = error, errno == EADDRINUSE {
      throw WebServerStartupError.portInUse
    }
    throw error
  }
}

private enum WebServerStartupError: LocalizedError {
  case portInUse

  var errorDescription: String? {
    switch self {
    case .portInUse: "Web 端口已被占用"
    }
  }
}

private func encodeAPI<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(value)
}

private struct OverviewDTO: Encodable {
  let services: [ServiceDTO]
  let summary: LocalOpsSummary
  let system: LocalOpsSystemMetrics
  let groups: [String]
  let events: [EventDTO]
  let refreshedAt: Date?
  let error: String?
  let metadata: MetadataDTO
  let typedState: SnapshotStateDTO

  init(
    _ overview: LocalOpsOverview,
    projection: LocalOpsSnapshotProjection,
    staleAfter: TimeInterval
  ) {
    services = overview.services.map { ServiceDTO($0, projection: projection) }
    summary = overview.summary
    system = overview.system
    groups = overview.groups
    events = overview.events.map(EventDTO.init)
    refreshedAt = overview.refreshedAt
    error = redact(overview.error)
    metadata = MetadataDTO(overview.metadata)
    typedState = SnapshotStateDTO(projection, staleAfter: staleAfter)
  }
}

private struct ServiceDTO: Encodable {
  let id: String
  let name: String
  let group: String
  let description: String
  let source: ServiceSource
  let lifecycle: ServiceLifecycle
  let health: ServiceHealth
  let endpoints: [ServiceEndpointDTO]
  let latencyMs: Double?
  let checkedAt: Date?
  let message: String?
  let pid: Int?
  let processName: String?
  let memoryMb: Double?
  let cpuPercent: Double?
  let presence: ServicePresence
  let firstSeenAt: Date?
  let lastSeenAt: Date?
  let observation: ObservationDTO
  let typedState: ServiceStateDTO

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case group
    case description
    case source
    case lifecycle
    case health
    case endpoints
    case latencyMs
    case checkedAt
    case message
    case pid
    case processName
    case memoryMb
    case cpuPercent
    case executablePath
    case workingDirectory
    case responseSummary
    case presence
    case firstSeenAt
    case lastSeenAt
    case observation
    case typedState
    case privacyRedacted
  }

  init(_ service: ServiceSnapshot, projection: LocalOpsSnapshotProjection) {
    id = service.id
    name = redact(service.name) ?? service.name
    group = redact(service.group) ?? service.group
    description = redact(service.description) ?? service.description
    source = service.source
    lifecycle = service.lifecycle
    health = service.health
    endpoints = service.endpoints.map(ServiceEndpointDTO.init)
    latencyMs = service.latencyMs
    checkedAt = service.checkedAt
    message = redact(service.message)
    pid = service.pid
    processName = redact(service.processName)
    memoryMb = service.memoryMb
    cpuPercent = service.cpuPercent
    presence = service.presence
    firstSeenAt = service.firstSeenAt
    lastSeenAt = service.lastSeenAt
    observation = ObservationDTO(service.observation)
    typedState = ServiceStateDTO(service, projection: projection)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(group, forKey: .group)
    try container.encode(description, forKey: .description)
    try container.encode(source, forKey: .source)
    try container.encode(lifecycle, forKey: .lifecycle)
    try container.encode(health, forKey: .health)
    try container.encode(endpoints, forKey: .endpoints)
    try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
    try container.encodeIfPresent(checkedAt, forKey: .checkedAt)
    try container.encodeIfPresent(message, forKey: .message)
    try container.encodeIfPresent(pid, forKey: .pid)
    try container.encodeIfPresent(processName, forKey: .processName)
    try container.encodeIfPresent(memoryMb, forKey: .memoryMb)
    try container.encodeIfPresent(cpuPercent, forKey: .cpuPercent)

    // Keep the historical keys for clients that decode them, but never leak
    // the sensitive process path, working directory, or raw response.
    try container.encodeNil(forKey: .executablePath)
    try container.encodeNil(forKey: .workingDirectory)
    try container.encodeNil(forKey: .responseSummary)
    try container.encode(presence, forKey: .presence)
    try container.encodeIfPresent(firstSeenAt, forKey: .firstSeenAt)
    try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
    try container.encode(observation, forKey: .observation)
    try container.encode(typedState, forKey: .typedState)
    try container.encode(true, forKey: .privacyRedacted)
  }
}

private struct ServiceEndpointDTO: Encodable {
  let name: String
  let url: String

  init(_ endpoint: ServiceEndpoint) {
    name = redact(endpoint.name) ?? endpoint.name
    url = safeURL(endpoint.url)
  }
}

private struct ObservationDTO: Encodable {
  let state: ObservationState
  let freshness: ObservationFreshness
  let matchConfidence: ObservationMatchConfidence
  let host: String?
  let port: Int?
  let pid: Int?
  let processName: String?
  let observedAt: Date?
  let message: String?

  init(_ observation: ObservationEvidence) {
    state = observation.state
    freshness = observation.freshness
    matchConfidence = observation.matchConfidence
    host = observation.host
    port = observation.port
    pid = observation.pid
    processName = redact(observation.processName)
    observedAt = observation.observedAt
    message = redact(observation.message)
  }
}

private struct MetadataDTO: Encodable {
  let generation: Int64
  let attemptedAt: Date?
  let successfulAt: Date?
  let freshness: ObservationFreshness
  let outcome: SnapshotOutcome
  let error: String?

  init(_ metadata: SnapshotMetadata) {
    generation = metadata.generation
    attemptedAt = metadata.attemptedAt
    successfulAt = metadata.successfulAt
    freshness = metadata.freshness
    outcome = metadata.outcome
    error = redact(metadata.error)
  }
}

private struct SnapshotStateDTO: Encodable {
  let kind: String
  let freshness: ObservationFreshness
  let outcome: SnapshotOutcome
  let generation: Int64
  let ready: Bool
  let ageSeconds: Double?
  let staleAfterSeconds: Double
  let error: String?

  init(_ projection: LocalOpsSnapshotProjection, staleAfter: TimeInterval) {
    kind = projection.state.rawValue
    freshness = projection.freshness
    outcome = projection.outcome
    generation = projection.generation
    ready = projection.ready
    ageSeconds = projection.age
    staleAfterSeconds = staleAfter
    error = redact(projection.error)
  }
}

private struct ServiceStateDTO: Encodable {
  let kind: String
  let snapshotState: LocalOpsSnapshotState
  let snapshotReady: Bool
  let lifecycle: ServiceLifecycle
  let health: ServiceHealth
  let presence: ServicePresence
  let observationState: ObservationState
  let freshness: ObservationFreshness
  let matchConfidence: ObservationMatchConfidence

  init(_ service: ServiceSnapshot, projection: LocalOpsSnapshotProjection) {
    snapshotState = projection.state
    snapshotReady = projection.ready
    lifecycle = service.lifecycle
    health = service.health
    presence = service.presence
    observationState = service.observation.state
    freshness = service.observation.freshness
    matchConfidence = service.observation.matchConfidence
    if service.lifecycle == .stopped || service.presence == .offline {
      kind = "offline"
    } else if service.health == .unhealthy {
      kind = "unhealthy"
    } else if service.health == .degraded {
      kind = "degraded"
    } else if service.health == .unknown || service.observation.state == .unknown {
      kind = "unknown"
    } else if service.observation.freshness != .fresh {
      kind = "stale"
    } else {
      kind = "healthy"
    }
  }
}

private struct EventDTO: Encodable {
  let id: Int64
  let occurredAt: Date
  let serviceId: String
  let serviceName: String
  let kind: String
  let severity: String
  let message: String

  init(_ event: LocalOpsEvent) {
    id = event.id
    occurredAt = event.occurredAt
    serviceId = event.serviceId
    serviceName = redact(event.serviceName) ?? event.serviceName
    kind = event.kind
    severity = event.severity
    message = redact(event.message) ?? event.message
  }
}

private struct ReadinessDTO: Encodable {
  let ready: Bool
  let status: String
  let state: String
  let generation: Int64
  let successfulAt: Date?
  let freshness: ObservationFreshness
  let error: String?
  let ageSeconds: Double?
  let staleAfterSeconds: Double
}

private func readinessPayload(
  projection: LocalOpsSnapshotProjection,
  staleAfter: TimeInterval
) -> ReadinessDTO {
  return ReadinessDTO(
    ready: projection.ready,
    status: projection.ready ? "ready" : "not_ready",
    state: projection.state.rawValue,
    generation: projection.generation,
    successfulAt: projection.successfulAt,
    freshness: projection.freshness,
    error: redact(projection.error),
    ageSeconds: projection.age,
    staleAfterSeconds: staleAfter
  )
}

private func safeURL(_ raw: String) -> String {
  guard var components = URLComponents(string: raw) else {
    return redact(raw) ?? raw
  }
  components.query = nil
  components.fragment = nil
  return components.string ?? (redact(raw) ?? raw)
}

private func redact(_ value: String?) -> String? {
  guard let value else { return nil }
  var result = value
  result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  result = result.replacingOccurrences(
    of: #"/Users/[^/\s]+"#,
    with: "~",
    options: .regularExpression
  )
  result = result.replacingOccurrences(
    of: #"(?i)(token|secret|password|authorization)=([^&\s]+)"#,
    with: "$1=REDACTED",
    options: .regularExpression
  )
  return String(result.prefix(1_024))
}

private func webServerError(_ error: Error, requestedPort: UInt16) -> String {
  let raw = error.localizedDescription
  if error is WebServerStartupError
    || raw.localizedCaseInsensitiveContains("address already in use")
    || raw.localizedCaseInsensitiveContains("already in use")
  {
    return "127.0.0.1:\(requestedPort) 已被占用；请关闭占用程序后重试。"
  }
  return redact(raw) ?? "只读 Web 启动失败"
}

private func baseHeaders(contentType: String) -> HTTPHeaders {
  [
    .contentType: contentType,
    .cacheControl: "no-store",
    HTTPHeader("X-Content-Type-Options"): "nosniff",
    HTTPHeader("Referrer-Policy"): "no-referrer",
  ]
}

private func htmlResponse(_ data: Data) -> HTTPResponse {
  var headers = baseHeaders(contentType: "text/html; charset=utf-8")
  headers[HTTPHeader("Content-Security-Policy")] =
    "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'"
  return HTTPResponse(statusCode: .ok, headers: headers, body: data)
}

private func assetResponse(_ data: Data, contentType: String) -> HTTPResponse {
  HTTPResponse(statusCode: .ok, headers: baseHeaders(contentType: contentType), body: data)
}

private func jsonResponse(
  _ data: Data,
  status: HTTPStatusCode = .ok
) -> HTTPResponse {
  HTTPResponse(
    statusCode: status,
    headers: baseHeaders(contentType: "application/json; charset=utf-8"),
    body: data
  )
}
