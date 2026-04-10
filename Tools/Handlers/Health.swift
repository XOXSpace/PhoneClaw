import Foundation
import HealthKit

// MARK: - Health Tools
//
// 读取 HealthKit 里用户的健康数据。只读,不写。
//
// v1 实现 health-steps-today (今日步数)。
// Phase 2 扩展: steps-yesterday, steps-range, distance, energy,
// heart rate, sleep, workout。
//
// 权限策略: 每次调用时检查授权, 首次会弹系统对话框。用户拒绝后直接返回
// failurePayload, 由 skill body 里的指令让模型给用户一个友好解释。

enum HealthTools {

    /// HealthKit store 单例 — Apple 官方建议整个 app 只创建一个
    private static let store = HKHealthStore()

    static func register(into registry: ToolRegistry) {

        registerStepsToday(into: registry)
        registerStepsYesterday(into: registry)
        registerStepsRange(into: registry)
        registerDistanceToday(into: registry)
        registerActiveEnergyToday(into: registry)
        registerHeartRateResting(into: registry)
        registerSleepLastNight(into: registry)
        registerSleepWeek(into: registry)
        registerWorkoutRecent(into: registry)
    }

    // ── health-steps-today ──
    private static func registerStepsToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-today",
            description: "读取用户今日步数 (从本地 0 点到当前时间的累计步数)。仅读取,不修改。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let cal = Calendar.current
            let now = Date()
            let start = cal.startOfDay(for: now)
            guard let steps = await fetchQuantitySum(
                identifier: .stepCount, unit: .count(), start: start, end: now
            ) else {
                return stepsPermissionError()
            }
            let rounded = Int(steps.rounded())
            return successPayload(
                result: "今日步数: \(rounded) 步",
                extras: ["steps": rounded, "unit": "步", "date": isoDateString(now)]
            )
        })
    }

    // ── health-steps-yesterday ──
    private static func registerStepsYesterday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-yesterday",
            description: "读取用户昨日步数 (昨天本地 0 点到 23:59:59 的累计步数)。仅读取,不修改。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Date())
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            guard let steps = await fetchQuantitySum(
                identifier: .stepCount, unit: .count(), start: yesterdayStart, end: todayStart
            ) else {
                return stepsPermissionError()
            }
            let rounded = Int(steps.rounded())
            return successPayload(
                result: "昨日步数: \(rounded) 步",
                extras: ["steps": rounded, "unit": "步", "date": isoDateString(yesterdayStart)]
            )
        })
    }

    // ── health-sleep-last-night ──
    private static func registerSleepLastNight(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-sleep-last-night",
            description: "读取用户昨晚的睡眠数据 (最近 24 小时内的睡眠记录)。返回总时长和分阶段明细。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let now = Date()
            let start = Calendar.current.date(byAdding: .hour, value: -24, to: now)!
            guard let stages = await fetchSleepAnalysis(start: start, end: now) else {
                return failurePayload(error: "无法读取睡眠数据。请确认健康权限已开启。")
            }
            if stages.isEmpty {
                return successPayload(
                    result: "最近 24 小时没有睡眠记录",
                    extras: ["total_minutes": 0, "stages": [] as [Any]]
                )
            }
            let totalMin = stages.reduce(0) { $0 + $1.minutes }
            let hours = totalMin / 60
            let mins = totalMin % 60
            let stageList = stages.map { ["stage": $0.stage, "minutes": $0.minutes] as [String: Any] }
            return successPayload(
                result: "昨晚睡眠: \(hours) 小时 \(mins) 分钟",
                extras: ["total_minutes": totalMin, "hours": hours, "minutes": mins, "stages": stageList]
            )
        })
    }

    // ── health-sleep-week ──
    private static func registerSleepWeek(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-sleep-week",
            description: "读取用户最近 7 天的睡眠汇总 (每晚总时长 + 7 天平均)。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let cal = Calendar.current
            let now = Date()
            let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
            guard let stages = await fetchSleepAnalysis(start: weekAgo, end: now) else {
                return failurePayload(error: "无法读取睡眠数据。请确认健康权限已开启。")
            }
            if stages.isEmpty {
                return successPayload(
                    result: "最近 7 天没有睡眠记录",
                    extras: ["nights": [] as [Any], "avg_minutes": 0]
                )
            }
            let totalMin = stages.reduce(0) { $0 + $1.minutes }
            let avgMin = totalMin / 7
            let avgH = avgMin / 60
            let avgM = avgMin % 60
            return successPayload(
                result: "最近 7 天睡眠: 日均 \(avgH) 小时 \(avgM) 分钟",
                extras: ["total_minutes": totalMin, "avg_minutes": avgMin, "days": 7]
            )
        })
    }

    // ── health-workout-recent ──
    private static func registerWorkoutRecent(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-workout-recent",
            description: "读取用户最近 7 天的运动记录 (类型、时长、消耗)。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let cal = Calendar.current
            let now = Date()
            let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
            guard let workouts = await fetchWorkouts(start: weekAgo, end: now) else {
                return failurePayload(error: "无法读取运动数据。请确认健康权限已开启。")
            }
            if workouts.isEmpty {
                return successPayload(
                    result: "最近 7 天没有运动记录",
                    extras: ["workouts": [] as [Any], "count": 0]
                )
            }
            let list = workouts.map { w in
                ["type": w.type, "duration_min": w.durationMin, "calories": w.calories, "date": w.date] as [String: Any]
            }
            let totalMin = workouts.reduce(0) { $0 + $1.durationMin }
            return successPayload(
                result: "最近 7 天共 \(workouts.count) 次运动, 总时长 \(totalMin) 分钟",
                extras: ["workouts": list, "count": workouts.count, "total_minutes": totalMin]
            )
        })
    }

    // ── health-distance-today ──
    private static func registerDistanceToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-distance-today",
            description: "读取用户今日步行+跑步距离 (从本地 0 点到当前时间, 单位 km)。仅读取。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let cal = Calendar.current
            let now = Date()
            let start = cal.startOfDay(for: now)
            guard let meters = await fetchQuantitySum(
                identifier: .distanceWalkingRunning, unit: .meter(), start: start, end: now
            ) else {
                return failurePayload(error: "无法读取距离数据。请确认健康权限已开启。")
            }
            let km = (meters / 1000 * 100).rounded() / 100  // 保留 2 位小数
            return successPayload(
                result: "今日步行距离: \(km) 公里",
                extras: ["distance_km": km, "distance_m": Int(meters.rounded()), "date": isoDateString(now)]
            )
        })
    }

    // ── health-active-energy-today ──
    private static func registerActiveEnergyToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-active-energy-today",
            description: "读取用户今日活动消耗的卡路里 (从本地 0 点到当前时间)。仅读取。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            let cal = Calendar.current
            let now = Date()
            let start = cal.startOfDay(for: now)
            guard let kcal = await fetchQuantitySum(
                identifier: .activeEnergyBurned, unit: .kilocalorie(), start: start, end: now
            ) else {
                return failurePayload(error: "无法读取能量消耗数据。请确认健康权限已开启。")
            }
            let rounded = Int(kcal.rounded())
            return successPayload(
                result: "今日活动消耗: \(rounded) 千卡",
                extras: ["calories": rounded, "unit": "kcal", "date": isoDateString(now)]
            )
        })
    }

    // ── health-heart-rate-resting ──
    private static func registerHeartRateResting(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-heart-rate-resting",
            description: "读取用户最近的静息心率 (最近 24 小时平均, 单位 BPM)。仅读取。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            guard let bpm = await fetchLatestQuantity(
                identifier: .restingHeartRate,
                unit: HKUnit.count().unitDivided(by: .minute())
            ) else {
                return failurePayload(error: "无法读取心率数据。请确认健康权限已开启。")
            }
            let rounded = Int(bpm.rounded())
            return successPayload(
                result: "静息心率: \(rounded) BPM",
                extras: ["bpm": rounded, "unit": "BPM"]
            )
        })
    }

    // ── health-steps-range ──
    private static func registerStepsRange(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-range",
            description: "读取最近 N 天的每日步数。返回每日列表 + 总数 + 日均。",
            parameters: "{\"days\":{\"type\":\"integer\",\"description\":\"查询天数 (1-30)\",\"required\":true}}",
            requiredParameters: ["days"],
            isParameterless: false
        ) { args in
            guard let days = (args["days"] as? Int) ?? (args["days"] as? String).flatMap(Int.init) else {
                return failurePayload(error: "缺少 days 参数 (1-30 的整数)")
            }
            let clampedDays = max(1, min(30, days))
            guard let entries = await fetchDailyQuantitySums(
                identifier: .stepCount, unit: .count(), days: clampedDays
            ) else {
                return stepsPermissionError()
            }
            let total = entries.reduce(0) { $0 + Int($1.value.rounded()) }
            let avg = entries.isEmpty ? 0 : total / entries.count
            let dailyList = entries.map { ["date": $0.date, "steps": Int($0.value.rounded())] as [String: Any] }
            return successPayload(
                result: "最近 \(clampedDays) 天步数: 总计 \(total) 步, 日均 \(avg) 步",
                extras: [
                    "days": clampedDays,
                    "total": total,
                    "daily_avg": avg,
                    "daily": dailyList
                ]
            )
        })
    }

    // MARK: - Shared HealthKit Helpers
    //
    // 所有 Health tool 共用的 query 封装。每个 helper 负责一种 HK query 模式,
    // 具体 tool 的 register 闭包只需要组装参数 + 格式化返回值。

    /// 请求读取权限并验证设备支持。
    /// 返回 nil 表示成功, 返回 String 表示错误信息 (直接可作为 failurePayload error)。
    static func requestReadAuth(for types: Set<HKObjectType>) async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "设备不支持 HealthKit"
        }
        do {
            try await store.requestAuthorization(toShare: [], read: types)
        } catch {
            return "健康数据授权失败: \(error.localizedDescription)"
        }
        return nil
    }

    /// 查询某个 quantity type 在时间区间内的累计总和 (steps, distance, energy 等)。
    /// 内含 requestReadAuth, 失败返回 nil。
    static func fetchQuantitySum(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> Double? {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return nil
        }
        if let err = await requestReadAuth(for: [qType]) {
            print("[Health] auth error: \(err)")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: .strictStartDate
            )
            let query = HKStatisticsQuery(
                quantityType: qType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                let sum = stats?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: sum)
            }
            store.execute(query)
        }
    }

    /// 查询最新一条离散值 (heart rate 等)。
    /// 用 HKStatisticsQuery + .discreteAverage 取最近区间平均值。
    static func fetchLatestQuantity(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        hoursBack: Int = 24
    ) async -> Double? {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return nil
        }
        if let err = await requestReadAuth(for: [qType]) {
            print("[Health] auth error: \(err)")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let now = Date()
            let start = Calendar.current.date(byAdding: .hour, value: -hoursBack, to: now)!
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: now, options: .strictStartDate
            )
            let query = HKStatisticsQuery(
                quantityType: qType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, _ in
                let avg = stats?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: avg)
            }
            store.execute(query)
        }
    }

    /// 按天查询 quantity type 的每日聚合 (用于 steps-range)。
    /// 返回 [(date: String, value: Double)] 数组, 最近 days 天。
    static func fetchDailyQuantitySums(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        days: Int
    ) async -> [(date: String, value: Double)]? {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return nil
        }
        if let err = await requestReadAuth(for: [qType]) {
            print("[Health] auth error: \(err)")
            return nil
        }
        let cal = Calendar.current
        let now = Date()
        let endOfToday = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: now))!
        let interval = DateComponents(day: 1)

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: endOfToday, options: .strictStartDate
            )
            let query = HKStatisticsCollectionQuery(
                quantityType: qType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, error in
                guard let results else {
                    continuation.resume(returning: nil)
                    return
                }
                var entries: [(date: String, value: Double)] = []
                results.enumerateStatistics(from: start, to: endOfToday) { stat, _ in
                    let val = stat.sumQuantity()?.doubleValue(for: unit) ?? 0
                    entries.append((date: isoDateString(stat.startDate), value: val))
                }
                continuation.resume(returning: entries)
            }
            store.execute(query)
        }
    }

    /// 查询睡眠分析数据 (HKCategoryType)。
    /// 返回 [(stage: String, minutes: Int)] 数组。
    static func fetchSleepAnalysis(
        start: Date,
        end: Date
    ) async -> [(stage: String, minutes: Int)]? {
        guard let sleepType = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else { return nil }
        if let err = await requestReadAuth(for: [sleepType]) {
            print("[Health] auth error: \(err)")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: .strictStartDate
            )
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    continuation.resume(returning: error == nil ? [] : nil)
                    return
                }
                var result: [(stage: String, minutes: Int)] = []
                for s in samples {
                    let mins = Int(s.endDate.timeIntervalSince(s.startDate) / 60)
                    let stage: String
                    if #available(iOS 16.0, *) {
                        switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                        case .inBed:        stage = "inBed"
                        case .asleepCore:   stage = "core"
                        case .asleepDeep:   stage = "deep"
                        case .asleepREM:    stage = "REM"
                        case .awake:        stage = "awake"
                        default:            stage = "unknown"
                        }
                    } else {
                        switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                        case .inBed:    stage = "inBed"
                        case .asleep:   stage = "asleep"
                        case .awake:    stage = "awake"
                        default:        stage = "unknown"
                        }
                    }
                    result.append((stage: stage, minutes: mins))
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    /// 查询最近的运动记录 (HKWorkout)。
    static func fetchWorkouts(
        start: Date,
        end: Date,
        limit: Int = 20
    ) async -> [(type: String, durationMin: Int, calories: Int, date: String)]? {
        let workoutType = HKWorkoutType.workoutType()
        if let err = await requestReadAuth(for: [workoutType]) {
            print("[Health] auth error: \(err)")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: .strictStartDate
            )
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                guard let workouts = samples as? [HKWorkout] else {
                    continuation.resume(returning: error == nil ? [] : nil)
                    return
                }
                let result = workouts.map { w in
                    (
                        type: workoutActivityName(w.workoutActivityType),
                        durationMin: Int(w.duration / 60),
                        calories: Int(w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0),
                        date: isoDateString(w.startDate)
                    )
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    // MARK: - Formatting Helpers

    static func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func stepsPermissionError() -> String {
        failurePayload(
            error: "无法读取步数。可能是授权被拒绝, 或没有数据。"
                + "请在设置 → 隐私与安全性 → 健康 → PhoneClaw 里确认开启了步数读取权限。"
        )
    }

    private static func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:              return "跑步"
        case .walking:              return "步行"
        case .cycling:              return "骑行"
        case .swimming:             return "游泳"
        case .yoga:                 return "瑜伽"
        case .hiking:               return "徒步"
        case .functionalStrengthTraining, .traditionalStrengthTraining:
                                    return "力量训练"
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance:                return "舞蹈"
        case .elliptical:           return "椭圆机"
        case .rowing:               return "划船"
        case .stairClimbing:        return "爬楼"
        default:                    return "其他运动"
        }
    }
}
