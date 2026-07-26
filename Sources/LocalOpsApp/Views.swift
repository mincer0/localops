import AppKit
import LocalOpsCore
import LocalOpsWeb
import SwiftUI

struct MenuPopoverView: View {
  @ObservedObject var model: LocalOpsAppModel
  let openDashboard: () -> Void
  let quit: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("LocalOps").font(.title2.bold())
          Text(summaryText).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if model.isRefreshing { ProgressView().controlSize(.small) }
        Button {
          Task { await model.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(model.isRefreshing)
        .help("立即扫描")
      }
      .padding(16)

      Divider()
      summary
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      Divider()

      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(model.overview.services.filter { $0.source == .registered }.prefix(7)) {
            service in
            MenuServiceRow(service: service)
          }
          if model.overview.services.isEmpty {
            VStack(spacing: 8) {
              ProgressView()
              Text("正在检查本地服务…")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
          }
        }
        .padding(12)
      }

      Divider()
      VStack(spacing: 8) {
        Button(action: openDashboard) {
          Label("打开管理窗口", systemImage: "rectangle.3.group")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        HStack {
          Button {
            model.openWebPage()
          } label: {
            Label("只读 Web", systemImage: "safari")
          }
          .disabled(model.webURL == nil)
          Spacer()
          Button("退出", action: quit)
        }
      }
      .padding(12)
    }
    .frame(width: 390, height: 590)
  }

  private var summaryText: String {
    guard model.overview.refreshedAt != nil else { return "正在初始化" }
    return
      "\(model.overview.summary.healthy)/\(model.overview.summary.total) 健康 · \(model.overview.summary.discovered) 待登记"
  }

  private var summary: some View {
    HStack(spacing: 10) {
      MetricChip(value: "\(model.overview.summary.healthy)", label: "健康", color: .green)
      MetricChip(value: "\(model.overview.summary.attention)", label: "异常", color: .orange)
      MetricChip(
        value: model.overview.system.memoryTotalGb > 0
          ? "\(Int(model.overview.system.memoryPercent))%"
          : "—",
        label: "内存",
        color: .blue
      )
      MetricChip(
        value: model.overview.system.thermalState.title,
        label: "温控",
        color: model.overview.system.thermalState.color
      )
    }
  }
}

private struct MetricChip: View {
  let value: String
  let label: String
  let color: Color

  var body: some View {
    VStack(spacing: 2) {
      Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct MenuServiceRow: View {
  let service: ServiceSnapshot

  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(service.health.color).frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 2) {
        Text(service.name).font(.callout.weight(.medium)).lineLimit(1)
        Text(service.message ?? service.endpoints.first?.url ?? service.group)
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if let latency = service.latencyMs {
        Text("\(Int(latency)) ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct DashboardView: View {
  @ObservedObject var model: LocalOpsAppModel

  var body: some View {
    TabView {
      OverviewPage(model: model)
        .tabItem { Label("总览", systemImage: "square.grid.2x2") }
      ServicesPage(model: model)
        .tabItem { Label("服务", systemImage: "server.rack") }
      EventsPage(model: model)
        .tabItem { Label("事件", systemImage: "clock.arrow.circlepath") }
      SettingsPage(model: model)
        .tabItem { Label("设置", systemImage: "gearshape") }
    }
    .toolbar {
      ToolbarItem {
        Button {
          Task { await model.refresh() }
        } label: {
          Label("立即扫描", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
      }
    }
  }
}

private struct OverviewPage: View {
  @ObservedObject var model: LocalOpsAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading) {
            Text("本地服务").font(.largeTitle.bold())
            Text("原生界面负责管理，Web 页面只读展示。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          if let date = model.overview.refreshedAt {
            Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 12) {
          DashboardMetric(title: "已登记", value: "\(model.overview.summary.total)", color: .primary)
          DashboardMetric(title: "健康", value: "\(model.overview.summary.healthy)", color: .green)
          DashboardMetric(
            title: "需关注", value: "\(model.overview.summary.attention)", color: .orange)
          DashboardMetric(title: "待登记", value: "\(model.overview.summary.discovered)", color: .blue)
        }

        GroupBox("这台 Mac") {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)],
            alignment: .leading,
            spacing: 14
          ) {
            Label(
              "内存 \(model.overview.system.memoryUsedGb.formatted()) / \(model.overview.system.memoryTotalGb.formatted()) GB",
              systemImage: "memorychip"
            )
            Label(
              "磁盘 \(model.overview.system.diskFreeGb.formatted()) / \(model.overview.system.diskTotalGb.formatted()) GB 可用",
              systemImage: "internaldrive"
            )
            Label(
              "CPU Load \(loadAverageText) · \(model.overview.system.logicalProcessorCount) 核",
              systemImage: "cpu"
            )
            Label(
              "热状态 \(model.overview.system.thermalState.title)",
              systemImage: "thermometer"
            )
            .foregroundStyle(model.overview.system.thermalState.color)
            Label("已运行 \(uptimeText)", systemImage: "clock.arrow.circlepath")
            webStatus
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
        }

        Text("已登记服务").font(.title2.bold())
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
          ForEach(model.overview.services.filter { $0.source == .registered }) { service in
            ServiceCard(service: service)
          }
        }
      }
      .padding(28)
    }
  }

  private var loadAverageText: String {
    let system = model.overview.system
    return [system.cpuLoadOneMinute, system.cpuLoadFiveMinutes, system.cpuLoadFifteenMinutes]
      .map { String(format: "%.2f", $0) }
      .joined(separator: " / ")
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

  @ViewBuilder private var webStatus: some View {
    switch model.webState {
    case .running(let url): Label("Web \(url.absoluteString)", systemImage: "checkmark.circle")
    case .starting: Label("Web 正在启动", systemImage: "hourglass")
    case .failed: Label("Web 不可用", systemImage: "exclamationmark.triangle")
    case .stopped: Label("Web 已停止", systemImage: "stop.circle")
    }
  }
}

private struct DashboardMetric: View {
  let title: String
  let value: String
  let color: Color
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
  }
}

private struct ServiceCard: View {
  let service: ServiceSnapshot
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Circle().fill(service.health.color).frame(width: 10, height: 10)
        Text(service.name).font(.headline)
        Spacer()
        Text(service.health.title).font(.caption).foregroundStyle(service.health.color)
      }
      Text(service.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      HStack {
        Text(service.group)
        if let latency = service.latencyMs { Text("\(Int(latency)) ms") }
        if let pid = service.pid { Text("PID \(pid)") }
      }
      .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
  }
}

private struct ServicesPage: View {
  @ObservedObject var model: LocalOpsAppModel
  @State private var selectedID: String?
  @State private var query = ""
  @State private var source: ServiceSource?

  private var services: [ServiceSnapshot] {
    model.overview.services.filter { service in
      (source == nil || service.source == source)
        && (query.isEmpty
          || "\(service.name) \(service.group) \(service.description) \(service.endpoints.map(\.url).joined())"
            .localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        Picker("来源", selection: $source) {
          Text("全部").tag(ServiceSource?.none)
          Text("已登记").tag(ServiceSource?.some(.registered))
          Text("待登记").tag(ServiceSource?.some(.discovered))
          Text("最近掉线").tag(ServiceSource?.some(.history))
        }
        .pickerStyle(.segmented)
        .padding(10)
        List(services, selection: $selectedID) { service in
          ServiceListRow(service: service).tag(service.id)
        }
        .searchable(text: $query, prompt: "搜索服务或端口")
      }
      .navigationSplitViewColumnWidth(min: 280, ideal: 330)
    } detail: {
      if let selectedID, let service = services.first(where: { $0.id == selectedID }) {
        ServiceDetailView(model: model, service: service)
      } else {
        VStack(spacing: 10) {
          Image(systemName: "server.rack").font(.system(size: 44)).foregroundStyle(.secondary)
          Text("选择一个服务查看详情").foregroundStyle(.secondary)
        }
      }
    }
    .onAppear { selectedID = selectedID ?? services.first?.id }
    .onChange(of: source) { _ in reconcileSelection() }
    .onChange(of: query) { _ in reconcileSelection() }
    .onChange(of: model.overview.services.map(\.id)) { _ in reconcileSelection() }
  }

  private func reconcileSelection() {
    guard let selectedID, services.contains(where: { $0.id == selectedID }) else {
      selectedID = services.first?.id
      return
    }
  }
}

private struct ServiceListRow: View {
  let service: ServiceSnapshot
  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(service.health.color).frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 2) {
        Text(service.name).lineLimit(1)
        Text("\(service.group) · \(service.source.title)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let port = service.endpoints.first?.parsedURL?.port {
        Text(":\(port)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct ServiceDetailView: View {
  @ObservedObject var model: LocalOpsAppModel
  let service: ServiceSnapshot
  @State private var showRegistration = false
  @State private var operationError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 6) {
            Text(service.name).font(.largeTitle.bold())
            Text(service.description).foregroundStyle(.secondary)
          }
          Spacer()
          Label(service.health.title, systemImage: service.health.icon)
            .foregroundStyle(service.health.color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(service.health.color.opacity(0.1), in: Capsule())
        }

        if let message = service.message {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }

        GroupBox("入口") {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(service.endpoints, id: \.self) { endpoint in
              HStack {
                VStack(alignment: .leading) {
                  Text(endpoint.name).font(.caption).foregroundStyle(.secondary)
                  Text(endpoint.url).font(.body.monospaced()).textSelection(.enabled)
                }
                Spacer()
                Button("打开") {
                  if let url = endpoint.parsedURL { NSWorkspace.shared.open(url) }
                }
              }
            }
          }.padding(6)
        }

        GroupBox("运行信息") {
          Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 10) {
            DetailRow(label: "来源", value: service.source.title)
            DetailRow(label: "生命周期", value: service.lifecycle.rawValue)
            DetailRow(label: "延迟", value: service.latencyMs.map { "\($0) ms" } ?? "—")
            DetailRow(label: "PID", value: service.pid.map(String.init) ?? "—")
            DetailRow(label: "进程", value: service.processName ?? "—")
            DetailRow(label: "内存", value: service.memoryMb.map { "\($0) MB" } ?? "—")
            DetailRow(label: "可执行文件", value: service.executablePath ?? "—")
            DetailRow(label: "工作目录", value: service.workingDirectory ?? "—")
          }
          .padding(6)
          .textSelection(.enabled)
        }

        if let response = service.responseSummary {
          GroupBox("健康响应") {
            ScrollView(.horizontal) {
              Text(response).font(.caption.monospaced()).textSelection(.enabled)
            }.padding(6)
          }
        }

        if service.source == .discovered {
          VStack(alignment: .leading, spacing: 8) {
            Button("登记为服务") { showRegistration = true }
              .buttonStyle(.borderedProminent)
            Label("在线监听项会持续被扫描发现；停止后可从“最近掉线”中忘记。", systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else if service.source == .history {
          HStack {
            Button("登记为服务") { showRegistration = true }
              .buttonStyle(.borderedProminent)
            Button("忘记记录", role: .destructive) {
              Task {
                do { try await model.forgetObserved(id: service.id) } catch {
                  operationError = error.localizedDescription
                }
              }
            }
          }
        } else {
          Label("启动、停止和重启方式将在后续版本接入。", systemImage: "info.circle")
            .foregroundStyle(.secondary)
        }
      }
      .padding(28)
    }
    .sheet(isPresented: $showRegistration) {
      RegistrationSheet(model: model, service: service, isPresented: $showRegistration)
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
}

private struct DetailRow: View {
  let label: String
  let value: String
  var body: some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value).gridColumnAlignment(.leading)
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
    VStack(alignment: .leading, spacing: 18) {
      Text("登记本地服务").font(.title2.bold())
      Text("登记后 LocalOps 会持续记住它的端口和健康状态，但仍不会获得启停权限。")
        .foregroundStyle(.secondary)
      Form {
        TextField("名称", text: $name)
        TextField("分组", text: $group)
        LabeledContent("端口", value: service.endpoints.first?.url ?? "—")
        LabeledContent("检查方式", value: "TCP")
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
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
      }
    }
    .padding(24)
    .frame(width: 470)
  }
}

private struct EventsPage: View {
  @ObservedObject var model: LocalOpsAppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("最近事件").font(.largeTitle.bold())
      Text("已登记服务的上线、掉线和健康变化。").foregroundStyle(.secondary)
      List(model.overview.events) { event in
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: event.severity == "error" ? "exclamationmark.circle.fill" : "clock")
            .foregroundStyle(event.severity == "error" ? .red : .secondary)
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(event.serviceName).bold()
              Text(event.kind).font(.caption).foregroundStyle(.secondary)
            }
            Text(event.message)
            Text(event.occurredAt.formatted()).font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.vertical, 5)
      }
    }
    .padding(28)
  }
}

private struct SettingsPage: View {
  @ObservedObject var model: LocalOpsAppModel
  var body: some View {
    Form {
      Section("刷新") {
        Picker("自动检查间隔", selection: $model.pollInterval) {
          Text("10 秒").tag(10.0)
          Text("15 秒").tag(15.0)
          Text("30 秒").tag(30.0)
          Text("60 秒").tag(60.0)
        }
      }
      Section("只读 Web 页面") {
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
        }
        Text("FlyingFox 随 LocalOps 启动，只监听 127.0.0.1，不提供控制接口。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("应用") {
        Toggle(
          "登录后自动启动 LocalOps",
          isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
          ))
        Button("在 Finder 中显示数据库") { model.openDataDirectory() }
      }
      Section("当前边界") {
        Text("本版只做发现、登记、健康检查和历史记录。服务的 CLI、launchd 或容器启停方式留到后续版本。")
          .foregroundStyle(.secondary)
      }
      if let message = model.message {
        Section { Text(message).foregroundStyle(.secondary) }
      }
    }
    .formStyle(.grouped)
    .padding(20)
  }

  private var webStateText: String {
    switch model.webState {
    case .stopped: "已停止"
    case .starting: "正在启动"
    case .running: "运行中"
    case .failed(let message): "失败：\(message)"
    }
  }
}

extension ServiceHealth {
  fileprivate var title: String {
    switch self {
    case .healthy: "健康"
    case .degraded: "需关注"
    case .unhealthy: "异常"
    case .unknown: "未检查"
    }
  }
  fileprivate var color: Color {
    switch self {
    case .healthy: .green
    case .degraded: .orange
    case .unhealthy: .red
    case .unknown: .secondary
    }
  }
  fileprivate var icon: String {
    switch self {
    case .healthy: "checkmark.circle.fill"
    case .degraded: "exclamationmark.triangle.fill"
    case .unhealthy: "xmark.circle.fill"
    case .unknown: "questionmark.circle"
    }
  }
}

extension ServiceSource {
  fileprivate var title: String {
    switch self {
    case .registered: "已登记"
    case .discovered: "待登记"
    case .history: "最近掉线"
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

  var color: Color {
    switch self {
    case .nominal: .green
    case .fair: .orange
    case .serious, .critical: .red
    case .unknown: .secondary
    }
  }

  var requiresAttention: Bool {
    switch self {
    case .fair, .serious, .critical: true
    case .nominal, .unknown: false
    }
  }
}
