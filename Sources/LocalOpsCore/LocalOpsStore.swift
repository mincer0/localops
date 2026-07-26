import Foundation
import GRDB

public struct ObservedServiceRecord: Hashable, Sendable {
  public var id: String
  public var processName: String
  public var executablePath: String?
  public var workingDirectory: String?
  public var host: String
  public var port: Int
  public var firstSeenAt: Date
  public var lastSeenAt: Date
  public var lastPid: Int?
}

public actor LocalOpsStore {
  private let database: DatabaseQueue

  public init(path: URL) throws {
    database = try DatabaseQueue(path: path.path)
  }

  public func migrate() throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("swift-v1-core") { db in
      try db.create(table: "services", options: .ifNotExists) { table in
        table.column("id", .text).primaryKey()
        table.column("name", .text).notNull()
        table.column("group_name", .text).notNull()
        table.column("description", .text).notNull()
        table.column("enabled", .boolean).notNull().defaults(to: true)
        table.column("endpoints_json", .text).notNull()
        table.column("health_json", .text).notNull()
        table.column("is_builtin", .boolean).notNull().defaults(to: false)
        table.column("created_at", .text).notNull()
        table.column("updated_at", .text).notNull()
      }
      try db.create(table: "service_state", options: .ifNotExists) { table in
        table.column("service_id", .text).primaryKey()
        table.column("service_name", .text).notNull()
        table.column("source", .text).notNull()
        table.column("lifecycle", .text).notNull()
        table.column("health", .text).notNull()
        table.column("latency_ms", .double)
        table.column("checked_at", .text).notNull()
        table.column("details_json", .text).notNull()
      }
      try db.create(table: "events", options: .ifNotExists) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("occurred_at", .text).notNull()
        table.column("service_id", .text).notNull()
        table.column("service_name", .text).notNull()
        table.column("kind", .text).notNull()
        table.column("severity", .text).notNull()
        table.column("message", .text).notNull()
      }
      try db.create(
        index: "events_occurred_at_idx",
        on: "events",
        columns: ["occurred_at"],
        options: .ifNotExists
      )
      try db.create(table: "service_catalog", options: .ifNotExists) { table in
        table.column("id", .text).primaryKey()
        table.column("process_name", .text).notNull()
        table.column("executable_path", .text)
        table.column("working_directory", .text)
        table.column("host", .text).notNull()
        table.column("port", .integer).notNull()
        table.column("first_seen_at", .text).notNull()
        table.column("last_seen_at", .text).notNull()
        table.column("last_started_at", .text)
        table.column("last_pid", .integer)
        table.column("metadata_json", .text).notNull()
        table.column("claimed_service_id", .text)
        table.column("ignored", .boolean).notNull().defaults(to: false)
      }
      try db.create(
        index: "service_catalog_last_seen_idx",
        on: "service_catalog",
        columns: ["last_seen_at"],
        options: .ifNotExists
      )
      try db.create(table: "action_audit", options: .ifNotExists) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("occurred_at", .text).notNull()
        table.column("request_id", .text).notNull().unique()
        table.column("service_id", .text).notNull()
        table.column("service_name", .text).notNull()
        table.column("manager", .text).notNull()
        table.column("action", .text).notNull()
        table.column("succeeded", .boolean).notNull()
        table.column("message", .text).notNull()
      }
    }
    try migrator.migrate(database)
  }

  public func seedDefaults(_ definitions: [ServiceDefinition]) throws {
    for definition in definitions {
      try saveDefinition(definition, builtIn: true, replace: false)
    }
  }

  public func saveDefinition(
    _ definition: ServiceDefinition,
    builtIn: Bool = false,
    replace: Bool = true
  ) throws {
    let value = try definition.validated()
    let endpoints = try encode(value.endpoints)
    let health = try encode(value.health)
    let now = isoString(Date())
    try database.write { db in
      if replace {
        try db.execute(
          sql: """
            INSERT INTO services (
                id, name, group_name, description, enabled,
                endpoints_json, health_json, is_builtin, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name,
                group_name=excluded.group_name,
                description=excluded.description,
                enabled=excluded.enabled,
                endpoints_json=excluded.endpoints_json,
                health_json=excluded.health_json,
                updated_at=excluded.updated_at
            """,
          arguments: [
            value.id, value.name, value.group, value.description, value.enabled,
            endpoints, health, builtIn, now, now,
          ]
        )
      } else {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO services (
                id, name, group_name, description, enabled,
                endpoints_json, health_json, is_builtin, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            value.id, value.name, value.group, value.description, value.enabled,
            endpoints, health, builtIn, now, now,
          ]
        )
      }
    }
  }

  public func loadDefinitions() throws -> [ServiceDefinition] {
    let definitions = try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, name, group_name, description, enabled, endpoints_json, health_json
          FROM services WHERE enabled = 1 ORDER BY group_name, name
          """
      ).map { row -> ServiceDefinition in
        ServiceDefinition(
          id: row["id"],
          name: row["name"],
          group: row["group_name"],
          description: row["description"],
          enabled: row["enabled"],
          endpoints: try decode([ServiceEndpoint].self, from: row["endpoints_json"]),
          health: try decode(ServiceHealthCheck.self, from: row["health_json"])
        )
      }
    }
    var seenIds = Set<String>()
    var occupiedPorts: [Int: String] = [:]
    for definition in definitions {
      _ = try definition.validated()
      guard seenIds.insert(definition.id).inserted else {
        throw LocalOpsError.invalidService("服务 id 重复：\(definition.id)")
      }
      for port in definition.ports {
        if let owner = occupiedPorts[port] {
          throw LocalOpsError.invalidService("端口 \(port) 同时由 \(owner) 和 \(definition.id) 登记")
        }
        occupiedPorts[port] = definition.id
      }
    }
    return definitions
  }

  public func deleteDefinition(id: String) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM services WHERE id = ? AND is_builtin = 0", arguments: [id])
    }
  }

  public func record(_ snapshot: ServiceSnapshot) throws {
    guard let checkedAt = snapshot.checkedAt else { return }
    let details = try encode(snapshot)
    let checked = isoString(checkedAt)
    try database.write { db in
      let previous = try Row.fetchOne(
        db,
        sql: "SELECT lifecycle, health FROM service_state WHERE service_id = ?",
        arguments: [snapshot.id]
      )
      try db.execute(
        sql: """
          INSERT INTO service_state (
              service_id, service_name, source, lifecycle, health,
              latency_ms, checked_at, details_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(service_id) DO UPDATE SET
              service_name=excluded.service_name,
              source=excluded.source,
              lifecycle=excluded.lifecycle,
              health=excluded.health,
              latency_ms=excluded.latency_ms,
              checked_at=excluded.checked_at,
              details_json=excluded.details_json
          """,
        arguments: [
          snapshot.id, snapshot.name, snapshot.source.rawValue,
          snapshot.lifecycle.rawValue, snapshot.health.rawValue,
          snapshot.latencyMs, checked, details,
        ]
      )
      let previousLifecycle: String? = previous?["lifecycle"]
      let previousHealth: String? = previous?["health"]
      if previousLifecycle != snapshot.lifecycle.rawValue
        || previousHealth != snapshot.health.rawValue
      {
        let event = transitionEvent(for: snapshot, hadPreviousState: previous != nil)
        try db.execute(
          sql: """
            INSERT INTO events (
                occurred_at, service_id, service_name, kind, severity, message
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            checked, snapshot.id, snapshot.name, event.kind, event.severity, event.message,
          ]
        )
      }
    }
  }

  public func recordObserved(_ listener: ListeningService, seenAt: Date = Date()) throws {
    let timestamp = isoString(seenAt)
    let metadata = try encode(listener)
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO service_catalog (
              id, process_name, executable_path, working_directory,
              host, port, first_seen_at, last_seen_at, last_pid, metadata_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
              process_name=excluded.process_name,
              executable_path=COALESCE(excluded.executable_path, executable_path),
              working_directory=COALESCE(excluded.working_directory, working_directory),
              host=excluded.host,
              port=excluded.port,
              last_seen_at=excluded.last_seen_at,
              last_pid=excluded.last_pid,
              metadata_json=excluded.metadata_json
          """,
        arguments: [
          listener.stableId, listener.processName, listener.executablePath,
          listener.workingDirectory, listener.normalizedHost, listener.port,
          timestamp, timestamp, listener.pid, metadata,
        ]
      )
    }
  }

  public func listObserved() throws -> [ObservedServiceRecord] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, process_name, executable_path, working_directory,
                 host, port, first_seen_at, last_seen_at, last_pid
          FROM service_catalog
          WHERE ignored = 0 AND claimed_service_id IS NULL
          ORDER BY last_seen_at DESC
          """
      ).compactMap { row in
        guard let first = parseISO(row["first_seen_at"]),
          let last = parseISO(row["last_seen_at"])
        else { return nil }
        return ObservedServiceRecord(
          id: row["id"],
          processName: row["process_name"],
          executablePath: row["executable_path"],
          workingDirectory: row["working_directory"],
          host: row["host"],
          port: row["port"],
          firstSeenAt: first,
          lastSeenAt: last,
          lastPid: row["last_pid"]
        )
      }
    }
  }

  public func forgetObserved(id: String) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM service_catalog WHERE id = ? AND claimed_service_id IS NULL",
        arguments: [id]
      )
    }
  }

  public func listEvents(limit: Int = 50) throws -> [LocalOpsEvent] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, occurred_at, service_id, service_name, kind, severity, message
          FROM events ORDER BY id DESC LIMIT ?
          """,
        arguments: [min(max(limit, 1), 200)]
      ).compactMap { row in
        guard let occurredAt = parseISO(row["occurred_at"]) else { return nil }
        return LocalOpsEvent(
          id: row["id"],
          occurredAt: occurredAt,
          serviceId: row["service_id"],
          serviceName: row["service_name"],
          kind: row["kind"],
          severity: row["severity"],
          message: row["message"]
        )
      }
    }
  }

  public func isReady() -> Bool {
    (try? database.read { db in try Int.fetchOne(db, sql: "SELECT 1") }) != nil
  }
}

private func transitionEvent(
  for snapshot: ServiceSnapshot,
  hadPreviousState: Bool
) -> (kind: String, severity: String, message: String) {
  if !hadPreviousState {
    return (
      "discovered", "info", "首次记录：\(snapshot.lifecycle.rawValue) / \(snapshot.health.rawValue)"
    )
  }
  if snapshot.health == .healthy {
    return ("recovered", "success", "服务恢复健康")
  }
  if snapshot.lifecycle == .stopped {
    return ("stopped", "error", snapshot.message ?? "服务停止响应")
  }
  if snapshot.health == .unhealthy || snapshot.health == .degraded {
    return ("health_changed", "warning", snapshot.message ?? "健康状态发生变化")
  }
  return (
    "state_changed", "info", "状态变为 \(snapshot.lifecycle.rawValue) / \(snapshot.health.rawValue)"
  )
}

private func encode<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(type, from: Data(value.utf8))
}

private func isoString(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

private func parseISO(_ string: String) -> Date? {
  ISO8601DateFormatter().date(from: string)
}
