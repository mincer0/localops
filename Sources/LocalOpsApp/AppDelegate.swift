import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private var model: LocalOpsAppModel!
  private var instanceLock: LocalOpsInstanceLock?
  private let popover = NSPopover()
  private var statusItem: NSStatusItem!
  private var dashboardWindow: DashboardWindowController!
  private var cancellables = Set<AnyCancellable>()
  private var terminationRequested = false
  private var instanceLockFailure: String?
  private var activationObserverRegistered = false

  private static let activationNotificationName = Notification.Name(
    "io.github.mincer0.localops.activate-dashboard"
  )

  override init() {
    super.init()
    switch LocalOpsInstanceLock.acquireResult() {
    case .acquired(let lock):
      instanceLock = lock
    case .alreadyRunning:
      instanceLock = nil
    case .failed(let message):
      instanceLock = nil
      instanceLockFailure = message
    }
    model = LocalOpsAppModel()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard instanceLock != nil else {
      if let instanceLockFailure {
        showStartupFailure(
          title: "LocalOps 无法启动",
          message: "无法取得单实例锁。\n\n\(instanceLockFailure)"
        )
      } else if activateExistingInstanceIfNeeded() {
        showStartupFailure(
          title: "LocalOps 已在运行",
          message: "已有 LocalOps 实例正在运行，但当前实例无法激活它。"
        )
      }
      return
    }
    configureStatusItem()
    configurePopover()
    dashboardWindow = DashboardWindowController(model: model)
    registerActivationObserver()
    guard activateExistingInstanceIfNeeded() else { return }

    model.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.updateStatusItem() }
      }
      .store(in: &cancellables)

    // LocalOps remains observational after migration. It does not inspect,
    // unload, or delete legacy LaunchAgents automatically.
    model.start()
    if !UserDefaults.standard.bool(forKey: "didShowSwiftInitialPopover") {
      UserDefaults.standard.set(true, forKey: "didShowSwiftInitialPopover")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
        self?.showPopover()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // applicationShouldTerminate normally performs the awaited shutdown.
    // Keep this fallback for forced/older termination paths.
    Task { await model.stop() }
  }

  deinit {
    if activationObserverRegistered {
      DistributedNotificationCenter.default().removeObserver(self)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationRequested else { return .terminateNow }
    terminationRequested = true
    Task { [weak self] in
      guard let self else { return }
      await model.stop()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    dashboardWindow.show()
    return true
  }

  private func configureStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = statusItem.button else { return }
    let image = NSImage(
      systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "LocalOps")
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageLeading
    button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    button.setAccessibilityLabel(model.statusItemAccessibilityLabel)
    button.setAccessibilityRole(.button)
    button.target = self
    button.action = #selector(togglePopover)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    updateStatusItem()
  }

  private func configurePopover() {
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentSize = NSSize(width: 390, height: 590)
    popover.contentViewController = NSHostingController(
      rootView: MenuPopoverView(
        model: model,
        openDashboard: { [weak self] in self?.openDashboard() },
        quit: { NSApp.terminate(nil) }
      )
    )
  }

  @objc private func togglePopover() {
    popover.isShown ? popover.performClose(nil) : showPopover()
  }

  private func showPopover() {
    guard let button = statusItem.button else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    Task { await model.refresh() }
  }

  private func openDashboard() {
    popover.performClose(nil)
    dashboardWindow.show()
  }

  private func showStartupFailure(title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "退出")
    alert.runModal()
    NSApp.terminate(nil)
  }

  private func registerActivationObserver() {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleActivationNotification(_:)),
      name: Self.activationNotificationName,
      object: Bundle.main.bundleIdentifier
    )
    activationObserverRegistered = true
  }

  @objc private func handleActivationNotification(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      self?.dashboardWindow.show()
    }
  }

  private func updateStatusItem() {
    statusItem.button?.title = " \(model.statusItemText)"
    statusItem.button?.toolTip = model.statusItemToolTip
    statusItem.button?.setAccessibilityLabel(model.statusItemAccessibilityLabel)
    statusItem.button?.setAccessibilityValue(model.statusItemToolTip)
  }

  /// A menu-bar app can be launched repeatedly by Login Items, Finder, or a
  /// stale Dock click. Activate the existing process before creating a second
  /// web server or status item.
  private func activateExistingInstanceIfNeeded() -> Bool {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let existing = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).first { $0.processIdentifier != currentPID }
    guard let existing else { return true }
    DistributedNotificationCenter.default().post(
      name: Self.activationNotificationName,
      object: bundleIdentifier,
      userInfo: nil
    )
    existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    NSApp.terminate(nil)
    return false
  }
}
