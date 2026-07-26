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
    environment: [String: String]? = nil
  ) throws -> CommandResult {
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

    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(
      status: process.terminationStatus,
      stdout: String(decoding: outputData, as: UTF8.self),
      stderr: String(decoding: errorData, as: UTF8.self)
    )
  }
}
