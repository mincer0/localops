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

  public init(
    lifecycle: ServiceLifecycle,
    health: ServiceHealth,
    latencyMs: Double? = nil,
    checkedAt: Date = Date(),
    message: String? = nil,
    responseSummary: String? = nil
  ) {
    self.lifecycle = lifecycle
    self.health = health
    self.latencyMs = latencyMs
    self.checkedAt = checkedAt
    self.message = message
    self.responseSummary = responseSummary
  }
}

public protocol HealthChecking: Sendable {
  func probe(_ check: ServiceHealthCheck) async -> ProbeResult
}

public struct SystemHealthChecker: HealthChecking {
  private let session: URLSession

  public init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.httpMaximumConnectionsPerHost = 2
      self.session = URLSession(configuration: configuration)
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
        message: "未配置健康检查"
      )
    }
  }

  private func probeHTTP(_ check: ServiceHealthCheck) async -> ProbeResult {
    guard let rawURL = check.url, let url = URL(string: rawURL) else {
      return ProbeResult(lifecycle: .unknown, health: .unknown, message: "HTTP 地址无效")
    }
    let started = ContinuousClock.now
    var request = URLRequest(url: url)
    request.timeoutInterval = check.timeoutSeconds
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("LocalOps/0.4.0", forHTTPHeaderField: "User-Agent")
    do {
      let (data, response) = try await session.data(for: request)
      let latency = milliseconds(since: started)
      guard let http = response as? HTTPURLResponse else {
        return ProbeResult(
          lifecycle: .running,
          health: .unhealthy,
          latencyMs: latency,
          message: "无法识别 HTTP 响应"
        )
      }
      let summary = responseSummary(data: data, response: http)
      let declaredStatus = declaredHealthStatus(in: data)
      if (200..<400).contains(http.statusCode) {
        return ProbeResult(
          lifecycle: .running,
          health: declaredStatus == "degraded" || declaredStatus == "warning"
            ? .degraded : .healthy,
          latencyMs: latency,
          responseSummary: summary
        )
      }
      return ProbeResult(
        lifecycle: .running,
        health: .unhealthy,
        latencyMs: latency,
        message: "HTTP \(http.statusCode)",
        responseSummary: summary
      )
    } catch {
      return ProbeResult(
        lifecycle: .stopped,
        health: .unhealthy,
        latencyMs: milliseconds(since: started),
        message: readableNetworkError(error)
      )
    }
  }

  private func probeTCP(_ check: ServiceHealthCheck) async -> ProbeResult {
    guard let rawPort = check.port, let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
      return ProbeResult(lifecycle: .unknown, health: .unknown, message: "TCP 端口无效")
    }
    let started = ContinuousClock.now
    let connected = await TCPProbe.connect(
      host: NWEndpoint.Host(check.host),
      port: port,
      timeout: check.timeoutSeconds
    )
    return ProbeResult(
      lifecycle: connected ? .running : .stopped,
      health: connected ? .healthy : .unhealthy,
      latencyMs: milliseconds(since: started),
      message: connected ? nil : "无法连接 \(check.host):\(rawPort)"
    )
  }

  private func probeProcess(_ check: ServiceHealthCheck) -> ProbeResult {
    guard let pid = check.pid, pid > 0 else {
      return ProbeResult(lifecycle: .unknown, health: .unknown, message: "PID 无效")
    }
    errno = 0
    let alive = kill(pid_t(pid), 0) == 0 || errno == EPERM
    return ProbeResult(
      lifecycle: alive ? .running : .stopped,
      health: alive ? .healthy : .unhealthy,
      message: alive ? nil : "PID \(pid) 不存在"
    )
  }
}

private enum TCPProbe {
  static func connect(host: NWEndpoint.Host, port: NWEndpoint.Port, timeout: Double) async -> Bool {
    await withCheckedContinuation { continuation in
      let connection = NWConnection(host: host, port: port, using: .tcp)
      let gate = TCPProbeGate(continuation: continuation, connection: connection)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: gate.finish(true)
        case .failed, .cancelled: gate.finish(false)
        default: break
        }
      }
      let queue = DispatchQueue(label: "io.github.mincer0.localops.tcp-probe")
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + max(0.2, timeout)) {
        gate.finish(false)
      }
    }
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

private func readableNetworkError(_ error: Error) -> String {
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
    JSONSerialization.isValidJSONObject(object),
    let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  else { return nil }
  let value = String(decoding: compact.prefix(2_048), as: UTF8.self)
  return compact.count > 2_048 ? value + "…" : value
}
