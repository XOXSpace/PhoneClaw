import Foundation

// MARK: - JSON Utilities

func jsonEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\t", with: "\\t")
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"success\": false, \"error\": \"JSON 编码失败\"}"
    }
    return string
}

// MARK: - Tool Result Payloads

func successPayload(
    result: String,
    extras: [String: Any] = [:]
) -> String {
    var payload = extras
    payload["success"] = true
    payload["status"] = "succeeded"
    payload["result"] = result
    return jsonString(payload)
}

func failurePayload(error: String, extras: [String: Any] = [:]) -> String {
    var payload = extras
    payload["success"] = false
    payload["status"] = "failed"
    payload["error"] = error
    return jsonString(payload)
}

// MARK: - Date Helpers

func parseISO8601Date(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let isoFormatters: [ISO8601DateFormatter] = [
        {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }(),
        {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    ]

    for formatter in isoFormatters {
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }

    let formats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm"
    ]

    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }

    return nil
}

func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
