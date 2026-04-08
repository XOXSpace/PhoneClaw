import EventKit
import Foundation

enum CalendarTools {

    static func register(into registry: ToolRegistry) {

        // ── calendar-create-event ──
        registry.register(RegisteredTool(
            name: "calendar-create-event",
            description: "创建新的日历事项，可写入标题、开始时间、结束时间、地点和备注",
            parameters: "title: 事件标题, start: ISO 8601 开始时间, end: ISO 8601 结束时间（可选）, location: 地点（可选）, notes: 备注（可选）",
            // 只有 start 是硬参 (EventKit API 强制要求)。
            // title 是软参,缺失时 handler 用默认值,不强制 caller 提供。
            requiredParameters: ["start"]
        ) { args in
            // title 是软参: 没传或为空时使用默认标题, 不阻断流程
            let rawTitle = (args["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? "新日历事项" : rawTitle

            guard let startRaw = args["start"] as? String,
                  let startDate = parseISO8601Date(startRaw) else {
                return failurePayload(error: "缺少有效的 start 参数，必须是 ISO 8601 时间字符串")
            }

            let endRaw = (args["end"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let endDate = endRaw.flatMap(parseISO8601Date) ?? startDate.addingTimeInterval(3600)
            guard endDate >= startDate else {
                return failurePayload(error: "end 不能早于 start")
            }

            let location = (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                guard try await ToolRegistry.shared.requestAccess(for: .calendar) else {
                    return failurePayload(error: "未获得日历写入权限")
                }

                guard let calendar = writableEventCalendar() else {
                    return failurePayload(error: "没有可用于新建事项的可写日历，请先在系统日历中启用或创建一个日历")
                }

                let event = EKEvent(eventStore: SystemStores.event)
                event.calendar = calendar
                event.title = title
                event.startDate = startDate
                event.endDate = endDate
                if let location, !location.isEmpty {
                    event.location = location
                }
                if let notes, !notes.isEmpty {
                    event.notes = notes
                }

                try SystemStores.event.save(event, span: .thisEvent, commit: true)

                return successPayload(
                    result: "已创建日历事项\u{201C}\(title)\u{201D}，开始时间为 \(iso8601String(from: startDate))。",
                    extras: [
                        "eventId": event.eventIdentifier ?? "",
                        "title": title,
                        "start": iso8601String(from: startDate),
                        "end": iso8601String(from: endDate),
                        "location": location ?? "",
                        "notes": notes ?? ""
                    ]
                )
            } catch {
                return failurePayload(error: "创建日历事项失败：\(error.localizedDescription)")
            }
        })
    }

    // MARK: - Private Helpers

    private static func writableEventCalendar() -> EKCalendar? {
        if let calendar = SystemStores.event.defaultCalendarForNewEvents,
           calendar.allowsContentModifications {
            return calendar
        }

        return SystemStores.event.calendars(for: .event)
            .first(where: \.allowsContentModifications)
    }
}
