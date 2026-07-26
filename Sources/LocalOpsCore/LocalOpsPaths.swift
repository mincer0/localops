import Foundation

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
      withIntermediateDirectories: true
    )
    guard !fileManager.fileExists(atPath: database.path),
      let legacyDatabase,
      fileManager.fileExists(atPath: legacyDatabase.path)
    else { return }
    try fileManager.copyItem(at: legacyDatabase, to: database)
  }
}
