import AppKit
import Darwin

enum LaunchStage: String { case core, views, controller, window, mail }
enum SwitchPattern { case sequential, visible }
enum CalendarProbe { case validate, preview }

enum LayerReport {
    static func collect(_ view: NSView) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let layer = view.layer {
            result.append(["view": String(describing: type(of: view)), "width": layer.bounds.width,
                           "height": layer.bounds.height, "scale": layer.contentsScale,
                           "opaque": layer.isOpaque, "layer_class": String(describing: type(of: layer))])
        }
        return result + view.subviews.flatMap { collect($0) }
    }
}

enum MemoryProbe {
    static func snapshot() throws -> [String: Double] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw MailError(message: "Could not read process footprint") }
        let bytesPerMiB = 1024.0 * 1024.0
        return ["rss_mib": Double(info.resident_size) / bytesPerMiB,
                "footprint_mib": Double(info.phys_footprint) / bytesPerMiB]
    }
}
