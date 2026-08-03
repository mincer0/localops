import Darwin
import Foundation
import Network

public struct ProbeResult: Hashable, Sendable {
  public var lifecycle: ServiceLifecycle
  public var health: ServiceHealth
  public var latencyMs: Double?
  public var checkedAt: Date
  public var message: String?
  public var responseSummary: String?
  public var freshness: ObservationFreshness
  public var statusCode: Int?

  public init(
    lifecycle: ServiceLifecycle,
    health: ServiceHealth,
    latencyMs: Double? = nil,
    checkedAt: Date = Date(),
    message: String? = nil,
    responseSummary: String? = nil,
    freshness: ObservationFreshness = .fresh,
    statusCode: Int? = nil
  ) {
    self.lifecycle = lifecycle
    self.health = health
    self.latencyMs = latencyMs
    self.checkedAt = checkedAt
    self.message = message
    self.responseSummary = responseSummary
    self.freshness = freshness
    self.statusCode = statusCode
  }
}

public protocol HealthChecking: Sendable {
  func probe(_ check: ServiceHealthCheck) async -> ProbeResult
}

public struct SystemHealthChecker: HealthChecking {
  private let session: URLSession
  private let maxResponseBytes: Int

  public init(session: URLSession? = nil, maxResponseBytes: Int = 64 * 1_024) {
    self.maxResponseBytes = max(1_024, maxResponseBytes)
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.httpMaximumConnectionsPerHost = 2
      self.session = URLSession(
        configuration: configuration,
        delegate: LocalOpsRedirectDelegate(),
        delegateQueue: nil
      )
    }
  }

  public func probe(_ check: ServiceHealthCheck) async -> ProbeResult {
    switch check.type {
    case .http:
      return await probeHTTP(check)
    case .tcp:
      return await probeTCP(check)
    case .process:
      return probeProcess(check)
    case .none:
      return ProbeResult(
        lifecycle: .unknown,
        health: .unknown,
        message: "未配置健康检查",
        freshness: .unknown
      )
    }
  }

  private func probeHTTP(_ check: ServiceHealthCheck) async -> ProbeResult {
    guard let rawURL = check.url,
      let url = URL(string: rawURL),
      localOpsAllowedLoopbackURL(url)
    else {
      return ProbeResult(lifecycle: .unknown, health: .unknown, message: "HTTP 地址无效")
    }
    let started = ContinuousClock.now
    var request = URLRequest(url: url)
    request.timeoutInterval = safeTimeout(check.timeoutSeconds)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(localOpsUserAgent(), forHTTPHeaderField: "User-Agent")
    do {
      let (data, response) = try await readResponse(for: request, maxBytes: maxResponseBytes)
      let latency = milliseconds(since: started)
      guard let http = response as? HTTPURLResponse else {
        return ProbeResult(
          lifecycle: .running,
          health: .unhealthy,
          latencyMs: latency,
          message: "无法识别 HTTP 响应",
          freshness: .partial
        )
      }
      guard let responseURL = http.url,
        localOpsAllowedLoopbackURL(responseURL),
        localOpsCanonicalLoopbackHost(responseURL.host ?? "")
          == localOpsCanonicalLoopbackHost(url.host ?? "")
      else {
        return ProbeResult(
          lifecycle: .unknown,
          health: .unknown,
          latencyMs: latency,
          message: "健康检查重定向到非本机地址",
          freshness: .partial,
          statusCode: http.statusCode
        )
      }
      let summary = responseSummary(data: data, response: http)
      let declaredStatus = declaredHealthStatus(in: data)
      // A redirect is not a successful local health check. The redirect
      // delegate refuses to follow it, and 3xx responses must remain visible
      // as an unhealthy result with their status code/reason preserved.
      if (200..<300).contains(http.statusCode) {
        return ProbeResult(
          lifecycle: .running,
          health: declaredStatus == "degraded" || declaredStatus == "warning"
            ? .degraded : .healthy,
          latencyMs: latency,
          responseSummary: summary,
          statusCode: http.statusCode
        )
      }
      return ProbeResult(
        lifecycle: .running,
        health: .unhealthy,
        latencyMs: latency,
        message: "HTTP \(http.statusCode)",
        responseSummary: summary,
        statusCode: http.statusCode
      )
    } catch {
      return ProbeResult(
        lifecycle: isCancellation(error) ? .unknown : .stopped,
        health: .unhealthy,
        latencyMs: milliseconds(since: started),
        message: readableNetworkError(error),
        freshness: .partial
      )
    }
  }

  private func probeTCP(_ check: ServiceHealthCheck) async -> ProbeResult {
    guard let rawPort = check.port,
      (1...65_535).contains(rawPort),
      let host = localOpsCanonicalLoopbackHost(check.host),
      let port = NWEndpoint.Port(rawValue: UInt16(rawPort))
    else {
      return ProbeResult(lifecycle: .unknown, health: .unknown, message: "TCP 地址或端口无效")
    }
    let started = ContinuousClock.now
    let connected = await TCPProbe.connect(
      host: NWEndpoint.Host(host),
      port: port,
      timeout: safeTimeout(check.timeoutSeconds)
    )
    return ProbeResult(
      lifecycle: connected ? .running : .stopped,
      health: connected ? .healthy : .unhealthy,
      latencyMs: milliseconds(since: started),
      message: connected ? nil : "无法连接本机 (check.host):(rawPort)"
    )
  }

  private func probeProcess(_ check: ServiceHealthCheck) -> ProbeResult {
    guard let pid = check.pid, pid > 0, pid <= Int(Int32.max) else {
      return ProbeResult(lifecycle: .unknown, health: .unknown, message: "PID 无效")
    }
    errno = 0
    let alive = kill(pid_t(pid), 0) == 0 || errno == EPERM
    return ProbeResult(
      lifecycle: alive ? .running : .stopped,
      health: alive ? .healthy : .unhealthy,
      message: alive ? nil : "PID (pid) 不存在"
    )
  }
}

private func readHTTPResponse(
  for request: URLRequest,
  maxBytes: Int,
  session: URLSession
) async throws -> (Data, URLResponse) {
  let (bytes, response) = try await session.bytes(for: request)
  var data = Data()
  data.reserveCapacity(min(maxBytes, 8 * 1_024))
  for try await byte in bytes {
    try Task.checkCancellation()
    guard data.count < maxBytes else { throw HealthCheckError.responseTooLarge }
    data.append(byte)
  }
  return (data, response)
}

extension SystemHealthChecker {
  fileprivate func readResponse(for request: URLRequest, maxBytes: Int) async throws -> (
    Data, URLResponse
  ) {
    try await readHTTPResponse(for: request, maxBytes: maxBytes, session: session)
  }
}

private enum HealthCheckError: Error {
  case responseTooLarge
}

private final class LocalOpsRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private enum TCPProbe {
  static func connect(host: NWEndpoint.Host, port: NWEndpoint.Port, timeout: Double) async -> Bool {
    let holder = TCPProbeHolder()
    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { continuation in
          let connection = NWConnection(host: host, port: port, using: .tcp)
          let gate = TCPProbeGate(continuation: continuation, connection: connection)
          holder.install(gate)
          if Task.isCancelled {
            gate.finish(false)
            return
          }
          connection.stateUpdateHandler = { state in
            switch state {
            case .ready: gate.finish(true)
            case .failed, .cancelled: gate.finish(false)
            default: break
            }
          }
          let queue = DispatchQueue(label: "io.github.mincer0.localops.tcp-probe")
          connection.start(queue: queue)
          queue.asyncAfter(deadline: .now() + safeTimeout(timeout)) {
            gate.finish(false)
          }
        }
      },
      onCancel: {
        holder.cancel()
      })
  }
}

private final class TCPProbeHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var gate: TCPProbeGate?
  private var cancelled = false

  func install(_ gate: TCPProbeGate) {
    lock.lock()
    if cancelled {
      lock.unlock()
      gate.finish(false)
      return
    }
    self.gate = gate
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let gate = self.gate
    lock.unlock()
    gate?.finish(false)
  }
}

private final class TCPProbeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  private let continuation: CheckedContinuation<Bool, Never>
  private let connection: NWConnection

  init(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
    self.continuation = continuation
    self.connection = connection
  }

  func finish(_ result: Bool) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    connection.cancel()
    continuation.resume(returning: result)
  }
}

private func milliseconds(since instant: ContinuousClock.Instant) -> Double {
  let duration = instant.duration(to: .now)
  let components = duration.components
  let value =
    Double(components.seconds) * 1_000
    + Double(components.attoseconds) / 1_000_000_000_000_000
  return (value * 10).rounded() / 10
}

private func safeTimeout(_ timeout: Double) -> Double {
  timeout.isFinite ? min(max(timeout, 0.2), 30) : 3
}

private func localOpsUserAgent() -> String {
  let fallback = "LocalOps/dev"
  guard
    let rawVersion = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String
  else {
    return fallback
  }
  let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !version.isEmpty,
    version.utf8.count <= 32,
    version.unicodeScalars.allSatisfy(isSafeUserAgentVersionScalar)
  else {
    return fallback
  }
  return "LocalOps/\(version)"
}

private func isSafeUserAgentVersionScalar(_ scalar: UnicodeScalar) -> Bool {
  switch scalar.value {
  case 45, 46, 95, 48...57, 65...90, 97...122:
    true
  default:
    false
  }
}

private func isCancellation(_ error: Error) -> Bool {
  error is CancellationError || (error as? URLError)?.code == .cancelled
}

private func readableNetworkError(_ error: Error) -> String {
  if error is HealthCheckError {
    return "健康响应超过大小上限"
  }
  if isCancellation(error) {
    return "检查已取消"
  }
  if let urlError = error as? URLError {
    switch urlError.code {
    case .timedOut: return "连接超时"
    case .cannotConnectToHost: return "无法连接服务"
    case .notConnectedToInternet: return "网络不可用"
    default: return urlError.localizedDescription
    }
  }
  return error.localizedDescription
}

private func declaredHealthStatus(in data: Data) -> String? {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return nil
  }
  return (object["status"] as? String)?.lowercased()
}

private func responseSummary(data: Data, response: HTTPURLResponse) -> String? {
  let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
  guard contentType.localizedCaseInsensitiveContains("json"),
    let object = try? JSONSerialization.jsonObject(with: data),
    JSONSerialization.isValidJSONObject(object)
  else { return nil }
  let redacted = redactJSON(object)
  guard let compact = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
  else { return nil }
  return boundedUTF8Summary(compact, limit: 2_048)
}

private func boundedUTF8Summary(_ data: Data, limit: Int) -> String {
  guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
  let suffix = "…"
  let budget = max(0, limit - suffix.utf8.count)
  let text = String(decoding: data, as: UTF8.self)
  var prefix = ""
  var bytes = 0
  for scalar in text.unicodeScalars {
    let scalarBytes = String(scalar).utf8.count
    guard bytes + scalarBytes <= budget else { break }
    prefix.unicodeScalars.append(scalar)
    bytes += scalarBytes
  }
  return prefix + suffix
}

private func redactJSON(_ value: Any) -> Any {
  if let dictionary = value as? [String: Any] {
    return dictionary.reduce(into: [String: Any]()) { result, pair in
      let key = pair.key.lowercased()
      if [
        "token", "secret", "password", "authorization", "cookie", "api_key", "apikey", "access_key",
      ].contains(where: key.contains) {
        result[pair.key] = "<redacted>"
      } else {
        result[pair.key] = redactJSON(pair.value)
      }
    }
  }
  if let array = value as? [Any] {
    return array.map(redactJSON)
  }
  return value
}
