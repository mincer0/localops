import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
  init(model: LocalOpsAppModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "LocalOps"
    window.titlebarAppearsTransparent = true
    window.minSize = NSSize(width: 780, height: 540)
    window.isReleasedWhenClosed = false
    window.center()
    window.contentViewController = NSHostingController(rootView: DashboardView(model: model))
    super.init(window: window)
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show() {
    showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}
