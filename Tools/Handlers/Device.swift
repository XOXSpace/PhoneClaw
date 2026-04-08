import Foundation
import UIKit

enum DeviceTools {

    static func register(into registry: ToolRegistry) {

        // ── device-info ──
        registry.register(RegisteredTool(
            name: "device-info",
            description: "使用 iOS 官方公开 API 汇总获取当前设备名称、设备类型、系统版本、内存和处理器数量",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let payload = await devicePayload()
            let name = payload["name"] as? String ?? ""
            let localizedModel = (payload["localized_model"] as? String)?.isEmpty == false
                ? (payload["localized_model"] as? String ?? "")
                : (payload["model"] as? String ?? "")
            let systemName = payload["system_name"] as? String ?? ""
            let systemVersion = payload["system_version"] as? String ?? ""
            let memoryGB = payload["memory_gb"] as? Double ?? 0
            let processorCount = payload["processor_count"] as? Int ?? 0

            let summary = [
                name.isEmpty ? nil : "设备名称：\(name)",
                localizedModel.isEmpty ? nil : "设备类型：\(localizedModel)",
                systemVersion.isEmpty ? nil : "系统版本：\(systemName.isEmpty ? "" : systemName + " ")\(systemVersion)",
                memoryGB > 0 ? String(format: "物理内存：%.1f GB", memoryGB) : nil,
                processorCount > 0 ? "处理器核心数：\(processorCount)" : nil
            ].compactMap { $0 }.joined(separator: "\n")

            var enriched = payload
            enriched["result"] = summary
            enriched["status"] = "succeeded"
            return jsonString(enriched)
        })

        // ── device-name ──
        registry.register(RegisteredTool(
            name: "device-name",
            description: "使用 UIDevice.current.name 获取当前设备名称",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let payload = await devicePayload()
            let name = payload["name"] as? String ?? ""
            return successPayload(
                result: "这台设备的名称是 \(name)。",
                extras: ["name": name]
            )
        })

        // ── device-model ──
        registry.register(RegisteredTool(
            name: "device-model",
            description: "使用 UIDevice.current.model 和 localizedModel 获取当前设备类型",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let payload = await devicePayload()
            let model = payload["model"] as? String ?? ""
            let localizedModel = payload["localized_model"] as? String ?? ""
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "这台设备的官方设备类型是 \((localizedModel.isEmpty ? model : localizedModel))。",
                "model": model,
                "localized_model": localizedModel
            ])
        })

        // ── device-system-version ──
        registry.register(RegisteredTool(
            name: "device-system-version",
            description: "使用 UIDevice.current.systemName 和 systemVersion 获取系统版本",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let payload = await devicePayload()
            let systemName = payload["system_name"] as? String ?? ""
            let systemVersion = payload["system_version"] as? String ?? ""
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "当前系统版本是 \(systemName) \(systemVersion)。",
                "system_name": systemName,
                "system_version": systemVersion
            ])
        })

        // ── device-memory ──
        registry.register(RegisteredTool(
            name: "device-memory",
            description: "使用 ProcessInfo.processInfo.physicalMemory 获取设备物理内存",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let payload = await devicePayload()
            let memoryBytes = payload["memory_bytes"] as? Double ?? 0
            let memoryGB = payload["memory_gb"] as? Double ?? 0
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": String(format: "这台设备的物理内存约为 %.1f GB。", memoryGB),
                "memory_bytes": memoryBytes,
                "memory_gb": memoryGB
            ])
        })

        // ── device-processor-count ──
        registry.register(RegisteredTool(
            name: "device-processor-count",
            description: "使用 ProcessInfo.processInfo.processorCount 获取处理器核心数",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let payload = await devicePayload()
            let processorCount = payload["processor_count"] as? Int ?? 0
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "这台设备的处理器核心数是 \(processorCount)。",
                "processor_count": processorCount
            ])
        })

        // ── device-identifier-for-vendor ──
        registry.register(RegisteredTool(
            name: "device-identifier-for-vendor",
            description: "使用 UIDevice.current.identifierForVendor 获取当前 App 在该设备上的 vendor 标识",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let payload = await devicePayload()
            let identifier = payload["identifier_for_vendor"] as? String ?? ""
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "当前 App 在这台设备上的 identifierForVendor 是 \(identifier)。",
                "identifier_for_vendor": identifier
            ])
        })
    }

    // MARK: - Private Helpers

    private static func devicePayload() async -> [String: Any] {
        let info = ProcessInfo.processInfo
        let device = await MainActor.run {
            (
                UIDevice.current.name,
                UIDevice.current.model,
                UIDevice.current.localizedModel,
                UIDevice.current.systemName,
                UIDevice.current.systemVersion,
                UIDevice.current.identifierForVendor?.uuidString
            )
        }

        var payload: [String: Any] = [
            "success": true,
            "name": device.0,
            "model": device.1,
            "localized_model": device.2,
            "system_name": device.3,
            "system_version": device.4,
            "memory_bytes": Double(info.physicalMemory),
            "memory_gb": Double(info.physicalMemory) / 1_073_741_824.0,
            "processor_count": info.processorCount
        ]

        if let identifierForVendor = device.5, !identifierForVendor.isEmpty {
            payload["identifier_for_vendor"] = identifierForVendor
        }

        return payload
    }
}
