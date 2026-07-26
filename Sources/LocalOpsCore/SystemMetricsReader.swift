import Darwin
import Foundation

public struct SystemMetricsReader: Sendable {
  private let volumeURL: URL

  public init(volumeURL: URL = URL(fileURLWithPath: NSHomeDirectory())) {
    self.volumeURL = volumeURL
  }

  public func read() -> LocalOpsSystemMetrics {
    let memory = readMemory()
    let disk = readDisk()
    let load = readLoadAverage()
    let processInfo = ProcessInfo.processInfo
    return LocalOpsSystemMetrics(
      memoryUsedGb: rounded(memory.used),
      memoryTotalGb: rounded(memory.total),
      memoryPercent: percentage(part: memory.used, total: memory.total),
      diskFreeGb: rounded(disk.free),
      diskTotalGb: rounded(disk.total),
      diskPercent: percentage(part: max(0, disk.total - disk.free), total: disk.total),
      cpuLoadOneMinute: rounded(load.one, places: 2),
      cpuLoadFiveMinutes: rounded(load.five, places: 2),
      cpuLoadFifteenMinutes: rounded(load.fifteen, places: 2),
      logicalProcessorCount: processInfo.activeProcessorCount,
      uptimeSeconds: max(0, Int(processInfo.systemUptime.rounded())),
      thermalState: thermalState(processInfo.thermalState)
    )
  }

  private func readMemory() -> (used: Double, total: Double) {
    let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let status = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
      }
    }
    guard status == KERN_SUCCESS else {
      return (0, totalBytes / 1_073_741_824)
    }
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
      return (0, totalBytes / 1_073_741_824)
    }
    let pages = Double(
      statistics.active_count
        + statistics.inactive_count
        + statistics.wire_count
        + statistics.compressor_page_count
    )
    return (
      pages * Double(pageSize) / 1_073_741_824,
      totalBytes / 1_073_741_824
    )
  }

  private func readDisk() -> (free: Double, total: Double) {
    guard
      let values = try? volumeURL.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeTotalCapacityKey,
      ])
    else { return (0, 0) }
    let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
    let total = Double(values.volumeTotalCapacity ?? 0)
    return (free / 1_073_741_824, total / 1_073_741_824)
  }

  private func readLoadAverage() -> (one: Double, five: Double, fifteen: Double) {
    var values = [Double](repeating: 0, count: 3)
    let count = values.withUnsafeMutableBufferPointer { buffer in
      getloadavg(buffer.baseAddress, Int32(buffer.count))
    }
    guard count > 0 else { return (0, 0, 0) }
    return (
      values[0],
      count > 1 ? values[1] : 0,
      count > 2 ? values[2] : 0
    )
  }

  private func thermalState(_ state: ProcessInfo.ThermalState) -> LocalOpsThermalState {
    switch state {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .unknown
    }
  }

  private func rounded(_ value: Double, places: Int = 1) -> Double {
    let scale = pow(10, Double(places))
    return (value * scale).rounded() / scale
  }

  private func percentage(part: Double, total: Double) -> Double {
    guard total > 0 else { return 0 }
    return (part / total * 1_000).rounded() / 10
  }
}
