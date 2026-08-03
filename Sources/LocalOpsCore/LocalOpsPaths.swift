import Foundation
import GRDB

public struct LocalOpsPaths: Sendable {
  public var applicationSupport: URL
  public var database: URL
  public var legacyDatabase: URL?
  public var legacyServices: [URL]

  public init(
    applicationSupport: URL,
    database: URL,
    legacyDatabase: URL? = nil,
    legacyServices: [URL] = []
  ) {
    self.applicationSupport = applicationSupport
    self.database = database
    self.legacyDatabase = legacyDatabase
    self.legacyServices = legacyServices
  }

  public static func live(fileManager: FileManager = .default) throws -> LocalOpsPaths {
    let base: URL
    if let override = ProcessInfo.processInfo.environment["LOCALOPS_APPLICATION_SUPPORT"],
      !override.isEmpty
    {
      base = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      base = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ).appendingPathComponent("LocalOps", isDirectory: true)
    }
    let data = base.appendingPathComponent(".data", isDirectory: true)
    let config = base.appendingPathComponent("config", isDirectory: true)
    return LocalOpsPaths(
      applicationSupport: base,
      database: data.appendingPathComponent("localops.sqlite3"),
      legacyDatabase: data.appendingPathComponent("cockpit.sqlite3"),
      legacyServices: [
        config.appendingPathComponent("services.yaml"),
        config.appendingPathComponent("claimed-services.yaml"),
      ]
    )
  }

  public func prepare(fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: database.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: database.deletingLastPathComponent().path
    )
    guard !fileManager.fileExists(atPath: database.path),
      let legacyDatabase,
      fileManager.fileExists(atPath: legacyDatabase.path)
    else { return }

    // The legacy database may be in WAL mode. Copying only its main file can
    // therefore lose committed pages. Open it through SQLite and create a
    // consistent snapshot in the same directory so the final rename remains
    // atomic and cannot cross filesystems.
    let temporary = database.deletingLastPathComponent()
      .appendingPathComponent(
        ".localops.sqlite3.migrating-\(UUID().uuidString).tmp",
        isDirectory: false
      )
    guard !fileManager.fileExists(atPath: temporary.path) else {
      throw LocalOpsError.commandFailed("无法创建唯一的 SQLite 迁移临时文件")
    }

    var moved = false
    defer {
      if !moved {
        try? fileManager.removeItem(at: temporary)
      }
    }

    let source = try DatabaseQueue(path: legacyDatabase.path)
    try source.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM INTO ?", arguments: [temporary.path])
    }

    let snapshot = try DatabaseQueue(path: temporary.path)
    try snapshot.read { db in
      let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
      guard result?.lowercased() == "ok" else {
        throw LocalOpsError.commandFailed("旧版 SQLite 快照完整性检查失败")
      }
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

    // Recheck immediately before the move. If another initializer won the
    // race, leave its destination untouched and clean up only our snapshot.
    guard !fileManager.fileExists(atPath: database.path) else {
      throw LocalOpsError.commandFailed("LocalOps 数据库已由其他进程创建")
    }
    try fileManager.moveItem(at: temporary, to: database)
    moved = true
  }
}
