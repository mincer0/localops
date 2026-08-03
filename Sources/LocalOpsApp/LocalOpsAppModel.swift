import AppKit
import Combine
import Foundation
import LocalOpsCore
import LocalOpsWeb
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class LocalOpsAppModel: ObservableObject {
  @Published private(set) var overview = LocalOpsOverview.empty
  @Published private(set) var projection = LocalOpsMetadataProjection.starting
  @Published private(set) var webState: LocalWebServerState = .stopped
  @Published private(set) var isRefreshing = false
  @Published private(set) var isCoreReady = false
  @Published private(set) var launchAtLogin = false
  @Published private(set) var notificationsAuthorized = false
  @Published private(set) var mutedServiceIDs: Set<String> = []
  @Published private(set) var catalogDefinitions: [ServiceDefinition] = []
  @Published private(set) var catalogRevision = 0
  @Published private(set) var isClearingData = false
  @Published private(set) var dataClearMessage: String?
  @Published var message: String?
  @Published var pollInterval: Double {
    didSet {
      let normalized = Self.normalizePollInterval(pollInterval)
      if normalized != pollInterval {
        pollInterval = normalized
        return
      }
      UserDefaults.standard.set(normalized, forKey: Self.pollIntervalKey)
      refreshProjection()
      if let webServer {
        let threshold = projectionStaleAfter
        Task { await webServer.setStaleAfter(threshold) }
      }
    }
  }

  private(set) var paths: LocalOpsPaths?
  private var engine: LocalOpsEngine?
  private var webServer: LocalWebServer?
  private var pollingTask: Task<Void, Never>?
  private var freshnessTask: Task<Void, Never>?
  private var didInitialize = false
  private var readyHandler: (() -> Void)?
  private var stopping = false
  private let notificationCoordinator: NotificationCoordinator
  private let logger = Logger(subsystem: "io.github.mincer0.localops", category: "app")

  private static let pollIntervalKey = "localopsPollInterval"
  init() {
    notificationCoordinator = NotificationCoordinator()
    let savedInterval = UserDefaults.standard.double(forKey: Self.pollIntervalKey)
    pollInterval = Self.normalizePollInterval(savedInterval > 0 ? savedInterval : 15)
    launchAtLogin = SMAppService.mainApp.status == .enabled
    mutedServiceIDs = notificationCoordinator.mutedServiceIDs
    notificationsAuthorized = notificationCoordinator.authorized
  }

  var notificationsEnabled: Bool {
    get { notificationCoordinator.enabled }
    set {
      Task {
        await notificationCoordinator.setEnabled(newValue)
        notificationsAuthorized = notificationCoordinator.authorized
        mutedServiceIDs = notificationCoordinator.mutedServiceIDs
        objectWillChange.send()
      }
      objectWillChange.send()
    }
  }

  var webURL: URL? { webState.url }

  var bundleVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "未知"
  }

  private static let releaseURL = URL(
    string: "https://github.com/mincer0/localops/releases"
  )!

  private var projectionStaleAfter: TimeInterval {
    max(30, min(600, pollInterval * 2))
  }

  var statusItemText: String {
    switch projection.state {
    case .starting: "…"
    case .coreError: "!"
    case .stale, .partial:
      attentionServiceCount > 0 ? "\(attentionServiceCount)!" : "⚠"
    case .empty: "0"
    case .fresh:
      attentionServiceCount > 0
        ? "\(attentionServiceCount)!"
        : "\(overview.summary.healthy)/\(overview.summary.total)"
    }
  }

  var statusItemToolTip: String {
    let prefix = "LocalOps"
    switch projection.state {
    case .starting: return "\(prefix)：正在准备目录"
    case .coreError: return "\(prefix)：目录暂不可用 · \(projection.detail)"
    case .stale: return "\(prefix)：数据已过期 · \(projection.detail)"
    case .partial: return "\(prefix)：部分信息待确认"
    case .empty: return "\(prefix)：尚未登记本地服务"
    case .fresh:
      if attentionServiceCount > 0 {
        return "\(prefix)：\(attentionServiceCount) 个服务需关注"
      }
      return "\(prefix)：\(overview.summary.healthy)/\(overview.summary.total) 个服务健康"
    }
  }

  var statusItemAccessibilityLabel: String {
    "LocalOps，\(projection.title)，\(statusItemToolTip)"
  }

  private var attentionServiceCount: Int {
    let observed = overview.services.filter {
      $0.source == .registered
        && ($0.health == .unhealthy || $0.health == .degraded || $0.lifecycle == .stopped)
    }.count
    return max(observed, overview.summary.attention, overview.summary.stopped)
  }

  var priorityServices: [ServiceSnapshot] {
    let recentCutoff = Date().addingTimeInterval(-max(300, projectionStaleAfter * 2))
    let changedIDs = Set(
      overview.events
        .filter { $0.occurredAt >= recentCutoff }
        .prefix(12)
        .map(\.serviceId)
    )
    return overview.services
      .filter { service in
        service.source == .registered
          && (service.health != .healthy
            || service.lifecycle != .running
            || service.observation.freshness != .fresh
            || changedIDs.contains(service.id))
      }
      .sorted { lhs, rhs in
        priorityRank(lhs) == priorityRank(rhs)
          ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
          : priorityRank(lhs) < priorityRank(rhs)
      }
  }

  var registeredServices: [ServiceSnapshot] {
    directoryServices.filter { $0.source == .registered }
  }

  var directoryServices: [ServiceSnapshot] {
    let live = overview.services
    let liveIDs = Set(live.map(\.id))
    let disabled =
      catalogDefinitions
      .filter { !$0.enabled && !liveIDs.contains($0.id) }
      .map(disabledSnapshot)
    return live + disabled
  }

  var discoveredServices: [ServiceSnapshot] {
    overview.services.filter { $0.source == .discovered }
  }

  var historyServices: [ServiceSnapshot] {
    overview.services.filter { $0.source == .history }
  }

  func start(onReady: (() -> Void)? = nil) {
    guard pollingTask == nil, !stopping else { return }
    readyHandler = onReady
    pollingTask = Task { [weak self] in
      guard let self else { return }
      await self.runPollingLoop()
    }
    freshnessTask = Task { [weak self] in
      guard let self else { return }
      await self.runFreshnessLoop()
    }
  }

  func stop() async {
    stopping = true
    pollingTask?.cancel()
    pollingTask = nil
    freshnessTask?.cancel()
    freshnessTask = nil
    if let webServer {
      await webServer.stop(timeout: 2)
    }
    webState = .stopped
    isCoreReady = false
  }

  func refresh() async {
    guard !isRefreshing, let engine else {
      if self.engine == nil { _ = await retryInitialization() }
      return
    }
    await refresh(using: engine)
  }

  /// Destructively reset LocalOps' current SQLite catalog. Core preserves the
  /// schema, migration markers, and legacy YAML/SQLite rollback sources, then
  /// reseeds the validated built-in definitions. The post-clear refresh is
  /// best effort: a committed clear is reported separately from a fresh
  /// snapshot so the UI never implies that stale data is still current.
  func clearCurrentDirectoryData() async {
    guard !isClearingData else { return }
    guard !isRefreshing else {
      dataClearMessage = "当前正在检查，请稍后再清除目录数据。"
      return
    }
    guard let engine else {
      dataClearMessage = "目录尚未初始化，暂时无法清除数据。"
      return
    }

    isClearingData = true
    isRefreshing = true
    dataClearMessage = nil
    defer {
      isRefreshing = false
      isClearingData = false
    }

    do {
      let value = try await engine.clearCurrentDirectoryData()
      didInitialize = true
      isCoreReady = true
      apply(value)
      await synchronizeMutedDefinitions(using: engine, overview: value)
      await synchronizeCatalog(using: engine)
      notificationCoordinator.prime(value)
      let projection = value.snapshotProjection(
        now: Date(),
        staleAfter: projectionStaleAfter
      )
      if projection.ready {
        dataClearMessage = "当前目录数据已清除，并完成重新检查。"
      } else {
        dataClearMessage =
          "当前目录数据已清除，但重新检查未成功；LocalOps 将继续重试。"
      }
    } catch {
      didInitialize = false
      isCoreReady = false
      message = redact(error.localizedDescription)
      dataClearMessage = "清除当前目录数据失败：\(redact(error.localizedDescription))"
      log(error, context: "clear-directory-data")
      apply(await engine.overview())
    }
  }

  func registerObserved(id: String, name: String, group: String) async throws {
    guard let engine else { throw LocalOpsError.notInitialized }
    try await engine.registerObserved(id: id, name: name, group: group)
    apply(await engine.overview())
    await synchronizeCatalog(using: engine)
  }

  func forgetObserved(id: String) async throws {
    guard let engine else { throw LocalOpsError.notInitialized }
    try await engine.forgetObserved(id: id)
    apply(await engine.overview())
  }

  func definition(id: String) async throws -> ServiceDefinition? {
    guard let engine else { throw LocalOpsError.notInitialized }
    return try await engine.definition(id: id)
  }

  func catalogDefinition(id: String) -> ServiceDefinition? {
    catalogDefinitions.first { $0.id == id }
  }

  func updateRegisteredDefinition(_ definition: ServiceDefinition) async throws {
    guard let engine else { throw LocalOpsError.notInitialized }
    try await engine.updateRegisteredDefinition(definition)
    apply(await engine.overview())
    notificationCoordinator.setMuted(
      serviceID: definition.id,
      muted: definition.notificationsMuted
    )
    mutedServiceIDs = notificationCoordinator.mutedServiceIDs
    await synchronizeCatalog(using: engine)
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
      message = "无法更改登录项：\(redact(error.localizedDescription))"
      log(error, context: "launch-at-login")
    }
  }

  func openWebPage() {
    let validation = LocalURLPolicy.validateWebURL(webURL)
    guard let url = validation.url else {
      message = validation.message
      return
    }
    guard NSWorkspace.shared.open(url) else {
      message = "无法打开：LocalOps Web 页面启动失败。"
      return
    }
  }

  func retryWebServer() async {
    guard let webServer else {
      message = "只读 Web 尚未初始化。"
      return
    }
    webState = await webServer.start()
    if case .failed(let error) = webState {
      message = "只读 Web 暂不可用：\(redact(error))"
    } else {
      message = nil
    }
  }

  func openReleasePage() {
    guard NSWorkspace.shared.open(Self.releaseURL) else {
      message = "无法打开：LocalOps 发布页启动失败。"
      return
    }
  }

  func openDataDirectory() {
    guard let paths else { return }
    NSWorkspace.shared.activateFileViewerSelecting([paths.database])
  }

  func exportDiagnostics() {
    do {
      let data = try DiagnosticsExporter.data(
        overview: overview,
        projection: projection,
        webState: webState
      )
      let panel = NSSavePanel()
      panel.title = "导出 LocalOps 诊断"
      panel.nameFieldStringValue = "localops-diagnostics.json"
      panel.allowedContentTypes = [.json]
      panel.begin { [weak self] response in
        guard response == .OK, let url = panel.url else { return }
        do {
          try data.write(to: url, options: [.atomic])
          self?.message = "已导出脱敏诊断：\(url.lastPathComponent)"
        } catch {
          self?.message = "导出诊断失败：\(self?.redact(error.localizedDescription) ?? "未知错误")"
        }
      }
    } catch {
      message = "导出诊断失败：\(redact(error.localizedDescription))"
      log(error, context: "diagnostics-export")
    }
  }

  func openEndpoint(_ endpoint: ServiceEndpoint) {
    let validation = LocalURLPolicy.validateServiceURL(endpoint.parsedURL)
    guard let url = validation.url else {
      message = validation.message
      return
    }
    guard NSWorkspace.shared.open(url) else {
      message = "无法打开：服务入口页面启动失败。"
      return
    }
  }

  func toggleMute(for serviceID: String) {
    Task { [weak self] in
      guard let self else { return }
      do {
        guard var updated = try await definition(id: serviceID) else {
          throw LocalOpsError.invalidService("找不到登记服务：\(serviceID)")
        }
        updated.notificationsMuted.toggle()
        try await updateRegisteredDefinition(updated)
      } catch {
        message = "无法更新通知静音：\(redact(error.localizedDescription))"
        log(error, context: "notification-mute")
      }
    }
  }

  func isMuted(_ serviceID: String) -> Bool { mutedServiceIDs.contains(serviceID) }

  private func runPollingLoop() async {
    var retryDelay = 1.0
    while !Task.isCancelled && !stopping {
      guard let engine = ensureRuntime() else {
        refreshProjection()
        await sleep(seconds: retryDelay)
        retryDelay = min(60, retryDelay * 2)
        continue
      }

      if !didInitialize {
        isRefreshing = true
        do {
          let initial = try await engine.initialize()
          didInitialize = true
          retryDelay = 1
          apply(initial)
          await notificationCoordinator.refreshAuthorization()
          notificationsAuthorized = notificationCoordinator.authorized
          await synchronizeMutedDefinitions(using: engine, overview: initial)
          await synchronizeCatalog(using: engine)
          notificationCoordinator.prime(initial)
          isCoreReady = true
          readyHandler?()
          readyHandler = nil
          if let webServer {
            webState = await webServer.start()
          }
        } catch {
          isRefreshing = false
          didInitialize = false
          message = redact(error.localizedDescription)
          log(error, context: "initialize")
          apply(await engine.overview())
          await sleep(seconds: retryDelay)
          retryDelay = min(60, retryDelay * 2)
          continue
        }
        isRefreshing = false
      } else {
        await refresh(using: engine)
        if let webServer { webState = await webServer.state() }
      }

      await sleep(seconds: pollInterval)
    }
  }

  private func ensureRuntime() -> LocalOpsEngine? {
    if let engine { return engine }
    do {
      let paths = try LocalOpsPaths.live()
      let engine = try LocalOpsEngine(paths: paths)
      self.paths = paths
      self.engine = engine
      self.webServer = try LocalWebServer(engine: engine, staleAfter: projectionStaleAfter)
      message = nil
      return engine
    } catch {
      message = redact(error.localizedDescription)
      log(error, context: "runtime")
      return nil
    }
  }

  private func retryInitialization() async -> Bool {
    guard let engine = ensureRuntime() else { return false }
    do {
      isRefreshing = true
      let value = try await engine.initialize()
      didInitialize = true
      apply(value)
      await notificationCoordinator.refreshAuthorization()
      notificationsAuthorized = notificationCoordinator.authorized
      await synchronizeMutedDefinitions(using: engine, overview: value)
      await synchronizeCatalog(using: engine)
      notificationCoordinator.prime(value)
      isCoreReady = true
      if let webServer { webState = await webServer.start() }
      isRefreshing = false
      return true
    } catch {
      isRefreshing = false
      didInitialize = false
      message = redact(error.localizedDescription)
      log(error, context: "retry-initialize")
      apply(await engine.overview())
      return false
    }
  }

  private func refresh(using engine: LocalOpsEngine) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    let value = await engine.refresh()
    apply(value)
    isRefreshing = false
    await notificationCoordinator.process(value)
  }

  private func runFreshnessLoop() async {
    while !Task.isCancelled && !stopping {
      await sleep(seconds: 0.5)
      guard !Task.isCancelled, !stopping else { return }
      refreshProjection()
    }
  }

  private func synchronizeMutedDefinitions(
    using engine: LocalOpsEngine,
    overview: LocalOpsOverview
  ) async {
    let serviceIDs: [String]
    if let definitions = try? await engine.definitions() {
      serviceIDs = definitions.map(\.id)
    } else {
      serviceIDs = overview.services
        .filter { $0.source == .registered }
        .map(\.id)
    }
    guard !serviceIDs.isEmpty else {
      notificationCoordinator.synchronizeMutedServiceIDs([])
      mutedServiceIDs = notificationCoordinator.mutedServiceIDs
      return
    }

    let results = await withTaskGroup(
      of: (String, Bool, Bool).self, returning: [(String, Bool, Bool)].self
    ) {
      group in
      for serviceID in serviceIDs {
        group.addTask {
          guard let definition = try? await engine.definition(id: serviceID) else {
            return (serviceID, false, false)
          }
          return (serviceID, definition.notificationsMuted, true)
        }
      }
      var values: [(String, Bool, Bool)] = []
      for await result in group {
        values.append(result)
      }
      return values
    }
    guard results.allSatisfy({ $0.2 }) else {
      logger.error("notification mute synchronization skipped: persisted definition unavailable")
      return
    }
    let mutedIDs = Set(results.compactMap { $0.1 ? $0.0 : nil })
    notificationCoordinator.synchronizeMutedServiceIDs(mutedIDs)
    mutedServiceIDs = notificationCoordinator.mutedServiceIDs
  }

  private func synchronizeCatalog(using engine: LocalOpsEngine) async {
    do {
      catalogDefinitions = try await engine.definitions()
      catalogRevision &+= 1
    } catch {
      logger.error(
        "catalog synchronization failed: \(self.redact(error.localizedDescription), privacy: .public)"
      )
    }
  }

  private func disabledSnapshot(_ definition: ServiceDefinition) -> ServiceSnapshot {
    ServiceSnapshot(
      id: definition.id,
      name: definition.name,
      group: definition.group,
      description: definition.description,
      source: .registered,
      lifecycle: .unknown,
      health: .unknown,
      endpoints: definition.endpoints,
      message: "检查已停用",
      presence: .unknown,
      observation: ObservationEvidence(
        state: .unknown,
        freshness: .unknown,
        message: "检查已停用"
      )
    )
  }

  private func apply(_ value: LocalOpsOverview) {
    overview = value
    refreshProjection()
    if let error = value.error {
      message = redact(error)
    } else if projection.state == .fresh || projection.state == .empty {
      message = nil
    }
  }

  private func refreshProjection(now: Date = Date()) {
    projection = overview.snapshotProjection(now: now, staleAfter: projectionStaleAfter)
  }

  private func sleep(seconds: Double) async {
    let duration = UInt64(max(0.2, seconds) * 1_000_000_000)
    try? await Task.sleep(nanoseconds: duration)
  }

  private func priorityRank(_ service: ServiceSnapshot) -> Int {
    if service.lifecycle == .stopped || service.health == .unhealthy { return 0 }
    if service.health == .degraded { return 1 }
    if service.observation.freshness != .fresh { return 2 }
    return 3
  }

  private static func normalizePollInterval(_ value: Double) -> Double {
    guard value.isFinite else { return 15 }
    return min(300, max(15, value.rounded()))
  }

  private func log(_ error: Error, context: String) {
    logger.error(
      "\(context, privacy: .public): \(self.redact(error.localizedDescription), privacy: .public)")
  }

  private func redact(_ value: String) -> String {
    var result = value
    result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    result = result.replacingOccurrences(
      of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"(?i)(token|secret|password|authorization)=([^&\s]+)"#,
      with: "$1=REDACTED",
      options: .regularExpression)
    return String(result.prefix(500))
  }
}

extension ServiceHealth {
  var title: String {
    switch self {
    case .healthy: "健康"
    case .degraded: "需关注"
    case .unhealthy: "异常"
    case .unknown: "未检查"
    }
  }

  var icon: String {
    switch self {
    case .healthy: "checkmark.circle.fill"
    case .degraded: "exclamationmark.triangle.fill"
    case .unhealthy: "xmark.circle.fill"
    case .unknown: "questionmark.circle"
    }
  }
}

extension ServiceSource {
  var title: String {
    switch self {
    case .registered: "已登记"
    case .discovered: "待登记"
    case .history: "最近掉线"
    }
  }
}

extension ObservationFreshness {
  var title: String {
    switch self {
    case .fresh: "最新"
    case .partial: "部分"
    case .stale: "已过期"
    case .unknown: "未知"
    }
  }
}

extension ObservationState {
  var title: String {
    switch self {
    case .observed: "已观察"
    case .ambiguous: "归属不明"
    case .notObserved: "未观察到"
    case .unknown: "未知"
    }
  }
}

extension ServicePresence {
  var title: String {
    switch self {
    case .online: "在线"
    case .offline: "离线"
    case .unknown: "未知"
    }
  }
}

extension LocalOpsThermalState {
  var title: String {
    switch self {
    case .nominal: "正常"
    case .fair: "偏热"
    case .serious: "严重"
    case .critical: "临界"
    case .unknown: "未知"
    }
  }

  var requiresAttention: Bool {
    switch self {
    case .fair, .serious, .critical: true
    case .nominal, .unknown: false
    }
  }
}
