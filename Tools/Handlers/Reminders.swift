import EventKit
import Foundation

enum RemindersTools {

    static func register(into registry: ToolRegistry) {

        // ── reminders-create ──
        registry.register(RegisteredTool(
            name: "reminders-create",
            description: "创建新的提醒事项，可写入标题、到期时间和备注",
            parameters: "title: 提醒标题, due: ISO 8601 到期时间（可选）, notes: 备注（可选）",
            requiredParameters: ["title"]
        ) { args in
            guard let rawTitle = args["title"] as? String else {
                return failurePayload(error: "缺少 title 参数")
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return failurePayload(error: "缺少 title 参数")
            }

            let dueRaw = (args["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dueRaw, !dueRaw.isEmpty, parseISO8601Date(dueRaw) == nil {
                return failurePayload(error: "due 必须是有效的 ISO 8601 时间字符串")
            }

            let dueDate = dueRaw.flatMap(parseISO8601Date)
            let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                guard try await ToolRegistry.shared.requestAccess(for: .reminders) else {
                    return failurePayload(error: "未获得提醒事项权限")
                }

                guard let calendar = try ensureWritableReminderCalendar() else {
                    return failurePayload(error: "没有可用于新建提醒事项的可写列表，且无法自动创建提醒列表，请先在系统提醒事项 App 中启用或创建一个列表")
                }

                let reminder = EKReminder(eventStore: SystemStores.event)
                reminder.calendar = calendar
                reminder.title = title
                if let dueDate {
                    reminder.dueDateComponents = reminderDateComponents(from: dueDate)
                    reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
                }
                if let notes, !notes.isEmpty {
                    reminder.notes = notes
                }

                try SystemStores.event.save(reminder, commit: true)

                return successPayload(
                    result: dueDate != nil
                        ? "已创建提醒事项\u{201C}\(title)\u{201D}，提醒时间为 \(iso8601String(from: dueDate!))。"
                        : "已创建提醒事项\u{201C}\(title)\u{201D}。",
                    extras: [
                        "calendarItemId": reminder.calendarItemIdentifier,
                        "title": title,
                        "due": dueDate.map { iso8601String(from: $0) } ?? "",
                        "notes": notes ?? ""
                    ]
                )
            } catch {
                return failurePayload(error: "创建提醒事项失败：\(error.localizedDescription)")
            }
        })
    }

    // MARK: - Private Helpers

    private static func writableReminderCalendar() -> EKCalendar? {
        if let calendar = SystemStores.event.defaultCalendarForNewReminders(),
           calendar.allowsContentModifications {
            return calendar
        }

        return SystemStores.event.calendars(for: .reminder)
            .first(where: \.allowsContentModifications)
    }

    private static func newReminderListTitle() -> String {
        let prefersChinese = Locale.preferredLanguages.contains { $0.hasPrefix("zh") }
        return prefersChinese ? "PhoneClaw 提醒事项" : "PhoneClaw Reminders"
    }

    private static func reminderCalendarCreationSources() -> [EKSource] {
        let existingReminderSources = Set(
            SystemStores.event.calendars(for: .reminder)
                .map(\.source.sourceIdentifier)
        )

        func priority(for source: EKSource) -> Int? {
            switch source.sourceType {
            case .local:
                return existingReminderSources.contains(source.sourceIdentifier) ? 0 : 1
            case .mobileMe:
                return existingReminderSources.contains(source.sourceIdentifier) ? 2 : 3
            case .calDAV:
                return existingReminderSources.contains(source.sourceIdentifier) ? 4 : 5
            case .exchange:
                return existingReminderSources.contains(source.sourceIdentifier) ? 6 : 7
            case .subscribed, .birthdays:
                return nil
            @unknown default:
                return existingReminderSources.contains(source.sourceIdentifier) ? 8 : 9
            }
        }

        let prioritizedSources: [(priority: Int, source: EKSource)] = SystemStores.event.sources.compactMap { source -> (priority: Int, source: EKSource)? in
            guard let priority = priority(for: source) else { return nil }
            return (priority, source)
        }

        return prioritizedSources
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.source.title.localizedCaseInsensitiveCompare(rhs.source.title) == .orderedAscending
                }
                return lhs.priority < rhs.priority
            }
            .map(\.source)
    }

    private static func ensureWritableReminderCalendar() throws -> EKCalendar? {
        if let calendar = writableReminderCalendar() {
            return calendar
        }

        var lastError: Error?
        for source in reminderCalendarCreationSources() {
            let reminderList = EKCalendar(for: .reminder, eventStore: SystemStores.event)
            reminderList.title = newReminderListTitle()
            reminderList.source = source

            do {
                try SystemStores.event.saveCalendar(reminderList, commit: true)
                if reminderList.allowsContentModifications {
                    return reminderList
                }
                if let saved = SystemStores.event.calendar(withIdentifier: reminderList.calendarIdentifier),
                   saved.allowsContentModifications {
                    return saved
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        return nil
    }

    private static func reminderDateComponents(from date: Date) -> DateComponents {
        Calendar.current.dateComponents(
            in: .current,
            from: date
        )
    }
}
