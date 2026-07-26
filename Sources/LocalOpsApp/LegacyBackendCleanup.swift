import Darwin
import Foundation

enum LegacyBackendCleanup {
  private static let labels = [
    "io.github.mincer0.localops.backend",
    "io.github.mincer0.local-service-cockpit.backend",
  ]

  static func run(fileManager: FileManager = .default) {
    let agents = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    for label in labels {
      let plist = agents.appendingPathComponent("\(label).plist")
      guard fileManager.fileExists(atPath: plist.path), belongsToLegacyLocalOps(plist) else {
        continue
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try? process.run()
      process.waitUntilExit()
      try? fileManager.removeItem(at: plist)
    }
  }

  private static func belongsToLegacyLocalOps(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let object = plist as? [String: Any]
    else { return false }
    let program = object["Program"] as? String
    let arguments = object["ProgramArguments"] as? [String]
    return program?.localizedCaseInsensitiveContains("localops") == true
      || arguments?.contains(where: {
        $0.localizedCaseInsensitiveContains("localops")
          || $0.localizedCaseInsensitiveContains("cockpit")
      }) == true
  }
}
