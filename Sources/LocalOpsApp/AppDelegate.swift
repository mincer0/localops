import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private let model = LocalOpsAppModel()
  private let popover = NSPopover()
  private var statusItem: NSStatusItem!
  private var dashboardWindow: DashboardWindowController!
  private var cancellables = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ notification: Notification) {
    LegacyBackendCleanup.run()
    configureStatusItem()
    configurePopover()
    dashboardWindow = DashboardWindowController(model: model)

    model.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.updateStatusItem() }
      }
      .store(in: &cancellables)

    model.start()
    if !UserDefaults.standard.bool(forKey: "didShowSwiftInitialPopover") {
      UserDefaults.standard.set(true, forKey: "didShowSwiftInitialPopover")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
        self?.showPopover()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.stop()
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

  private func updateStatusItem() {
    statusItem.button?.title = " \(model.statusItemText)"
    statusItem.button?.toolTip = model.statusItemToolTip
  }
}
