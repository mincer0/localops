import CryptoKit
import Foundation

public struct ListeningService: Codable, Hashable, Sendable {
  public var pid: Int
  public var processName: String
  public var host: String
  public var port: Int
  public var address: String
  public var memoryMb: Double?
  public var cpuPercent: Double?
  public var executablePath: String?
  public var workingDirectory: String?

  public init(
    pid: Int,
    processName: String,
    host: String,
    port: Int,
    address: String,
    memoryMb: Double? = nil,
    cpuPercent: Double? = nil,
    executablePath: String? = nil,
    workingDirectory: String? = nil
  ) {
    self.pid = pid
    self.processName = processName
    self.host = host
    self.port = port
    self.address = address
    self.memoryMb = memoryMb
    self.cpuPercent = cpuPercent
    self.executablePath = executablePath
    self.workingDirectory = workingDirectory
  }

  public var normalizedHost: String {
    canonicalObservationHost(host)
  }

  /// A PID-independent identity for the observed process. Executable path is
  /// preferred when available, while command name and working directory keep
  /// the value useful for restricted `lsof` environments. It is intentionally
  /// separate from `stableId`, which also includes host/port for history.
  public var processFingerprint: String {
    let material = [processName, executablePath ?? "", workingDirectory ?? ""].joined(
      separator: "\0")
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  public var stableId: String {
    let executable = executablePath ?? processName
    let material = "\(executable)\0\(normalizedHost)\0\(port)"
    let digest = SHA256.hash(data: Data(material.utf8))
    return "observed-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}

public protocol ServiceDiscovering: Sendable {
  func scan() async throws -> [ListeningService]
}

public enum ListenerMatch: Sendable {
  case none
  case matched(ListeningService)
  case ambiguous
}

public struct SystemServiceDiscovery: ServiceDiscovering {
  private let runner: CommandRunner

  public init(runner: CommandRunner = CommandRunner()) {
    self.runner = runner
  }

  public func scan() async throws -> [ListeningService] {
    let worker = Task.detached(priority: .utility) {
      try scanSynchronously(runner: runner)
    }
    return try await withTaskCancellationHandler(
      operation: {
        try await worker.value
      },
      onCancel: {
        worker.cancel()
      })
  }
}

public func discoveryCandidates(
  from listeners: [ListeningService],
  knownPorts: Set<Int>,
  currentPid: Int32 = ProcessInfo.processInfo.processIdentifier,
  webPort: Int = 8042
) -> [ListeningService] {
  let systemProcesses: Set<String> = [
    "ControlCenter",
    "rapportd",
    "sharingd",
    "identityservicesd",
    "trustd",
    "mDNSResponder",
  ]
  return listeners.filter { listener in
    listener.pid != Int(currentPid)
      && listener.port != webPort
      && !knownPorts.contains(listener.port)
      && !systemProcesses.contains(listener.processName)
  }
}

public func matchListener(
  ports: Set<Int>,
  listeners: [ListeningService],
  hosts: Set<String>? = nil,
  processName: String? = nil,
  executablePath: String? = nil
) -> ListeningService? {
  switch matchListenerDetailed(
    ports: ports,
    listeners: listeners,
    hosts: hosts,
    processName: processName,
    executablePath: executablePath
  ) {
  case .matched(let listener): listener
  case .none, .ambiguous: nil
  }
}

/// Match a configured service to process evidence without ever assigning an
/// arbitrary process merely because it happens to use the same port. Host and
/// port are mandatory for Engine attribution; a caller may further narrow by
/// process name/path. If more than one PID remains, the result is ambiguous
/// and no PID is assigned. This avoids treating a reused PID as identity.
public func matchListenerDetailed(
  ports: Set<Int>,
  listeners: [ListeningService],
  hosts: Set<String>? = nil,
  processName: String? = nil,
  executablePath: String? = nil
) -> ListenerMatch {
  guard !ports.isEmpty else { return .none }
  let canonicalHosts = hosts?.map(canonicalObservationHost)
  var candidates = listeners.filter { listener in
    guard ports.contains(listener.port) else { return false }
    // The legacy public helper allowed port-only matching. Keep that behavior
    // for callers that omit hosts; Engine always supplies configured hosts.
    guard let canonicalHosts, !canonicalHosts.isEmpty else { return true }
    return canonicalHosts.contains(listener.normalizedHost)
  }
  if let processName, !processName.isEmpty {
    candidates = candidates.filter { $0.processName == processName }
  }
  if let executablePath, !executablePath.isEmpty {
    candidates = candidates.filter { $0.executablePath == executablePath }
  }
  switch candidates.count {
  case 0: return .none
  case 1: return .matched(candidates[0])
  default: return .ambiguous
  }
}

public func parseListeningAddress(_ address: String) -> (host: String, port: Int)? {
  let host: String
  let rawPort: String
  if address.hasPrefix("["), let separator = address.range(of: "]:", options: .backwards) {
    host = String(address[address.index(after: address.startIndex)..<separator.lowerBound])
    rawPort = String(address[separator.upperBound...])
  } else if let separator = address.lastIndex(of: ":") {
    host = String(address[..<separator])
    rawPort = String(address[address.index(after: separator)...])
  } else {
    return nil
  }
  guard let port = Int(rawPort), (1...65_535).contains(port) else { return nil }
  return (host, port)
}

private func scanSynchronously(runner: CommandRunner) throws -> [ListeningService] {
  let result = try runner.run(
    executable: "/usr/sbin/lsof",
    arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"],
    timeoutSeconds: 8,
    maxOutputBytes: 4 * 1_024 * 1_024
  )
  guard result.status == 0 || result.status == 1 else {
    throw LocalOpsError.commandFailed(
      "lsof 扫描失败：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
  }

  var records: [(Int, String, String)] = []
  var currentPid: Int?
  var currentCommand = "unknown"
  for line in result.stdout.split(whereSeparator: \.isNewline) {
    guard let field = line.first else { continue }
    let value = String(line.dropFirst())
    switch field {
    case "p": currentPid = Int(value)
    case "c": currentCommand = value.isEmpty ? "unknown" : value
    case "n":
      if let currentPid { records.append((currentPid, currentCommand, value)) }
    default: break
    }
  }

  var seen = Set<String>()
  let uniquePids = Set(records.map(\.0))
  let processInfo = Dictionary(
    uniqueKeysWithValues: uniquePids.map { pid in
      (pid, readProcessInfo(pid: pid, runner: runner))
    })

  return records.compactMap { pid, command, address in
    guard let parsed = parseListeningAddress(address) else { return nil }
    let key = "\(pid):\(parsed.port)"
    guard seen.insert(key).inserted else { return nil }
    let info = processInfo[pid] ?? ProcessDetails()
    return ListeningService(
      pid: pid,
      processName: command,
      host: parsed.host,
      port: parsed.port,
      address: address,
      memoryMb: info.memoryMb,
      cpuPercent: info.cpuPercent,
      executablePath: info.executablePath,
      workingDirectory: info.workingDirectory
    )
  }.sorted { lhs, rhs in
    lhs.port == rhs.port ? lhs.pid < rhs.pid : lhs.port < rhs.port
  }
}

private struct ProcessDetails {
  var memoryMb: Double?
  var cpuPercent: Double?
  var executablePath: String?
  var workingDirectory: String?
}

private func readProcessInfo(pid: Int, runner: CommandRunner) -> ProcessDetails {
  var details = ProcessDetails()
  if let metrics = try? runner.run(
    executable: "/bin/ps",
    arguments: ["-p", String(pid), "-o", "rss=", "-o", "%cpu="],
    timeoutSeconds: 3,
    maxOutputBytes: 64 * 1_024
  ), metrics.status == 0 {
    let values = metrics.stdout.split(whereSeparator: \.isWhitespace)
    if values.count >= 2 {
      details.memoryMb = Double(values[0]).map { ($0 / 1024 * 10).rounded() / 10 }
      details.cpuPercent = Double(values[1]).map { ($0 * 10).rounded() / 10 }
    }
  }

  if let files = try? runner.run(
    executable: "/usr/sbin/lsof",
    arguments: ["-a", "-p", String(pid), "-d", "cwd,txt", "-Fn"],
    timeoutSeconds: 3,
    maxOutputBytes: 256 * 1_024
  ), files.status == 0 {
    var descriptor: String?
    for line in files.stdout.split(whereSeparator: \.isNewline) {
      guard let field = line.first else { continue }
      let value = String(line.dropFirst())
      if field == "f" {
        descriptor = value
      } else if field == "n", descriptor == "cwd" {
        details.workingDirectory = value
      } else if field == "n", descriptor == "txt", details.executablePath == nil {
        details.executablePath = value
      }
    }
  }
  return details
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
