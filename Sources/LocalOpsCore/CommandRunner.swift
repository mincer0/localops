import Darwin
import Foundation

public struct CommandResult: Sendable {
  public var status: Int32
  public var stdout: String
  public var stderr: String
}

public struct CommandRunner: Sendable {
  public init() {}

  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    timeoutSeconds: Double = 10,
    maxOutputBytes: Int = 1_024 * 1_024
  ) throws -> CommandResult {
    guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalOpsError.commandFailed("命令路径为空")
    }
    guard maxOutputBytes > 0 else {
      throw LocalOpsError.commandFailed("命令输出上限无效")
    }
    let timeout = timeoutSeconds.isFinite ? max(0.1, timeoutSeconds) : 10
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    if let environment { process.environment = environment }

    do {
      try process.run()
    } catch {
      throw LocalOpsError.commandFailed("\(executable) 无法执行：\(error.localizedDescription)")
    }

    let group = DispatchGroup()
    let collector = CommandOutputCollector()

    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let data = readLimited(
        from: output.fileHandleForReading,
        maxBytes: maxOutputBytes,
        process: process,
        collector: collector
      )
      collector.set(stdout: data)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let data = readLimited(
        from: errors.fileHandleForReading,
        maxBytes: maxOutputBytes,
        process: process,
        collector: collector
      )
      collector.set(stderr: data)
      group.leave()
    }

    let deadline = Date().addingTimeInterval(timeout)
    var collectorsFinished = false
    while !collectorsFinished {
      if Task.isCancelled {
        terminate(process)
        _ = group.wait(timeout: .now() + 1)
        process.waitUntilExit()
        throw CancellationError()
      }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      collectorsFinished =
        group.wait(
          timeout: .now() + min(0.05, remaining)
        ) == .success
    }
    if !collectorsFinished {
      terminate(process)
      _ = group.wait(timeout: .now() + 1)
      process.waitUntilExit()
      throw LocalOpsError.commandFailed("\(executable) 执行超时")
    }
    var processTimedOut = false
    while process.isRunning && Date() < deadline {
      if Task.isCancelled {
        terminate(process)
        _ = group.wait(timeout: .now() + 1)
        process.waitUntilExit()
        throw CancellationError()
      }
      usleep(10_000)
    }
    if process.isRunning {
      processTimedOut = true
      terminate(process)
    }
    process.waitUntilExit()
    if processTimedOut {
      throw LocalOpsError.commandFailed("\(executable) 执行超时")
    }
    let collected = collector.value()
    if collected.exceeded {
      throw LocalOpsError.commandFailed("\(executable) 输出超过 \(maxOutputBytes) 字节上限")
    }
    return CommandResult(
      status: process.terminationStatus,
      stdout: String(decoding: collected.stdout, as: UTF8.self),
      stderr: String(decoding: collected.stderr, as: UTF8.self)
    )
  }
}

private func terminate(_ process: Process) {
  guard process.isRunning else { return }
  process.terminate()
  if process.isRunning {
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
  }
}

private func readLimited(
  from handle: FileHandle,
  maxBytes: Int,
  process: Process,
  collector: CommandOutputCollector
) -> Data {
  var result = Data()
  while true {
    let chunk = handle.readData(ofLength: min(64 * 1_024, maxBytes + 1))
    if chunk.isEmpty { break }
    result.append(chunk)
    if result.count > maxBytes {
      collector.markExceeded()
      if process.isRunning { process.terminate() }
      break
    }
  }
  return result
}

private final class CommandOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var stdout = Data()
  private var stderr = Data()
  private var didExceed = false

  func set(stdout: Data) {
    lock.lock()
    self.stdout = stdout
    lock.unlock()
  }

  func set(stderr: Data) {
    lock.lock()
    self.stderr = stderr
    lock.unlock()
  }

  func markExceeded() {
    lock.lock()
    didExceed = true
    lock.unlock()
  }

  func value() -> (stdout: Data, stderr: Data, exceeded: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (stdout, stderr, didExceed)
  }
}
