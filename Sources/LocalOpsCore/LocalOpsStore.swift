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
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }

  /// Create one consistent SQLite backup before the first migration of a
  /// database. `VACUUM INTO` includes WAL contents, unlike copying the main
  /// file directly. Existing backups are never overwritten.
  public func backupIfNeeded(to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try database.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
    migrator.registerMigration("swift-v2-trust") { db in
      try db.create(table: "localops_migrations", options: .ifNotExists) { table in
        table.column("name", .text).primaryKey()
        table.column("completed_at", .text).notNull()
      }
      try db.create(table: "localops_refresh_state", options: .ifNotExists) { table in
        table.column("id", .integer).primaryKey()
        table.column("generation", .integer).notNull().defaults(to: 0)
        table.column("attempted_at", .text)
        table.column("successful_at", .text)
      }
      try db.create(table: "service_failure_state", options: .ifNotExists) { table in
        table.column("service_id", .text).primaryKey()
        table.column("consecutive_failures", .integer).notNull().defaults(to: 0)
      }
      try db.create(
        index: "service_state_checked_at_idx",
        on: "service_state",
        columns: ["checked_at"],
        options: .ifNotExists
      )
      try db.create(
        index: "events_service_id_idx",
        on: "events",
        columns: ["service_id"],
        options: .ifNotExists
      )
      // Existing databases predate foreign-key declarations.  Triggers give
      // them the same delete semantics without rebuilding user data in place.
      try db.execute(
        sql: """
          CREATE TRIGGER IF NOT EXISTS services_delete_state
          AFTER DELETE ON services
          BEGIN
            DELETE FROM service_state WHERE service_id = OLD.id;
            DELETE FROM events WHERE service_id = OLD.id;
            UPDATE service_catalog SET claimed_service_id = NULL
              WHERE claimed_service_id = OLD.id;
            DELETE FROM service_failure_state WHERE service_id = OLD.id;
          END
          """)
    }
    migrator.registerMigration("swift-v3-service-editing") { db in
      // A development build may have added one of these columns before the
      // migration was registered. Inspect the schema first so retries remain
      // idempotent on both old and partially upgraded databases.
      let columns = Set(
        try Row.fetchAll(db, sql: "PRAGMA table_info(services)").map {
          (row: Row) -> String in row["name"]
        })
      if !columns.contains("management_kind") {
        try db.execute(
          sql: "ALTER TABLE services ADD COLUMN management_kind TEXT NOT NULL DEFAULT 'unknown'"
        )
      }
      if !columns.contains("recovery_note") {
        try db.execute(
          sql: "ALTER TABLE services ADD COLUMN recovery_note TEXT NOT NULL DEFAULT ''"
        )
      }
      if !columns.contains("notifications_muted") {
        try db.execute(
          sql: "ALTER TABLE services ADD COLUMN notifications_muted INTEGER NOT NULL DEFAULT 0"
        )
      }
    }
    try migrator.migrate(database)
    try database.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
      guard result?.lowercased() == "ok" else {
        throw LocalOpsError.commandFailed("SQLite 完整性检查失败")
      }
      try db.execute(
        sql: "INSERT OR IGNORE INTO localops_refresh_state (id, generation) VALUES (1, 0)"
      )
    }
  }

  public func hasMigrationMarker(_ name: String) throws -> Bool {
    try database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT 1 FROM localops_migrations WHERE name = ? LIMIT 1",
        arguments: [name]
      ) != nil
    }
  }

  public func markMigration(_ name: String, completedAt: Date = Date()) throws {
    try database.write { db in
      try db.execute(
        sql: "INSERT OR REPLACE INTO localops_migrations (name, completed_at) VALUES (?, ?)",
        arguments: [name, isoString(completedAt)]
      )
    }
  }

  public func seedDefaults(_ definitions: [ServiceDefinition]) throws {
    for definition in definitions {
      try saveDefinition(definition, builtIn: true, replace: false)
    }
  }

  /// Remove the mutable LocalOps catalog and seed the supplied built-in
  /// definitions in the same SQLite transaction. Migration markers and the
  /// schema are deliberately left untouched so legacy YAML is not replayed
  /// after a user reset. The caller must checkpoint/VACUUM and remove the
  /// preflight backup only after this transaction succeeds.
  public func clearCurrentDirectoryData(
    seeding definitions: [ServiceDefinition],
    completedAt: Date = Date()
  ) throws {
    let values = try definitions.map { try $0.validated() }
    let ids = values.map(\.id)
    guard Set(ids).count == ids.count else {
      throw LocalOpsError.invalidService("默认服务 id 重复")
    }
    let encoded = try values.map {
      (value: $0, endpoints: try encode($0.endpoints), health: try encode($0.health))
    }
    let now = isoString(completedAt)

    try database.write { db in
      // secure_delete is connection-scoped. Enable it before any DELETE in
      // this transaction so SQLite overwrites deleted pages instead of
      // leaving the old LocalOps catalog recoverable from free-list pages.
      try db.execute(sql: "PRAGMA secure_delete = ON")
      try db.execute(sql: "DELETE FROM action_audit")
      try db.execute(sql: "DELETE FROM events")
      try db.execute(sql: "DELETE FROM service_catalog")
      try db.execute(sql: "DELETE FROM service_failure_state")
      try db.execute(sql: "DELETE FROM service_state")
      try db.execute(sql: "DELETE FROM services")
      try db.execute(
        sql: "INSERT OR IGNORE INTO localops_refresh_state (id, generation) VALUES (1, 0)"
      )
      try db.execute(
        sql: """
          UPDATE localops_refresh_state
          SET generation = 0, attempted_at = NULL, successful_at = NULL
          WHERE id = 1
          """)

      // The catalog is empty at this point, but keep the normal enabled-port
      // invariant here so a malformed built-in bundle still rolls back the
      // complete clear rather than leaving a partially reseeded database.
      try validatePortConflicts(values, existingOwners: [:])
      for item in encoded {
        try insertDefinition(
          item.value,
          endpoints: item.endpoints,
          health: item.health,
          builtIn: true,
          replace: false,
          now: now,
          in: db
        )
      }
    }
  }

  /// Flush pending WAL pages and rebuild the database after a successful
  /// clear transaction. This intentionally runs outside a transaction:
  /// SQLite's VACUUM cannot run while a write transaction is active.
  public func checkpointAndVacuum() throws {
    try database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
      try db.execute(sql: "VACUUM")
    }
  }

  public func commitRefresh(
    snapshots: [ServiceSnapshot],
    observed: [ListeningService],
    attemptedAt: Date,
    successfulAt: Date
  ) throws -> (generation: Int64, snapshots: [ServiceSnapshot]) {
    try database.write { db in
      var effectiveSnapshots: [ServiceSnapshot] = []
      for snapshot in snapshots {
        effectiveSnapshots.append(try record(snapshot, in: db))
      }
      for listener in observed {
        try recordObserved(listener, seenAt: successfulAt, in: db)
      }
      let previous =
        try Int64.fetchOne(
          db,
          sql: "SELECT generation FROM localops_refresh_state WHERE id = 1"
        ) ?? 0
      let generation = previous + 1
      try db.execute(
        sql: """
          UPDATE localops_refresh_state
          SET generation = ?, attempted_at = ?, successful_at = ?
          WHERE id = 1
          """,
        arguments: [generation, isoString(attemptedAt), isoString(successfulAt)]
      )
      try pruneEvents(in: db, now: successfulAt)
      return (generation, effectiveSnapshots)
    }
  }

  public func refreshState() throws -> (generation: Int64, successfulAt: Date?) {
    try database.read { db in
      let generation =
        (try? Int64.fetchOne(
          db,
          sql: "SELECT generation FROM localops_refresh_state WHERE id = 1"
        )) ?? 0
      let successfulAt = try String.fetchOne(
        db,
        sql: "SELECT successful_at FROM localops_refresh_state WHERE id = 1"
      )
      return (max(0, generation), successfulAt.flatMap(parseISO))
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
      let existingIDs = try existingServiceIDs(in: db)
      let ignoredInsert = !replace && existingIDs.contains(value.id)
      let existingOwners = try existingEnabledPortOwners(
        in: db,
        excluding: replace ? [value.id] : []
      )
      try validatePortConflicts(
        ignoredInsert ? [] : [value],
        existingOwners: existingOwners
      )
      if !ignoredInsert {
        try insertDefinition(
          value,
          endpoints: endpoints,
          health: health,
          builtIn: builtIn,
          replace: replace,
          now: now,
          in: db
        )
      }
    }
  }

  /// Import legacy registrations atomically and mark the migration in the
  /// same transaction. A retry rechecks the marker while holding the write
  /// transaction, so a concurrent/partial import cannot leave half a catalog.
  public func importLegacyDefinitions(
    _ definitions: [ServiceDefinition],
    marker: String = "legacy-services-v1",
    completedAt: Date = Date()
  ) throws {
    let now = isoString(completedAt)
    try database.write { db in
      let alreadyMigrated =
        try Int.fetchOne(
          db,
          sql: "SELECT 1 FROM localops_migrations WHERE name = ? LIMIT 1",
          arguments: [marker]
        ) != nil
      guard !alreadyMigrated else { return }

      let values = try definitions.map { try $0.validated() }
      let ids = values.map(\.id)
      guard Set(ids).count == ids.count else {
        throw LocalOpsError.invalidService("旧版服务 id 重复")
      }
      let existingIDs = try existingServiceIDs(in: db)
      let existingOwners = try existingEnabledPortOwners(in: db, excluding: [])
      let toInsert = values.filter { !existingIDs.contains($0.id) }
      try validatePortConflicts(toInsert, existingOwners: existingOwners)

      for value in toInsert {
        try insertDefinition(
          value,
          endpoints: try encode(value.endpoints),
          health: try encode(value.health),
          builtIn: false,
          replace: false,
          now: now,
          in: db
        )
      }
      try db.execute(
        sql: "INSERT OR REPLACE INTO localops_migrations (name, completed_at) VALUES (?, ?)",
        arguments: [marker, now]
      )
    }
  }

  /// Return every registered definition, including disabled entries. Values
  /// are validated individually and sorted by stable, binary string keys.
  /// Port conflicts are enforced only among enabled definitions so operators
  /// can inspect and later re-enable a disabled registration.
  public func definitions() throws -> [ServiceDefinition] {
    let definitions = try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, name, group_name, description, enabled, endpoints_json, health_json,
                 management_kind, recovery_note, notifications_muted
          FROM services ORDER BY group_name, name, id
          """
      ).map { try serviceDefinition($0) }
    }
    var seenIds = Set<String>()
    var occupiedPorts: [Int: String] = [:]
    for definition in definitions {
      _ = try definition.validated()
      guard seenIds.insert(definition.id).inserted else {
        throw LocalOpsError.invalidService("服务 id 重复：\(definition.id)")
      }
      if definition.enabled {
        for port in definition.ports {
          if let owner = occupiedPorts[port] {
            throw LocalOpsError.invalidService("端口 \(port) 同时由 \(owner) 和 \(definition.id) 登记")
          }
          occupiedPorts[port] = definition.id
        }
      }
    }
    return definitions
  }

  /// Runtime refresh only probes enabled definitions. Use `definitions()`
  /// when the caller needs the complete editable catalog.
  public func loadDefinitions() throws -> [ServiceDefinition] {
    try definitions().filter(\.enabled)
  }

  /// Read a registered definition regardless of its enabled state. The
  /// editing API uses this to distinguish an absent service from a disabled
  /// one while keeping refresh limited to enabled definitions.
  public func loadDefinition(id: String) throws -> ServiceDefinition? {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT id, name, group_name, description, enabled, endpoints_json, health_json,
                   management_kind, recovery_note, notifications_muted
            FROM services WHERE id = ? LIMIT 1
            """,
          arguments: [id]
        )
      else { return nil }
      let definition = try serviceDefinition(row)
      return try definition.validated()
    }
  }

  /// Persist an edit to an existing registration. The SQL update deliberately
  /// does not touch `is_builtin`, so callers cannot change built-in ownership
  /// through this API.
  public func updateDefinition(_ definition: ServiceDefinition) throws {
    let value = try definition.validated()
    let endpoints = try encode(value.endpoints)
    let health = try encode(value.health)
    let now = isoString(Date())
    try database.write { db in
      let exists =
        try Int.fetchOne(
          db,
          sql: "SELECT 1 FROM services WHERE id = ? LIMIT 1",
          arguments: [value.id]
        ) != nil
      guard exists else {
        throw LocalOpsError.invalidService("找不到登记服务：\(value.id)")
      }
      let existingOwners = try existingEnabledPortOwners(in: db, excluding: [value.id])
      try validatePortConflicts([value], existingOwners: existingOwners)
      try db.execute(
        sql: """
          UPDATE services SET
            name = ?, group_name = ?, description = ?, enabled = ?,
            endpoints_json = ?, health_json = ?, management_kind = ?,
            recovery_note = ?, notifications_muted = ?, updated_at = ?
          WHERE id = ?
          """,
        arguments: [
          value.name, value.group, value.description, value.enabled,
          endpoints, health, value.managementKind.rawValue, value.recoveryNote,
          value.notificationsMuted, now, value.id,
        ]
      )
    }
  }

  public func deleteDefinition(id: String) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM services WHERE id = ? AND is_builtin = 0", arguments: [id])
    }
  }

  private func insertDefinition(
    _ value: ServiceDefinition,
    endpoints: String,
    health: String,
    builtIn: Bool,
    replace: Bool,
    now: String,
    in db: Database
  ) throws {
    if replace {
      try db.execute(
        sql: """
          INSERT INTO services (
              id, name, group_name, description, enabled,
              endpoints_json, health_json, management_kind, recovery_note,
              notifications_muted, is_builtin, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              group_name=excluded.group_name,
              description=excluded.description,
              enabled=excluded.enabled,
              endpoints_json=excluded.endpoints_json,
              health_json=excluded.health_json,
              management_kind=excluded.management_kind,
              recovery_note=excluded.recovery_note,
              notifications_muted=excluded.notifications_muted,
              updated_at=excluded.updated_at
          """,
        arguments: [
          value.id, value.name, value.group, value.description, value.enabled,
          endpoints, health, value.managementKind.rawValue, value.recoveryNote,
          value.notificationsMuted, builtIn, now, now,
        ]
      )
    } else {
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO services (
              id, name, group_name, description, enabled,
              endpoints_json, health_json, management_kind, recovery_note,
              notifications_muted, is_builtin, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          value.id, value.name, value.group, value.description, value.enabled,
          endpoints, health, value.managementKind.rawValue, value.recoveryNote,
          value.notificationsMuted, builtIn, now, now,
        ]
      )
    }
  }

  private func existingServiceIDs(in db: Database) throws -> Set<String> {
    Set(try String.fetchAll(db, sql: "SELECT id FROM services"))
  }

  private func existingEnabledPortOwners(
    in db: Database,
    excluding ids: Set<String>
  ) throws -> [Int: String] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id, endpoints_json, health_json
        FROM services WHERE enabled = 1
        """
    )
    var owners: [Int: String] = [:]
    for row in rows {
      let id: String = row["id"]
      guard !ids.contains(id) else { continue }
      let endpoints = try decode([ServiceEndpoint].self, from: row["endpoints_json"])
      let health = try decode(ServiceHealthCheck.self, from: row["health_json"])
      for port in ServiceDefinition(
        id: id,
        name: id,
        endpoints: endpoints,
        health: health
      ).ports {
        owners[port] = id
      }
    }
    return owners
  }

  private func validatePortConflicts(
    _ definitions: [ServiceDefinition],
    existingOwners: [Int: String]
  ) throws {
    var owners = existingOwners
    for definition in definitions where definition.enabled {
      for port in definition.ports {
        if let owner = owners[port], owner != definition.id {
          throw LocalOpsError.invalidService(
            "端口 \(port) 同时由 \(owner) 和 \(definition.id) 登记"
          )
        }
        owners[port] = definition.id
      }
    }
  }

  public func record(_ snapshot: ServiceSnapshot) throws {
    guard let checkedAt = snapshot.checkedAt else { return }
    try database.write { db in
      _ = try record(snapshot, in: db)
      try pruneEvents(in: db, now: checkedAt)
    }
  }

  public func recordObserved(_ listener: ListeningService, seenAt: Date = Date()) throws {
    try database.write { db in
      try recordObserved(listener, seenAt: seenAt, in: db)
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

  private func record(_ snapshot: ServiceSnapshot, in db: Database) throws -> ServiceSnapshot {
    guard let checkedAt = snapshot.checkedAt else { return snapshot }
    let previous = try Row.fetchOne(
      db,
      sql: "SELECT lifecycle, health FROM service_state WHERE service_id = ?",
      arguments: [snapshot.id]
    )
    let previousFailures =
      try Int.fetchOne(
        db,
        sql: "SELECT consecutive_failures FROM service_failure_state WHERE service_id = ?",
        arguments: [snapshot.id]
      ) ?? 0
    let failed = snapshot.lifecycle == .stopped || snapshot.health == .unhealthy
    let failures = failed ? min(previousFailures + 1, 3) : 0
    var effective = snapshot
    if failed, failures < 2 {
      let previousLifecycle: String? = previous?["lifecycle"]
      effective.lifecycle =
        previousLifecycle == ServiceLifecycle.running.rawValue
        ? .running : .unknown
      effective.health = .degraded
      effective.presence = effective.lifecycle == .running ? .online : .unknown
      effective.message = "连续失败 \(failures)/2，暂不判定服务离线"
      effective.observation.freshness = .partial
    }
    let details = try encode(effective)
    let checked = isoString(checkedAt)
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
        effective.id, effective.name, effective.source.rawValue,
        effective.lifecycle.rawValue, effective.health.rawValue,
        effective.latencyMs, checked, details,
      ]
    )
    try db.execute(
      sql: """
        INSERT INTO service_failure_state (service_id, consecutive_failures)
        VALUES (?, ?)
        ON CONFLICT(service_id) DO UPDATE SET consecutive_failures = excluded.consecutive_failures
        """,
      arguments: [effective.id, failures]
    )
    let previousLifecycle: String? = previous?["lifecycle"]
    let previousHealth: String? = previous?["health"]
    if previousLifecycle != effective.lifecycle.rawValue
      || previousHealth != effective.health.rawValue
    {
      let event = transitionEvent(for: effective, hadPreviousState: previous != nil)
      try db.execute(
        sql: """
          INSERT INTO events (
              occurred_at, service_id, service_name, kind, severity, message
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          checked, effective.id, effective.name, event.kind, event.severity, event.message,
        ]
      )
    }
    return effective
  }

  private func recordObserved(
    _ listener: ListeningService,
    seenAt: Date,
    in db: Database
  ) throws {
    let timestamp = isoString(seenAt)
    let metadata = try encode(listener)
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

  private func pruneEvents(in db: Database, now: Date) throws {
    let cutoff = isoString(now.addingTimeInterval(-30 * 24 * 60 * 60))
    try db.execute(sql: "DELETE FROM events WHERE occurred_at < ?", arguments: [cutoff])
    try db.execute(
      sql: """
        DELETE FROM events
        WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 10000)
        """
    )
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

private func serviceDefinition(_ row: Row) throws -> ServiceDefinition {
  let rawManagementKind: String = row["management_kind"] ?? "unknown"
  return ServiceDefinition(
    id: row["id"],
    name: row["name"],
    group: row["group_name"],
    description: row["description"],
    enabled: row["enabled"],
    endpoints: try decode([ServiceEndpoint].self, from: row["endpoints_json"]),
    health: try decode(ServiceHealthCheck.self, from: row["health_json"]),
    managementKind: ServiceManagementKind(rawValue: rawManagementKind) ?? .unknown,
    recoveryNote: row["recovery_note"] ?? "",
    notificationsMuted: row["notifications_muted"] ?? false
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
