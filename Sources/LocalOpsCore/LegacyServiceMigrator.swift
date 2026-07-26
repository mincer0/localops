import Foundation

public struct LegacyServiceMigrator: Sendable {
  public init() {}

  public func load(from files: [URL]) -> [ServiceDefinition] {
    var definitions: [ServiceDefinition] = []
    var ids = Set<String>()
    for file in files {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      for definition in parse(text) {
        if ids.insert(definition.id).inserted {
          definitions.append(definition)
        }
      }
    }
    return definitions
  }
}

extension LegacyServiceMigrator {
  fileprivate enum Section {
    case service
    case endpoints
    case health
    case ignored
  }

  fileprivate struct EndpointBuilder {
    var name = "入口"
    var url: String?

    var value: ServiceEndpoint? {
      url.map { ServiceEndpoint(name: name, url: $0) }
    }
  }

  fileprivate struct ServiceBuilder {
    var id: String?
    var name: String?
    var group = "其他"
    var description = ""
    var enabled = true
    var endpoints: [ServiceEndpoint] = []
    var healthType: HealthCheckType = .none
    var healthURL: String?
    var healthHost = "127.0.0.1"
    var healthPort: Int?
    var healthPID: Int?
    var timeout = 3.0

    var value: ServiceDefinition? {
      guard let id, !id.isEmpty else { return nil }
      let definition = ServiceDefinition(
        id: id,
        name: name ?? id,
        group: group,
        description: description,
        enabled: enabled,
        endpoints: endpoints,
        health: ServiceHealthCheck(
          type: healthType,
          url: healthURL,
          host: healthHost,
          port: healthPort,
          pid: healthPID,
          timeoutSeconds: timeout
        )
      )
      return try? definition.validated()
    }
  }

  fileprivate func parse(_ text: String) -> [ServiceDefinition] {
    var output: [ServiceDefinition] = []
    var service: ServiceBuilder?
    var endpoint: EndpointBuilder?
    var section: Section = .service

    func flushEndpoint() {
      if let value = endpoint?.value { service?.endpoints.append(value) }
      endpoint = nil
    }

    func flushService() {
      flushEndpoint()
      if let value = service?.value { output.append(value) }
      service = nil
    }

    for rawLine in text.split(whereSeparator: \.isNewline) {
      let indentation = rawLine.prefix(while: { $0 == " " }).count
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }

      if indentation == 2, line.hasPrefix("- id:") {
        flushService()
        service = ServiceBuilder()
        section = .service
        service?.id = scalar(afterColonIn: line)
        continue
      }
      guard service != nil else { continue }

      if indentation == 4, line == "endpoints:" {
        flushEndpoint()
        section = .endpoints
        continue
      }
      if indentation == 4, line == "health:" {
        flushEndpoint()
        section = .health
        continue
      }
      if indentation == 4, line == "manager:" || line == "tags:" {
        flushEndpoint()
        section = .ignored
        continue
      }
      if indentation == 4 {
        flushEndpoint()
        section = .service
      }

      switch section {
      case .service:
        let key = key(in: line)
        let value = scalar(afterColonIn: line)
        switch key {
        case "id": service?.id = value
        case "name": service?.name = value
        case "group": service?.group = value
        case "description": service?.description = value
        case "enabled": service?.enabled = value.lowercased() != "false"
        default: break
        }
      case .endpoints:
        if line.hasPrefix("- ") {
          flushEndpoint()
          endpoint = EndpointBuilder()
        }
        let key = key(in: line.trimmingPrefix("- "))
        let value = scalar(afterColonIn: line)
        if key == "name" { endpoint?.name = value }
        if key == "url" { endpoint?.url = value }
      case .health:
        let key = key(in: line)
        let value = scalar(afterColonIn: line)
        switch key {
        case "type": service?.healthType = HealthCheckType(rawValue: value) ?? .none
        case "url": service?.healthURL = value
        case "host": service?.healthHost = value
        case "port": service?.healthPort = Int(value)
        case "pid": service?.healthPID = Int(value)
        case "timeout_seconds": service?.timeout = Double(value) ?? 3
        default: break
        }
      case .ignored:
        break
      }
    }
    flushService()
    return output
  }

  fileprivate func key(in line: String) -> String {
    String(line.split(separator: ":", maxSplits: 1).first ?? "")
      .trimmingCharacters(in: .whitespaces)
  }

  fileprivate func scalar(afterColonIn line: String) -> String {
    guard let colon = line.firstIndex(of: ":") else { return "" }
    var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    if value.count >= 2,
      value.hasPrefix("\"") && value.hasSuffix("\"")
        || value.hasPrefix("'") && value.hasSuffix("'")
    {
      value.removeFirst()
      value.removeLast()
    }
    return value
  }
}

extension String {
  fileprivate func trimmingPrefix(_ prefix: String) -> String {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
  }
}
