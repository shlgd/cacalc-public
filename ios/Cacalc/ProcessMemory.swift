import Foundation
import Darwin

/// OS-reported footprint of the whole process, not the size of model files.
enum ProcessMemory {
    static func fields() -> [String: String] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return ["memoryStatus": String(status)] }
        return ["memoryScope": "whole-process", "physicalFootprintBytes": String(info.phys_footprint),
                "residentBytes": String(info.resident_size), "residentPeakBytes": String(info.resident_size_peak)]
    }
}
