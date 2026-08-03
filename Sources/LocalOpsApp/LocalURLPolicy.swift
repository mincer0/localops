import Foundation

/// The App re-checks every URL immediately before handing it to AppKit. Core
/// performs the same loopback policy for health probes, but snapshots can be
/// old or edited between observation and a user click.
enum LocalURLPolicy {
  struct Validation {
    let url: URL?
    let message: String?

    var isValid: Bool { url != nil }
  }

  static func validateServiceURL(_ url: URL?) -> Validation {
    validate(url, expectedWebPort: nil)
  }

  static func validateWebURL(_ url: URL?) -> Validation {
    validate(url, expectedWebPort: 8_042)
  }

  private static func validate(_ url: URL?, expectedWebPort: Int?) -> Validation {
    guard let url else {
      return Validation(url: nil, message: "无法打开：服务入口地址无效。")
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return Validation(url: nil, message: "无法打开：仅允许打开本机 HTTP/HTTPS 地址。")
    }
    guard url.user == nil, url.password == nil else {
      return Validation(url: nil, message: "无法打开：地址包含不安全的登录信息。")
    }
    guard let rawHost = url.host, !rawHost.isEmpty else {
      return Validation(url: nil, message: "无法打开：服务入口缺少主机地址。")
    }
    let host = canonicalHost(rawHost)
    guard host == "127.0.0.1" || host == "::1" else {
      return Validation(url: nil, message: "无法打开：仅允许打开本机服务地址。")
    }
    if let port = url.port, !(1...65_535).contains(port) {
      return Validation(url: nil, message: "无法打开：服务入口端口无效。")
    }
    if let expectedWebPort, (url.port ?? 0) != expectedWebPort {
      return Validation(
        url: nil,
        message: "无法打开：LocalOps Web 仅允许 127.0.0.1:8042。"
      )
    }
    return Validation(url: url, message: nil)
  }

  private static func canonicalHost(_ rawHost: String) -> String {
    let host =
      rawHost
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
    switch host {
    case "localhost", "0.0.0.0", "::": return "127.0.0.1"
    default: return host
    }
  }
}
