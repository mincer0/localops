import Foundation
import LocalOpsCore
import OSLog
@preconcurrency import UserNotifications

@MainActor
final class NotificationCoordinator {
  private enum ServiceState: Equatable {
    case offline
    case healthy
  }

  private let enabledKey = "localopsNotificationsEnabled"
  private let mutedKey = "localopsMutedServiceIDs"
  private let logger = Logger(
    subsystem: "io.github.mincer0.localops",
    category: "notifications"
  )
  private var notifiedStates: [String: ServiceState] = [:]

  private(set) var enabled: Bool
  private(set) var authorized: Bool
  private(set) var mutedServiceIDs: Set<String>

  init() {
    enabled = UserDefaults.standard.bool(forKey: enabledKey)
    authorized = UserDefaults.standard.bool(forKey: "\(enabledKey).authorized")
    mutedServiceIDs = Set(
      UserDefaults.standard.stringArray(forKey: mutedKey) ?? []
    )
  }

  func setEnabled(_ value: Bool) async {
    guard value else {
      enabled = false
      UserDefaults.standard.set(false, forKey: enabledKey)
      UserDefaults.standard.set(authorized, forKey: "\(enabledKey).authorized")
      return
    }

    let granted =
      (try? await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .sound])) ?? false
    enabled = granted
    authorized = granted
    UserDefaults.standard.set(granted, forKey: enabledKey)
    UserDefaults.standard.set(granted, forKey: "\(enabledKey).authorized")
  }

  func refreshAuthorization() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    let allowed =
      settings.authorizationStatus == .authorized
      || settings.authorizationStatus == .provisional
    authorized = allowed
    if !allowed {
      enabled = false
      UserDefaults.standard.set(false, forKey: enabledKey)
    }
    UserDefaults.standard.set(allowed, forKey: "\(enabledKey).authorized")
  }

  func setMuted(serviceID: String, muted: Bool) {
    if muted {
      mutedServiceIDs.insert(serviceID)
    } else {
      mutedServiceIDs.remove(serviceID)
    }
    UserDefaults.standard.set(Array(mutedServiceIDs).sorted(), forKey: mutedKey)
  }

  func synchronizeMutedServiceIDs(_ serviceIDs: Set<String>) {
    mutedServiceIDs = serviceIDs
    UserDefaults.standard.set(Array(serviceIDs).sorted(), forKey: mutedKey)
  }

  func isMuted(_ serviceID: String) -> Bool {
    mutedServiceIDs.contains(serviceID)
  }

  /// Seed confirmed states without emitting notifications. This is used after
  /// initialization/reset so a persisted offline snapshot is a baseline rather
  /// than a newly observed outage.
  func prime(_ overview: LocalOpsOverview) {
    let registeredIDs = Set(
      overview.services.filter { $0.source == .registered }.map(\.id)
    )
    notifiedStates = notifiedStates.filter { registeredIDs.contains($0.key) }
    for service in overview.services where service.source == .registered {
      if service.presence == .offline {
        notifiedStates[service.id] = .offline
      } else if service.presence == .online, service.health == .healthy {
        notifiedStates[service.id] = .healthy
      }
    }
  }

  /// Offline and recovery notifications are intentionally edge-triggered.
  /// Core applies the failure hysteresis and only exposes `presence == .offline`
  /// once that state is confirmed, so the UI must not maintain a second
  /// failure counter here. A confirmed offline transition emits one event;
  /// a later confirmed healthy transition emits one recovery event.
  func process(_ overview: LocalOpsOverview) async {
    for service in overview.services where service.source == .registered {
      // Do not infer offline from a single failed probe. LocalOpsCore's
      // persisted failure hysteresis rewrites the snapshot to `.offline`
      // only after the required consecutive failures.
      let state: ServiceState?
      if service.presence == .offline {
        state = .offline
      } else if service.presence == .online && service.health == .healthy {
        state = .healthy
      } else {
        // Unknown/degraded/partial observations do not constitute a state
        // transition. Keep the last confirmed edge until Core confirms a
        // healthy or offline state.
        state = nil
      }

      guard let state, notifiedStates[service.id] != state else { continue }
      let previous = notifiedStates.updateValue(state, forKey: service.id)

      // State tracking remains active while notifications are globally
      // disabled or muted, so enabling/unmuting cannot replay an old edge.
      guard enabled, authorized, !isMuted(service.id) else { continue }
      switch state {
      case .offline:
        await send(
          title: "服务离线",
          body: "\(service.name)：\(service.message ?? "无法通过健康检查")"
        )
      case .healthy:
        guard previous == .offline else { continue }
        await send(title: "服务已恢复", body: "\(service.name) 已恢复健康")
      }
    }
  }

  private func send(title: String, body: String) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = redact(body)
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "localops.\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    do {
      try await UNUserNotificationCenter.current().add(request)
    } catch {
      logger.error(
        "notification failed: \(self.redact(error.localizedDescription), privacy: .public)"
      )
    }
  }

  private func redact(_ value: String) -> String {
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
