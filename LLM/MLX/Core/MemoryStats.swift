import Foundation
import Darwin

// MARK: - MemoryStats
//
// task_vm_info 包装。从 MLXLocalLLMService.swift L733-745 原样迁移,
// 额外提供 headroomMB 便捷访问。

enum MemoryStats {

    /// (footprint MB, jetsam limit MB) via task_info.
    static func footprintMB() -> (Double, Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let footprint = Double(info.phys_footprint) / 1_048_576
        let limit = Double(info.limit_bytes_remaining) / 1_048_576 + footprint
        return (footprint, limit)
    }

    /// 当前可用内存 headroom (MB), 用于所有 budget 计算。
    static var headroomMB: Int {
        let (footprint, limit) = footprintMB()
        return max(0, Int(limit - footprint))
    }
}
