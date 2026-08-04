import Foundation

public struct LegacyServiceMigrator: Sendable {
  public init() {}

  public struct Report: Sendable {
    public var definitions: [ServiceDefinition]
    public var errors: [String]

    public init(definitions: [ServiceDefinition] = [], errors: [String] = []) {
      self.definitions = definitions
      self.errors = errors
    }
  }

  public func load(from files: [URL]) -> [ServiceDefinition] {
    loadReport(from: files).definitions
  }

  public func loadReport(from files: [URL]) -> Report {
    var definitions: [ServiceDefinition] = []
    var errors: [String] = []
    var ids = Set<String>()
    for file in files {
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        errors.append("\(file.lastPathComponent) 无法读取")
        continue
      }
      let before = definitions.count
      for definition in parse(text) {
        if ids.insert(definition.id).inserted {
          definitions.append(definition)
        }
      }
      // Only the primary `services:` document has a required shape.  The
      // claimed-services file came from several historical formats, so an
      // empty, comment-only, or otherwise unrelated file must not be treated
      // as a migration failure.  A non-empty services document that produces
      // no valid definition is actionable (including inline forms such as
      // `services: [broken`).
      if nonEmptyServicesDocument(text) && definitions.count == before {
        errors.append("\(file.lastPathComponent) 未解析出有效服务")
      }
    }
    return Report(definitions: definitions, errors: errors)
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

      if indentation == 4 {
        flushEndpoint()
        switch line {
        case "endpoints:":
          section = .endpoints
          continue
        case "health:":
          section = .health
          continue
        case "manager:", "tags:":
          section = .ignored
          continue
        default:
          section = .service
        }
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

  /// Return whether a YAML text contains a non-empty top-level `services:`
  /// value. This intentionally does not classify arbitrary non-comment text
  /// as a failed migration because claimed-services.yaml may use another
  /// shape. Inline values (`services: [broken`) are considered non-empty and
  /// therefore must report a parse error when no valid service is produced.
  fileprivate func nonEmptyServicesDocument(_ text: String) -> Bool {
    let lines = text.split(whereSeparator: \.isNewline)
    for (index, rawLine) in lines.enumerated() {
      let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count
      guard leadingSpaces == 0 else { continue }
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#"), line.hasPrefix("services:") else {
        continue
      }
      let value = String(line.dropFirst("services:".count))
        .trimmingCharacters(in: .whitespaces)
      if value.isEmpty {
        // A block value is non-empty when it has any meaningful indented
        // child before the next top-level key.
        for child in lines.dropFirst(index + 1) {
          let childIndent = child.prefix(while: { $0 == " " }).count
          let childLine = child.trimmingCharacters(in: .whitespaces)
          guard !childLine.isEmpty, !childLine.hasPrefix("#") else { continue }
          if childIndent == 0 { break }
          return true
        }
        return false
      }
      let withoutComment =
        value.split(separator: "#", maxSplits: 1).first.map(String.init)
        ?? value
      let normalized = withoutComment.trimmingCharacters(in: .whitespaces)
      return !normalized.isEmpty && normalized != "[]" && normalized != "[ ]"
    }
    return false
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
