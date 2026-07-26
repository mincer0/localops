import Darwin
import FlyingFox
import FlyingSocks
import Foundation
import LocalOpsCore

public enum LocalWebServerState: Equatable, Sendable {
  case stopped
  case starting
  case running(URL)
  case failed(String)

  public var url: URL? {
    if case .running(let url) = self { return url }
    return nil
  }
}

public actor LocalWebServer {
  private let engine: LocalOpsEngine
  private let requestedPort: UInt16
  private let assets: WebAssets
  private var server: HTTPServer?
  private var runTask: Task<Void, Never>?
  private var currentState: LocalWebServerState = .stopped

  public init(engine: LocalOpsEngine, port: UInt16 = 8042) throws {
    self.engine = engine
    self.requestedPort = port
    self.assets = try WebAssets.load()
  }

  public func state() -> LocalWebServerState {
    currentState
  }

  @discardableResult
  public func start() async -> LocalWebServerState {
    switch currentState {
    case .starting, .running:
      return currentState
    case .stopped, .failed:
      break
    }

    currentState = .starting
    do {
      let address: sockaddr_in = try .inet(ip4: "127.0.0.1", port: requestedPort)
      let server = HTTPServer(address: address, logger: .disabled)
      await installRoutes(on: server)
      self.server = server
      let task = Task { [weak self, server] in
        do {
          try await server.run()
        } catch {
          guard !Task.isCancelled else { return }
          await self?.recordFailure(error)
        }
      }
      runTask = task
      try await server.waitUntilListening(timeout: 3)
      let port = await listeningPort(of: server) ?? requestedPort
      let url = URL(string: "http://127.0.0.1:\(port)")!
      currentState = .running(url)
    } catch {
      runTask?.cancel()
      runTask = nil
      if let server { await server.stop() }
      server = nil
      currentState = .failed(error.localizedDescription)
    }
    return currentState
  }

  public func stop() async {
    runTask?.cancel()
    runTask = nil
    if let server { await server.stop(timeout: 1) }
    server = nil
    currentState = .stopped
  }

  private func recordFailure(_ error: Error) {
    currentState = .failed(error.localizedDescription)
    server = nil
    runTask = nil
  }

  private func installRoutes(on server: HTTPServer) async {
    let engine = self.engine
    let assets = self.assets

    await server.appendRoute("GET /") { _ in
      htmlResponse(assets.index)
    }
    await server.appendRoute("GET /static/localops.css") { _ in
      assetResponse(assets.css, contentType: "text/css; charset=utf-8")
    }
    await server.appendRoute("GET /static/localops.js") { _ in
      assetResponse(assets.javascript, contentType: "text/javascript; charset=utf-8")
    }
    await server.appendRoute("GET /healthz") { _ in
      jsonResponse(Data(#"{"status":"ok"}"#.utf8))
    }
    await server.appendRoute("GET /readyz") { _ in
      let overview = await engine.overview()
      let ready = overview.refreshedAt != nil
      return jsonResponse(
        Data((ready ? #"{"status":"ready"}"# : #"{"status":"not_ready"}"#).utf8),
        status: ready ? .ok : .serviceUnavailable
      )
    }
    await server.appendRoute("GET /api/v1/overview") { _ in
      jsonResponse(try encodeAPI(await engine.overview()))
    }
    await server.appendRoute("GET /api/v1/services") { _ in
      jsonResponse(try encodeAPI(await engine.overview().services))
    }
    await server.appendRoute("GET /api/v1/services/:id") { request in
      guard let id = request.routeParameters["id"], let service = await engine.service(id: id)
      else {
        return jsonResponse(
          Data(#"{"detail":"Service not found"}"#.utf8),
          status: .notFound
        )
      }
      return jsonResponse(try encodeAPI(service))
    }
    await server.appendRoute("GET /api/v1/events") { _ in
      jsonResponse(try encodeAPI(await engine.overview().events))
    }
  }
}

private struct WebAssets: Sendable {
  var index: Data
  var css: Data
  var javascript: Data

  static func load() throws -> WebAssets {
    WebAssets(
      index: try resource(named: "index", extension: "html"),
      css: try resource(named: "localops", extension: "css"),
      javascript: try resource(named: "localops", extension: "js")
    )
  }

  private static func resource(named name: String, extension fileExtension: String) throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Web"
      ) ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    else {
      throw LocalOpsError.resourceMissing("\(name).\(fileExtension)")
    }
    return try Data(contentsOf: url)
  }
}

private func listeningPort(of server: HTTPServer) async -> UInt16? {
  switch await server.listeningAddress {
  case .ip4(_, let port), .ip6(_, let port): port
  default: nil
  }
}

private func encodeAPI<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(value)
}

private func baseHeaders(contentType: String) -> HTTPHeaders {
  [
    .contentType: contentType,
    .cacheControl: "no-store",
    HTTPHeader("X-Content-Type-Options"): "nosniff",
    HTTPHeader("Referrer-Policy"): "no-referrer",
  ]
}

private func htmlResponse(_ data: Data) -> HTTPResponse {
  var headers = baseHeaders(contentType: "text/html; charset=utf-8")
  headers[HTTPHeader("Content-Security-Policy")] =
    "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'"
  return HTTPResponse(statusCode: .ok, headers: headers, body: data)
}

private func assetResponse(_ data: Data, contentType: String) -> HTTPResponse {
  HTTPResponse(statusCode: .ok, headers: baseHeaders(contentType: contentType), body: data)
}

private func jsonResponse(
  _ data: Data,
  status: HTTPStatusCode = .ok
) -> HTTPResponse {
  HTTPResponse(
    statusCode: status,
    headers: baseHeaders(contentType: "application/json; charset=utf-8"),
    body: data
  )
}
