import Darwin
import Foundation
import QuartzCore

/// Explicitly enabled when launching a device investigation. Records timings
/// and resource use, never image data, and adds no periodic work otherwise.
enum CaptureDiagnostics {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-capture-diagnostics")

    static func start() -> TimeInterval { enabled ? CACurrentMediaTime() : 0 }

    static func log(_ stage: String, since started: TimeInterval? = nil,
                    _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        let timing = started.map { String(format: " elapsed_ms=%.2f", (now - $0) * 1000) } ?? ""
        let line = String(format: "[UltraWide Diagnostics] t=%.3f stage=%@", now, stage)
            + timing + " " + detail().replacingOccurrences(of: "\n", with: " ") + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / (1024 * 1024) : -1
    }

    final class ExportTrace: @unchecked Sendable {
        private let started = CACurrentMediaTime()
        private let lock = NSLock()
        private var next = 0
        private let milestones: [(Double, String)] = [
            (0.15, "export_decoded"), (0.35, "export_registered"),
            (0.43, "export_coverage"), (0.46, "export_exposure"),
            (0.49, "export_seams"), (0.50, "export_render_start"),
            (0.90, "export_render_end"), (0.94, "export_color"), (1, "export_complete")
        ]

        func record(_ fraction: Double) {
            lock.lock()
            defer { lock.unlock() }
            while next < milestones.count, fraction + 1e-8 >= milestones[next].0 {
                CaptureDiagnostics.log(milestones[next].1, since: started,
                    String(format: "memory_mb=%.1f", CaptureDiagnostics.footprintMegabytes()))
                next += 1
            }
        }
    }
}
