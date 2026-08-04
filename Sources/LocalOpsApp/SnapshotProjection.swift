import AppKit
import Foundation
import LocalOpsCore

extension LocalOpsSnapshotProjection {
  var title: String {
    switch state {
    case .starting: "正在准备目录"
    case .empty: "目录已就绪"
    case .fresh: "状态正常"
    case .partial: "部分信息待确认"
    case .stale: "数据已过期"
    case .coreError: "目录暂不可用"
    }
  }

  var detail: String {
    switch state {
    case .starting: return "正在初始化本地服务目录…"
    case .empty: return "还没有已登记或待登记的服务。"
    case .fresh: return "最近一次检查已完成。"
    case .partial: return "部分服务的观察结果不完整，请查看详情。"
    case .stale:
      if let error, !error.isEmpty { return "保留上次结果 · \(error)" }
      return "保留上次结果，等待下一次检查。"
    case .coreError:
      return error ?? "初始化失败，LocalOps 将自动重试。"
    }
  }

  var ageText: String? {
    guard let age, age.isFinite else { return nil }
    let seconds = Int(age.rounded(.down))
    if seconds < 60 { return "数据年龄：\(seconds) 秒" }
    let minutes = seconds / 60
    return "数据年龄：\(minutes) 分钟"
  }
}
