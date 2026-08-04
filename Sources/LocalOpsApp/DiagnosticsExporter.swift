import CryptoKit
import Foundation
import LocalOpsCore
import LocalOpsWeb

struct DiagnosticsExporter {
  static func data(
    overview: LocalOpsOverview,
    projection: LocalOpsMetadataProjection,
    webState: LocalWebServerState
  ) throws -> Data {
    let payload: [String: Any] = [
      "format": "localops-diagnostics-v1",
      "exported_at": ISO8601DateFormatter().string(from: Date()),
      "state": [
        "kind": projection.state.rawValue,
        "generation": projection.generation,
        "outcome": projection.outcome.rawValue,
        "freshness": projection.freshness.rawValue,
        "attempted_at": projection.attemptedAt.map(iso) as Any,
        "successful_at": projection.successfulAt.map(iso) as Any,
        "error": projection.error.map(redact) as Any,
      ],
      "summary": [
        "total": overview.summary.total,
        "healthy": overview.summary.healthy,
        "attention": overview.summary.attention,
        "stopped": overview.summary.stopped,
        "discovered": overview.summary.discovered,
        "offline_history": overview.summary.offlineHistory,
        "unknown": overview.summary.unknown,
        "stale": overview.summary.stale,
      ],
      "web": webPayload(webState),
      "services": overview.services.map(servicePayload),
      "events": overview.events.prefix(50).map(eventPayload),
    ]
    guard JSONSerialization.isValidJSONObject(payload) else {
      throw ExportError.invalidPayload
    }
    return try JSONSerialization.data(
      withJSONObject: payload,
      options: [.prettyPrinted, .sortedKeys]
    )
  }

  private static func webPayload(_ state: LocalWebServerState) -> [String: Any] {
    switch state {
    case .stopped: ["state": "stopped"]
    case .starting: ["state": "starting"]
    case .failed(let message): ["state": "failed", "error": redact(message)]
    case .running(let url):
      ["state": "running", "port": url.port as Any]
    }
  }

  private static func servicePayload(_ service: ServiceSnapshot) -> [String: Any] {
    [
      "id": redact(service.id),
      "name": redact(service.name),
      "group": redact(service.group),
      "description": redact(service.description),
      "source": service.source.rawValue,
      "lifecycle": service.lifecycle.rawValue,
      "health": service.health.rawValue,
      "presence": service.presence.rawValue,
      "latency_ms": service.latencyMs as Any,
      "checked_at": service.checkedAt.map(iso) as Any,
      "last_seen_at": service.lastSeenAt.map(iso) as Any,
      "pid": service.pid as Any,
      "process_name": service.processName.map(redact) as Any,
      "observation": [
        "state": service.observation.state.rawValue,
        "freshness": service.observation.freshness.rawValue,
        "match_confidence": service.observation.matchConfidence.rawValue,
        "host": service.observation.host as Any,
        "port": service.observation.port as Any,
        "pid": service.observation.pid as Any,
        "process_fingerprint": service.observation.processFingerprint.map(redact) as Any,
        "process_name": service.observation.processName.map(redact) as Any,
        "observed_at": service.observation.observedAt.map(iso) as Any,
        "message": service.observation.message.map(redact) as Any,
      ],
    ]
  }

  private static func eventPayload(_ event: LocalOpsEvent) -> [String: Any] {
    [
      "id": redact(String(event.id)),
      "occurred_at": iso(event.occurredAt),
      "service_id": redact(event.serviceId),
      "service_name": redact(event.serviceName),
      "kind": event.kind,
      "severity": event.severity,
      "message": redact(event.message),
    ]
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func redact(_ value: String) -> String {
    guard !value.isEmpty else { return "" }
    var normalized = value
    normalized = normalized.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    normalized = normalized.replacingOccurrences(
      of: #"/Users/[^/\s]+"#,
      with: "~",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(
      of: #"(?i)(token|secret|password|authorization)=([^&\s]+)"#,
      with: "$1=REDACTED",
      options: .regularExpression
    )
    let digest = SHA256.hash(data: Data(normalized.utf8))
    let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "<redacted-\(suffix)>"
  }
}

enum ExportError: LocalizedError {
  case invalidPayload

  var errorDescription: String? {
    "诊断数据无法编码"
  }
}
