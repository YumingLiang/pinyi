import Darwin
import MosaicAppCore

/// `task_vm_info.phys_footprint`（与 Xcode 内存仪表 / jetsam 同口径，评审 MF-7、方案 §11.5）。
struct PhysFootprintReader: MemoryFootprintReading {
    func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
