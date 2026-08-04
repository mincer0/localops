import Darwin
import Foundation
import LocalOpsCore

final class LocalOpsInstanceLock {
  enum Acquisition {
    case acquired(LocalOpsInstanceLock)
    case alreadyRunning
    case failed(String)
  }

  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }

  static func acquire(fileManager: FileManager = .default) -> LocalOpsInstanceLock? {
    guard case .acquired(let lock) = acquireResult(fileManager: fileManager) else {
      return nil
    }
    return lock
  }

  static func acquireResult(fileManager: FileManager = .default) -> Acquisition {
    guard let paths = try? LocalOpsPaths.live() else {
      return .failed("无法定位 LocalOps 应用数据目录。")
    }
    do {
      try fileManager.createDirectory(
        at: paths.applicationSupport,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: paths.applicationSupport.path
      )
    } catch {
      return .failed("无法准备 LocalOps 单实例锁目录：\(redact(error.localizedDescription))")
    }

    let lockURL = paths.applicationSupport.appendingPathComponent("localops.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
    guard descriptor >= 0 else {
      return .failed("无法创建 LocalOps 单实例锁文件：\(redact(String(cString: strerror(errno))))")
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
      _ = close(descriptor)
      return .failed("无法设置 LocalOps 单实例锁权限。")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      _ = close(descriptor)
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        return .alreadyRunning
      }
      return .failed("无法取得 LocalOps 单实例锁：\(String(cString: strerror(lockError)))")
    }
    return .acquired(LocalOpsInstanceLock(descriptor: descriptor))
  }

  private static func redact(_ value: String) -> String {
    var result = value
    result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    result = result.replacingOccurrences(
      of: #"/Users/[^/\s]+"#,
      with: "~",
      options: .regularExpression
    )
    return String(result.prefix(300))
  }
}
