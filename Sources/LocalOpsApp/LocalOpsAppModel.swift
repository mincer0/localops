import AppKit
import Combine
import Foundation
import LocalOpsCore
import LocalOpsWeb
import ServiceManagement

@MainActor
final class LocalOpsAppModel: ObservableObject {
  @Published private(set) var overview = LocalOpsOverview.empty
  @Published private(set) var webState: LocalWebServerState = .stopped
  @Published private(set) var isRefreshing = false
  @Published private(set) var launchAtLogin = false
  @Published var message: String?
  @Published var pollInterval: Double {
    didSet {
      UserDefaults.standard.set(pollInterval, forKey: Self.pollIntervalKey)
    }
  }

  private(set) var paths: LocalOpsPaths?
  private var engine: LocalOpsEngine?
  private var webServer: LocalWebServer?
  private var pollingTask: Task<Void, Never>?

  private static let pollIntervalKey = "localopsPollInterval"

  init() {
    let savedInterval = UserDefaults.standard.double(forKey: Self.pollIntervalKey)
    pollInterval = savedInterval > 0 ? savedInterval : 15
    launchAtLogin = SMAppService.mainApp.status == .enabled
    do {
      let paths = try LocalOpsPaths.live()
      let engine = try LocalOpsEngine(paths: paths)
      self.paths = paths
      self.engine = engine
      self.webServer = try LocalWebServer(engine: engine)
    } catch {
      paths = nil
      engine = nil
      webServer = nil
      message = error.localizedDescription
    }
  }

  var statusItemText: String {
    guard overview.refreshedAt != nil else { return "—" }
    if overview.summary.attention > 0 || overview.summary.stopped > 0
      || overview.system.thermalState.requiresAttention
    {
      return "\(overview.summary.healthy)!"
    }
    return "\(overview.summary.healthy)/\(overview.summary.total)"
  }

  var statusItemToolTip: String {
    guard overview.refreshedAt != nil else { return "LocalOps：正在初始化" }
    let services = "LocalOps：\(overview.summary.healthy)/\(overview.summary.total) 个服务健康"
    guard overview.system.thermalState != .nominal,
      overview.system.thermalState != .unknown
    else { return services }
    return "\(services) · 热状态：\(overview.system.thermalState.title)"
  }

  var webURL: URL? { webState.url }

  func start() {
    guard pollingTask == nil, let engine else { return }
    pollingTask = Task { [weak self] in
      guard let self else { return }
      do {
        overview = try await engine.initialize()
        if let webServer {
          webState = await webServer.start()
        }
      } catch {
        message = error.localizedDescription
      }

      while !Task.isCancelled {
        let seconds = UInt64(max(5, pollInterval))
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { break }
        await refresh()
        if let webServer { webState = await webServer.state() }
      }
    }
  }

  func stop() {
    pollingTask?.cancel()
    pollingTask = nil
    if let webServer {
      Task { await webServer.stop() }
    }
  }

  func refresh() async {
    guard !isRefreshing, let engine else { return }
    isRefreshing = true
    overview = await engine.refresh()
    isRefreshing = false
  }

  func registerObserved(id: String, name: String, group: String) async throws {
    guard let engine else { return }
    try await engine.registerObserved(id: id, name: name, group: group)
    overview = await engine.overview()
  }

  func forgetObserved(id: String) async throws {
    guard let engine else { return }
    try await engine.forgetObserved(id: id)
    overview = await engine.overview()
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLogin = SMAppService.mainApp.status == .enabled
      message = launchAtLogin ? "已设为登录后自动启动" : "已关闭登录自动启动"
    } catch {
      launchAtLogin = SMAppService.mainApp.status == .enabled
      message = "无法更改登录项：\(error.localizedDescription)"
    }
  }

  func openWebPage() {
    guard let webURL else { return }
    NSWorkspace.shared.open(webURL)
  }

  func openDataDirectory() {
    guard let paths else { return }
    NSWorkspace.shared.activateFileViewerSelecting([paths.database])
  }
}
