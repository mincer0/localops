import AppKit
import LocalOpsCore
import LocalOpsWeb
import SwiftUI

struct MenuPopoverView: View {
  @ObservedObject var model: LocalOpsAppModel
  let openDashboard: () -> Void
  let quit: () -> Void

  private var visibleServices: [ServiceSnapshot] {
    Array(model.priorityServices.prefix(5))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("LocalOps")
              .font(.title2.weight(.semibold))
            Text(model.projection.title)
              .font(.caption.weight(.medium))
              .foregroundStyle(model.projection.state.color)
          }
          Spacer(minLength: 8)
          if model.isRefreshing {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在检查")
          }
          Button {
            Task { await model.refresh() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .disabled(model.isRefreshing)
          .help("立即检查")
          .accessibilityLabel("立即检查")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)

        SnapshotBanner(projection: model.projection) {
          Task { await model.refresh() }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)

        Divider()

        if model.projection.state == .fresh && visibleServices.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Label(
              "全部 \(model.overview.summary.total) 个服务正常",
              systemImage: "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)
            Text("打开管理窗口查看完整目录。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
        } else if model.projection.state == .empty {
          EmptyState(
            title: "还没有服务",
            detail: "LocalOps 会继续扫描本机监听端口。",
            icon: "tray"
          )
          .padding(16)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text(visibleServices.isEmpty ? "最近状态" : "需要留意")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .textCase(.uppercase)
            if visibleServices.isEmpty {
              Text("没有新的异常或状态变化。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
              ForEach(visibleServices) { service in
                MenuServiceRow(service: service)
              }
            }
            if model.priorityServices.count > visibleServices.count {
              Text("还有 \(model.priorityServices.count - visibleServices.count) 个状态需要查看")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .padding(12)
        }

        Divider()
        VStack(spacing: 8) {
          Button(action: openDashboard) {
            Label("打开服务目录", systemImage: "sidebar.left")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Label(webLabel, systemImage: webIcon)
                .font(.caption)
                .foregroundStyle(webColor)
                .lineLimit(1)
              Text(webAddressLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if case .failed = model.webState {
              Button("重试") { Task { await model.retryWebServer() } }
            }
            Button("Web") { model.openWebPage() }
              .disabled(model.webURL == nil)
            Button("退出", action: quit)
          }
          .accessibilityElement(children: .contain)
        }
        .padding(12)
      }
    }
    .frame(width: 390)
    .frame(maxHeight: 590)
  }

  private var webLabel: String {
    switch model.webState {
    case .running: "只读 Web · 运行中"
    case .starting: "只读 Web · 启动中"
    case .failed: "只读 Web · 不可用"
    case .stopped: "只读 Web · 已停止"
    }
  }

  private var webIcon: String {
    switch model.webState {
    case .running: "checkmark.circle"
    case .starting: "hourglass"
    case .failed: "exclamationmark.triangle"
    case .stopped: "stop.circle"
    }
  }

  private var webColor: Color {
    switch model.webState {
    case .running: .green
    case .starting: .orange
    case .failed: .red
    case .stopped: .secondary
    }
  }

  private var webAddressLabel: String {
    guard case .running(let url) = model.webState,
      let host = url.host,
      let port = url.port,
      LocalURLPolicy.validateWebURL(url).isValid
    else {
      return "127.0.0.1:8042"
    }
    return "\(host):\(port)"
  }
}

private struct SnapshotBanner: View {
  let projection: LocalOpsMetadataProjection
  let retry: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if projection.state == .starting {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: projection.state.icon)
          .foregroundStyle(projection.state.color)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          Text(projection.title).font(.caption.weight(.medium))
          if let updatedAt = projection.updatedAt {
            Text("· \(updatedAt.formatted(date: .omitted, time: .shortened))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Text(projection.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 4)
      if projection.state == .stale || projection.state == .coreError {
        Button("重试", action: retry)
          .buttonStyle(.borderless)
          .font(.caption.weight(.medium))
          .accessibilityLabel("重试检查")
      }
    }
    .padding(9)
    .background(projection.state.tint, in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .combine)
  }
}

private struct MenuServiceRow: View {
  let service: ServiceSnapshot

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: service.health.icon)
        .foregroundStyle(service.health.color)
        .imageScale(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text(service.name)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(service.message ?? serviceStatusDetail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let latency = service.latencyMs {
        Text("\(Int(latency)) ms")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(service.name)，\(service.health.title)，\(serviceStatusDetail)")
  }

  private var serviceStatusDetail: String {
    if service.observation.freshness != .fresh {
      return service.observation.freshness.title
    }
    if service.lifecycle == .stopped { return "离线" }
    return service.health.title
  }
}

struct DashboardView: View {
  @ObservedObject var model: LocalOpsAppModel
  @State private var section: DashboardSection = .overview

  var body: some View {
    NavigationSplitView {
      List(selection: $section) {
        Section("LocalOps") {
          Label("总览", systemImage: "checkmark.circle")
            .tag(DashboardSection.overview)
          Label("服务", systemImage: "server.rack")
            .badge(model.registeredServices.count)
            .tag(DashboardSection.services)
          Label("历史", systemImage: "clock.arrow.circlepath")
            .badge(model.historyServices.count)
            .tag(DashboardSection.history)
        }
        Section("应用") {
          Label("设置", systemImage: "gearshape")
            .tag(DashboardSection.settings)
        }
      }
      .listStyle(.sidebar)
      .navigationTitle("LocalOps")
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.projection.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(model.projection.state.color)
          if let updatedAt = model.projection.updatedAt {
            Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
    } detail: {
      Group {
        switch section {
        case .overview: OverviewPage(model: model)
        case .services: ServicesPage(model: model)
        case .history: HistoryPage(model: model)
        case .settings: SettingsPage(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          Task { await model.refresh() }
        } label: {
          Label("立即检查", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
      }
    }
    .frame(minWidth: 780, minHeight: 540)
  }
}

private enum DashboardSection: Hashable {
  case overview
  case services
  case history
  case settings
}

private struct OverviewPage: View {
  @ObservedObject var model: LocalOpsAppModel
  @State private var showMachineDetails = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PageHeader(
          title: "总览",
          subtitle: "一眼查看本机服务目录；LocalOps 不会控制、启动或停止已登记服务。",
          projection: model.projection
        )
        SnapshotBanner(projection: model.projection) {
          Task { await model.refresh() }
        }

        HStack(spacing: 10) {
          SummaryValue(title: "健康", value: "\(model.overview.summary.healthy)", color: .green)
          SummaryValue(
            title: "需关注",
            value: "\(model.overview.summary.attention)",
            color: model.overview.summary.attention > 0 ? .orange : .secondary
          )
          SummaryValue(title: "待登记", value: "\(model.overview.summary.discovered)", color: .blue)
          SummaryValue(
            title: "历史", value: "\(model.overview.summary.offlineHistory)", color: .secondary)
        }

        if model.overview.services.isEmpty && model.projection.state != .starting {
          EmptyState(
            title: "目录为空",
            detail: "LocalOps 会发现本机监听端口；发现项可在“服务”中登记。",
            icon: "tray"
          )
        } else {
          VStack(alignment: .leading, spacing: 10) {
            Text("需要留意").font(.title3.weight(.semibold))
            if model.priorityServices.isEmpty {
              Label("当前没有异常或新的状态变化。", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
              ForEach(model.priorityServices.prefix(8)) { service in
                ServiceListRow(service: service)
              }
            }
          }
        }

        DisclosureGroup("本机信息", isExpanded: $showMachineDetails) {
          MachineDetails(model: model)
            .padding(.top, 8)
        }
        .font(.headline)
      }
      .padding(24)
    }
  }
}

private struct PageHeader: View {
  let title: String
  let subtitle: String
  let projection: LocalOpsMetadataProjection

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.weight(.semibold))
        Text(subtitle).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let updatedAt = projection.updatedAt {
        Text("更新于 \(updatedAt.formatted(date: .omitted, time: .standard))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct SummaryValue: View {
  let title: String
  let value: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value)
        .font(.title2.monospacedDigit().weight(.semibold))
        .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct MachineDetails: View {
  @ObservedObject var model: LocalOpsAppModel

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
      GridRow {
        Label("内存", systemImage: "memorychip")
        Text(memoryText)
      }
      GridRow {
        Label("磁盘可用", systemImage: "internaldrive")
        Text(diskText)
      }
      GridRow {
        Label("CPU 负载", systemImage: "cpu")
        Text(loadText)
      }
      GridRow {
        Label("热状态", systemImage: "thermometer")
        Text(model.overview.system.thermalState.title)
          .foregroundStyle(model.overview.system.thermalState.color)
      }
      GridRow {
        Label("开机时长", systemImage: "clock.arrow.circlepath")
        Text(uptimeText)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  private var memoryText: String {
    guard model.overview.system.memoryTotalGb > 0 else { return "—" }
    return
      "\(model.overview.system.memoryUsedGb.formatted()) / \(model.overview.system.memoryTotalGb.formatted()) GB"
  }

  private var diskText: String {
    guard model.overview.system.diskTotalGb > 0 else { return "—" }
    return
      "\(model.overview.system.diskFreeGb.formatted()) / \(model.overview.system.diskTotalGb.formatted()) GB"
  }

  private var loadText: String {
    let system = model.overview.system
    guard system.logicalProcessorCount > 0 else { return "—" }
    return "\(String(format: "%.2f", system.cpuLoadOneMinute)) / \(system.logicalProcessorCount) 核"
  }

  private var uptimeText: String {
    let totalMinutes = model.overview.system.uptimeSeconds / 60
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return "\(days) 天 \(hours) 小时" }
    if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
    return "\(minutes) 分钟"
  }
}

private struct ServicesPage: View {
  @ObservedObject var model: LocalOpsAppModel
  @State private var selectedID: String?
  @State private var query = ""
  @State private var filter: ServiceDirectoryFilter = .all

  private var services: [ServiceSnapshot] {
    model.directoryServices.filter { service in
      let filterMatches: Bool
      switch filter {
      case .all: filterMatches = true
      case .registered: filterMatches = service.source == .registered
      case .discovered: filterMatches = service.source == .discovered
      case .history: filterMatches = service.source == .history
      }
      let searchMatches =
        query.isEmpty
        || "\(service.name) \(service.group) \(service.description) \(service.endpoints.map(\.url).joined())"
          .localizedCaseInsensitiveContains(query)
      return filterMatches && searchMatches
    }
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        Picker("范围", selection: $filter) {
          ForEach(ServiceDirectoryFilter.allCases, id: \.self) { item in
            Text(item.title).tag(item)
          }
        }
        .pickerStyle(.segmented)
        .padding(10)
        List(services, selection: $selectedID) { service in
          ServiceListRow(service: service)
            .tag(service.id)
        }
        .searchable(text: $query, prompt: "搜索名称、分组或端口")
      }
      .navigationSplitViewColumnWidth(min: 280, ideal: 330)
    } detail: {
      if let selectedID, let service = services.first(where: { $0.id == selectedID }) {
        ServiceDetailView(model: model, service: service)
      } else if services.isEmpty {
        EmptyState(
          title: "没有匹配的服务",
          detail: "尝试清除搜索或切换目录范围。",
          icon: "magnifyingglass"
        )
      } else {
        EmptyState(
          title: "选择一个服务",
          detail: "在左侧列表中查看健康状态和入口。",
          icon: "server.rack"
        )
      }
    }
    .onAppear { reconcileSelection() }
    .onChange(of: filter) { _ in reconcileSelection() }
    .onChange(of: query) { _ in reconcileSelection() }
    .onChange(of: model.directoryServices.map(\.id)) { _ in reconcileSelection() }
  }

  private func reconcileSelection() {
    guard let selectedID, services.contains(where: { $0.id == selectedID }) else {
      selectedID = services.first?.id
      return
    }
  }
}

private enum ServiceDirectoryFilter: CaseIterable, Hashable {
  case all
  case registered
  case discovered
  case history

  var title: String {
    switch self {
    case .all: "全部"
    case .registered: "已登记"
    case .discovered: "待登记"
    case .history: "历史"
    }
  }
}

private struct ServiceListRow: View {
  let service: ServiceSnapshot

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: service.health.icon)
        .foregroundStyle(service.health.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(service.name).lineLimit(1)
        Text(
          service.checksDisabled
            ? "\(service.group) · 检查已停用"
            : "\(service.group) · \(service.source.title)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let port = service.endpoints.first?.port {
        // Ports are identifiers, not quantities: never apply locale grouping
        // (for example, `:8,000`).
        Text(":\(String(port))")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      service.checksDisabled
        ? "\(service.name)，检查已停用"
        : "\(service.name)，\(service.health.title)，\(service.source.title)"
    )
  }
}

private struct ServiceDetailView: View {
  @ObservedObject var model: LocalOpsAppModel
  let service: ServiceSnapshot
  @State private var showRegistration = false
  @State private var showEditor = false
  @State private var definition: ServiceDefinition?
  @State private var operationError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 5) {
            Text(service.name).font(.largeTitle.weight(.semibold))
            Text(service.description)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          StatusBadge(service: service)
        }

        SnapshotBanner(projection: detailProjection) {
          Task { await model.refresh() }
        }

        if let message = service.message {
          Label(
            message,
            systemImage: service.lifecycle == .stopped
              ? "exclamationmark.triangle" : "info.circle"
          )
          .foregroundStyle(service.health == .unhealthy ? .orange : .secondary)
          .textSelection(.enabled)
        }

        DetailSection(title: "入口", systemImage: "link") {
          if service.endpoints.isEmpty {
            Text("尚未配置服务入口。").foregroundStyle(.secondary)
          } else {
            ForEach(service.endpoints, id: \.self) { endpoint in
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(endpoint.name).font(.caption).foregroundStyle(.secondary)
                  Text(endpoint.url)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                }
                Spacer()
                Button("打开") { model.openEndpoint(endpoint) }
                  .buttonStyle(.bordered)
              }
            }
          }
        }

        DetailSection(title: "状态", systemImage: "waveform.path.ecg") {
          Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
            DetailGridRow(label: "健康", value: service.health.title)
            DetailGridRow(label: "生命周期", value: service.lifecycle.title)
            DetailGridRow(label: "观察", value: service.observation.state.title)
            DetailGridRow(label: "新鲜度", value: service.observation.freshness.title)
            DetailGridRow(
              label: "归属置信度",
              value: service.observation.matchConfidence.title
            )
            DetailGridRow(label: "延迟", value: service.latencyMs.map { "\($0) ms" } ?? "—")
            DetailGridRow(label: "上次检查", value: formatted(service.checkedAt))
            DetailGridRow(label: "最后在线", value: formatted(service.lastSeenAt))
            DetailGridRow(label: "PID", value: service.pid.map(String.init) ?? "—")
          }
          .textSelection(.enabled)
        }

        DetailSection(title: "检查规则", systemImage: "checkmark.shield") {
          VStack(alignment: .leading, spacing: 6) {
            if let definition {
              Text("当前：\(healthTypeTitle(definition.health.type))")
              Text("管理方式：\(definition.managementKind.title)")
              if let url = definition.health.url ?? definition.endpoints.first?.url {
                Text(url).font(.caption.monospaced()).foregroundStyle(.secondary)
              }
              if !definition.recoveryNote.isEmpty {
                Text(definition.recoveryNote)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else {
              Text("正在读取目录配置…").foregroundStyle(.secondary)
            }
            Text("这些字段只修改 LocalOps 目录；LocalOps 不会控制、启动或停止已登记服务。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 10) {
          Button {
            Task { await model.refresh() }
          } label: {
            Label("重新检查", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.borderedProminent)
          if service.source == .discovered {
            Button("登记为服务") { showRegistration = true }
          } else if service.source == .history {
            Button("登记为服务") { showRegistration = true }
            Button("忘记记录", role: .destructive) {
              Task {
                do {
                  try await model.forgetObserved(id: service.id)
                } catch {
                  operationError = error.localizedDescription
                }
              }
            }
          } else if service.source == .registered, definition != nil {
            Button("编辑目录") { showEditor = true }
          }
          Spacer()
          if service.source == .registered {
            Toggle(
              "静音提醒",
              isOn: Binding(
                get: { model.isMuted(service.id) },
                set: { _ in model.toggleMute(for: service.id) }
              )
            )
            .toggleStyle(.checkbox)
            .help("只影响 LocalOps 通知，不影响健康检查")
          }
        }
      }
      .padding(24)
    }
    .sheet(isPresented: $showRegistration) {
      RegistrationSheet(model: model, service: service, isPresented: $showRegistration)
    }
    .sheet(isPresented: $showEditor) {
      if let definition {
        DefinitionEditorSheet(
          model: model,
          definition: definition,
          isPresented: $showEditor
        )
      }
    }
    .task(id: "\(service.id)-\(model.catalogRevision)") {
      guard service.source == .registered else {
        definition = nil
        return
      }
      if let catalogDefinition = model.catalogDefinition(id: service.id) {
        definition = catalogDefinition
      } else {
        definition = try? await model.definition(id: service.id)
      }
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { operationError != nil },
        set: { if !$0 { operationError = nil } }
      )
    ) {
      Button("好") { operationError = nil }
    } message: {
      Text(operationError ?? "")
    }
  }

  private var detailProjection: LocalOpsMetadataProjection {
    model.projection
  }

  private func healthTypeTitle(_ type: HealthCheckType) -> String {
    switch type {
    case .http: "HTTP"
    case .tcp: "TCP"
    case .process: "进程"
    case .none: "未配置"
    }
  }

  private func formatted(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
  }
}

private struct StatusBadge: View {
  let service: ServiceSnapshot

  var body: some View {
    Label(service.health.title, systemImage: service.health.icon)
      .font(.caption.weight(.medium))
      .foregroundStyle(service.health.color)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(service.health.color.opacity(0.12), in: Capsule())
      .accessibilityElement(children: .combine)
  }
}

private struct DetailSection<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct DetailGridRow: View {
  let label: String
  let value: String

  var body: some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value)
        .gridColumnAlignment(.leading)
    }
  }
}

private struct RegistrationSheet: View {
  @ObservedObject var model: LocalOpsAppModel
  let service: ServiceSnapshot
  @Binding var isPresented: Bool
  @State private var name: String
  @State private var group = "其他"
  @State private var saving = false
  @State private var error: String?

  init(model: LocalOpsAppModel, service: ServiceSnapshot, isPresented: Binding<Bool>) {
    self.model = model
    self.service = service
    self._isPresented = isPresented
    self._name = State(initialValue: service.processName ?? service.name)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("登记本地服务").font(.title2.weight(.semibold))
      Text("登记只保存 LocalOps 的目录元数据；LocalOps 不会控制、启动或停止已登记服务。")
        .foregroundStyle(.secondary)
      Form {
        TextField("名称", text: $name)
        TextField("分组", text: $group)
        LabeledContent("入口", value: service.endpoints.first?.url ?? "—")
        LabeledContent("检查方式", value: "TCP（当前 Core 默认）")
      }
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { isPresented = false }
        Button("登记") {
          saving = true
          Task {
            do {
              try await model.registerObserved(id: service.id, name: name, group: group)
              isPresented = false
            } catch {
              self.error = error.localizedDescription
            }
            saving = false
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving
        )
      }
    }
    .padding(24)
    .frame(width: 470)
  }
}

private struct DefinitionEditorSheet: View {
  @ObservedObject var model: LocalOpsAppModel
  let definition: ServiceDefinition
  @Binding var isPresented: Bool
  @State private var draft: ServiceDefinition
  @State private var healthType: HealthCheckType
  @State private var healthURL: String
  @State private var healthHost: String
  @State private var healthPort: String
  @State private var healthPID: String
  @State private var timeout: Double
  @State private var saving = false
  @State private var error: String?

  init(
    model: LocalOpsAppModel,
    definition: ServiceDefinition,
    isPresented: Binding<Bool>
  ) {
    self.model = model
    self.definition = definition
    self._isPresented = isPresented
    self._draft = State(initialValue: definition)
    self._healthType = State(initialValue: definition.health.type)
    self._healthURL = State(initialValue: definition.health.url ?? "")
    self._healthHost = State(initialValue: definition.health.host)
    self._healthPort = State(initialValue: definition.health.port.map(String.init) ?? "")
    self._healthPID = State(initialValue: definition.health.pid.map(String.init) ?? "")
    self._timeout = State(initialValue: min(30, max(1, definition.health.timeoutSeconds)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("编辑目录").font(.title2.weight(.semibold))
      Text("这里只保存服务定义、检查方式和恢复说明；LocalOps 不会控制、启动或停止已登记服务。")
        .font(.callout)
        .foregroundStyle(.secondary)
      Form {
        Section("基本信息") {
          TextField("名称", text: $draft.name)
          TextField("分组", text: $draft.group)
          TextField("描述", text: $draft.description, axis: .vertical)
            .lineLimit(2...4)
          Toggle("启用检查", isOn: $draft.enabled)
        }

        Section("服务入口") {
          if draft.endpoints.isEmpty {
            Text("尚未配置服务入口；可添加入口，或保存为空目录。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          ForEach(Array(draft.endpoints.indices), id: \.self) { index in
            VStack(alignment: .leading, spacing: 6) {
              TextField(
                "入口名称",
                text: Binding(
                  get: { draft.endpoints[index].name },
                  set: { draft.endpoints[index].name = $0 }
                )
              )
              HStack {
                TextField(
                  "URL",
                  text: Binding(
                    get: { draft.endpoints[index].url },
                    set: { draft.endpoints[index].url = $0 }
                  )
                )
                Button(role: .destructive) {
                  draft.endpoints.remove(at: index)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
              }
            }
          }
          Button("添加入口", systemImage: "plus") {
            draft.endpoints.append(
              ServiceEndpoint(name: "服务入口", url: "http://127.0.0.1:8080/")
            )
          }
        }

        Section("健康检查") {
          Picker("方式", selection: $healthType) {
            Text("HTTP").tag(HealthCheckType.http)
            Text("TCP").tag(HealthCheckType.tcp)
            Text("进程").tag(HealthCheckType.process)
            Text("不检查").tag(HealthCheckType.none)
          }
          switch healthType {
          case .http:
            TextField("HTTP 健康地址", text: $healthURL)
          case .tcp:
            TextField("主机", text: $healthHost)
            TextField("端口", text: $healthPort)
          case .process:
            TextField("PID", text: $healthPID)
          case .none:
            Text("未配置健康检查，状态会显示为未检查。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Stepper(
            "超时 \(timeout.formatted(.number.precision(.fractionLength(0)))) 秒",
            value: $timeout,
            in: 1...30,
            step: 1
          )
        }

        Section("管理与恢复说明") {
          Picker("管理方式", selection: $draft.managementKind) {
            ForEach(ServiceManagementKind.allCases, id: \.self) { kind in
              Text(kind.title).tag(kind)
            }
          }
          TextEditor(text: $draft.recoveryNote)
            .frame(minHeight: 70)
          Text("恢复说明仅供查看，不会被 LocalOps 执行。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("提醒") {
          Toggle("静音此服务的离线/恢复通知", isOn: $draft.notificationsMuted)
        }
      }
      if let error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button("取消") { isPresented = false }
        Button("保存") { save() }
          .buttonStyle(.borderedProminent)
          .disabled(saving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 500, idealWidth: 560, minHeight: 450, idealHeight: 650)
  }

  private func save() {
    var value = draft
    value.health = ServiceHealthCheck(
      type: healthType,
      url: healthURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : healthURL.trimmingCharacters(in: .whitespacesAndNewlines),
      host: healthHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "127.0.0.1" : healthHost.trimmingCharacters(in: .whitespacesAndNewlines),
      port: Int(healthPort.trimmingCharacters(in: .whitespacesAndNewlines)),
      pid: Int(healthPID.trimmingCharacters(in: .whitespacesAndNewlines)),
      timeoutSeconds: timeout
    )
    saving = true
    Task {
      do {
        try await model.updateRegisteredDefinition(value)
        isPresented = false
      } catch {
        self.error = error.localizedDescription
      }
      saving = false
    }
  }
}

private struct HistoryPage: View {
  @ObservedObject var model: LocalOpsAppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        title: "历史",
        subtitle: "查看状态变化和最近掉线的目录记录。",
        projection: model.projection
      )
      SnapshotBanner(projection: model.projection) {
        Task { await model.refresh() }
      }
      if model.overview.events.isEmpty && model.historyServices.isEmpty {
        EmptyState(
          title: "还没有历史事件",
          detail: "登记服务状态变化后会出现在这里。",
          icon: "clock.arrow.circlepath"
        )
      } else {
        List {
          if !model.historyServices.isEmpty {
            Section("最近掉线") {
              ForEach(model.historyServices) { service in
                ServiceListRow(service: service)
              }
            }
          }
          Section("状态变化") {
            ForEach(model.overview.events) { event in
              EventRow(event: event)
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .padding(24)
  }
}

private struct EventRow: View {
  let event: LocalOpsEvent

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(
        systemName: event.severity == "error"
          ? "exclamationmark.circle.fill" : "clock.arrow.circlepath"
      )
      .foregroundStyle(event.severity == "error" ? .red : .secondary)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(event.serviceName).font(.callout.weight(.medium))
          Text(eventKindTitle(event.kind)).font(.caption).foregroundStyle(.secondary)
        }
        Text(event.message)
        Text(event.occurredAt.formatted())
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(event.serviceName)，\(eventKindTitle(event.kind))，\(event.message)，\(event.occurredAt.formatted())"
    )
    .accessibilityHint("原始事件类型：\(event.kind)")
  }
}

private func eventKindTitle(_ kind: String) -> String {
  switch kind {
  case "stopped": "已停止"
  case "health_changed": "健康状态变化"
  case "discovered": "首次发现"
  case "recovered": "已恢复"
  case "state_changed": "状态变化"
  default: "状态变化"
  }
}

private struct SettingsPage: View {
  @ObservedObject var model: LocalOpsAppModel
  @State private var showClearConfirmation = false

  var body: some View {
    Form {
      Section("检查") {
        Picker("自动检查间隔", selection: $model.pollInterval) {
          Text("15 秒").tag(15.0)
          Text("30 秒").tag(30.0)
          Text("60 秒").tag(60.0)
          Text("120 秒").tag(120.0)
          Text("300 秒").tag(300.0)
        }
        Text("允许范围为 15–300 秒；所有结果都来自本机只读检查。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("提醒") {
        Toggle(
          "服务连续离线后发送通知",
          isOn: Binding(
            get: { model.notificationsEnabled },
            set: { model.notificationsEnabled = $0 }
          ))
        Text(
          model.notificationsAuthorized
            ? "通知默认关闭；开启后只对连续确认的离线/恢复各提醒一次。"
            : "首次开启会请求 macOS 通知权限。可在系统设置中随时撤销。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("只读 Web") {
        LabeledContent("状态", value: webStateText)
        if let url = model.webURL {
          LabeledContent("地址", value: url.absoluteString)
          HStack {
            Button("打开页面") { model.openWebPage() }
            Button("复制地址") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
          }
        } else {
          if case .failed(let error) = model.webState {
            Button("重试 Web") { Task { await model.retryWebServer() } }
            Text("固定监听地址为 127.0.0.1:8042。关闭占用端口的程序后重试。\n\(error)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          } else {
            Text("Web 仅在目录初始化成功后启动，并只监听 127.0.0.1。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Section("应用") {
        LabeledContent("版本", value: model.bundleVersion)
        Toggle(
          "登录后自动启动 LocalOps",
          isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
          )
        )
        Button("在 Finder 中显示数据库") { model.openDataDirectory() }
        Button("导出脱敏诊断") { model.exportDiagnostics() }
        Button("查看发布页") { model.openReleasePage() }
        Text("发布页：github.com/mincer0/localops/releases")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("数据") {
        Text(
          "清除当前目录、服务状态和历史记录，并重新写入内置服务。旧版 YAML/SQLite 迁移来源会保留，便于回滚。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button("清除当前目录数据", role: .destructive) {
          showClearConfirmation = true
        }
        .disabled(model.isClearingData || model.isRefreshing || !model.isCoreReady)
        if model.isClearingData {
          ProgressView("正在清除并重新检查…")
            .controlSize(.small)
        }
        if let clearMessage = model.dataClearMessage {
          Text(clearMessage)
            .font(.caption)
            .foregroundStyle(
              clearMessage.contains("失败") || clearMessage.contains("未成功")
                ? .orange : .secondary
            )
            .textSelection(.enabled)
        }
      }
      Section("当前边界") {
        Text(
          "v1 只发现、登记、检查和记录本地服务。"
            + "LocalOps 不会控制、启动或停止已登记服务，"
            + "也不执行服务 CLI、launchd、容器或任意 shell 命令。"
        )
        .foregroundStyle(.secondary)
        Text("LocalOps 不会自动卸载或删除旧 LaunchAgent；如检测到历史安装，请按安装/迁移说明自行确认处理。")
          .foregroundStyle(.secondary)
      }
      if let message = model.message {
        Section("诊断") {
          Text(message)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Button("立即重试") { Task { await model.refresh() } }
        }
      }
    }
    .formStyle(.grouped)
    .padding(20)
    .frame(maxWidth: 680)
    .confirmationDialog(
      "清除 LocalOps 当前目录数据？",
      isPresented: $showClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("清除并重新检查", role: .destructive) {
        Task { await model.clearCurrentDirectoryData() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "这会删除当前服务目录、状态和历史事件，并重新写入内置服务。旧版 YAML/SQLite 迁移来源会保留。"
      )
    }
  }

  private var webStateText: String {
    switch model.webState {
    case .stopped: "已停止"
    case .starting: "启动中"
    case .running: "运行中"
    case .failed(let message): "不可用：\(message)"
    }
  }
}

private struct EmptyState: View {
  let title: String
  let detail: String
  let icon: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text(title).font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
    .accessibilityElement(children: .combine)
  }
}

extension LocalOpsSnapshotState {
  fileprivate var icon: String {
    switch self {
    case .starting: "hourglass"
    case .empty, .fresh: "checkmark.circle"
    case .partial: "questionmark.circle"
    case .stale: "clock.badge.exclamationmark"
    case .coreError: "exclamationmark.triangle"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .starting: .secondary
    case .empty, .fresh: .green
    case .partial: .orange
    case .stale: .orange
    case .coreError: .red
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .starting: Color.secondary.opacity(0.12)
    case .empty, .fresh: .green.opacity(0.08)
    case .partial, .stale: .orange.opacity(0.10)
    case .coreError: .red.opacity(0.10)
    }
  }
}

extension ServiceHealth {
  fileprivate var color: Color {
    switch self {
    case .healthy: .green
    case .degraded: .orange
    case .unhealthy: .red
    case .unknown: .secondary
    }
  }
}

extension ServiceLifecycle {
  fileprivate var title: String {
    switch self {
    case .unknown: "未知"
    case .stopped: "已停止"
    case .running: "运行中"
    }
  }
}

extension ObservationMatchConfidence {
  fileprivate var title: String {
    switch self {
    case .none: "未确认"
    case .ambiguous: "有歧义"
    case .portOnly: "仅端口"
    case .hostPort: "主机与端口"
    case .processFingerprint: "进程指纹"
    }
  }
}

extension ServiceManagementKind {
  static var allCases: [ServiceManagementKind] {
    [.unknown, .app, .cli, .launchd, .container, .manual]
  }

  fileprivate var title: String {
    switch self {
    case .unknown: "未指定"
    case .app: "macOS 应用"
    case .cli: "官方 CLI"
    case .launchd: "launchd"
    case .container: "容器"
    case .manual: "手动"
    }
  }
}

extension ServiceSnapshot {
  fileprivate var checksDisabled: Bool {
    message == "检查已停用"
  }

  fileprivate var healthCheckType: HealthCheckType {
    if endpoints.first?.url.lowercased().hasPrefix("http") == true {
      return .http
    }
    if lifecycle == .running || lifecycle == .stopped {
      return .tcp
    }
    return .none
  }
}

extension LocalOpsThermalState {
  fileprivate var color: Color {
    switch self {
    case .nominal: .green
    case .fair: .orange
    case .serious, .critical: .red
    case .unknown: .secondary
    }
  }
}
