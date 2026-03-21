import Foundation

// MARK: - Cron Expression

/// Minimal 5-field cron parser: minute hour day-of-month month day-of-week
/// Supports: numbers, *, */N (step), ranges (1-5), lists (1,3,5)
public struct CronExpression: Codable, Sendable {
    public let raw: String
    private let minutes: FieldMatcher
    private let hours: FieldMatcher
    private let days: FieldMatcher
    private let months: FieldMatcher
    private let weekdays: FieldMatcher

    public init(_ expression: String) throws {
        self.raw = expression
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5 else {
            throw CronError.invalidExpression("Expected 5 fields, got \(fields.count)")
        }
        self.minutes = try FieldMatcher.parse(fields[0], range: 0...59)
        self.hours = try FieldMatcher.parse(fields[1], range: 0...23)
        self.days = try FieldMatcher.parse(fields[2], range: 1...31)
        self.months = try FieldMatcher.parse(fields[3], range: 1...12)
        self.weekdays = try FieldMatcher.parse(fields[4], range: 0...6)
    }

    public func matches(_ date: Date) -> Bool {
        let cal = Calendar.current
        let comps = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = comps.minute, let hour = comps.hour,
              let day = comps.day, let month = comps.month,
              let weekday = comps.weekday else { return false }
        let cronWeekday = weekday - 1
        return minutes.matches(minute) && hours.matches(hour) &&
               days.matches(day) && months.matches(month) &&
               weekdays.matches(cronWeekday)
    }
}

// MARK: - Field Matcher

private enum FieldMatcher: Codable, Sendable {
    case all
    case step(Int)
    case values(Set<Int>)

    func matches(_ value: Int) -> Bool {
        switch self {
        case .all: return true
        case .step(let n): return value % n == 0
        case .values(let set): return set.contains(value)
        }
    }

    static func parse(_ field: String, range: ClosedRange<Int>) throws -> FieldMatcher {
        if field == "*" { return .all }

        if field.hasPrefix("*/") {
            guard let step = Int(field.dropFirst(2)), step > 0 else {
                throw CronError.invalidExpression("Invalid step: \(field)")
            }
            return .step(step)
        }

        var values = Set<Int>()
        for part in field.split(separator: ",") {
            let s = String(part)
            if s.contains("-") {
                let bounds = s.split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] <= bounds[1] else {
                    throw CronError.invalidExpression("Invalid range: \(s)")
                }
                for v in bounds[0]...bounds[1] { values.insert(v) }
            } else if let v = Int(s) {
                values.insert(v)
            } else {
                throw CronError.invalidExpression("Invalid value: \(s)")
            }
        }
        return .values(values)
    }
}

// MARK: - Cron Job

public struct CronJob: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var schedule: String
    public var prompt: String
    public var enabled: Bool
    public var lastRun: Date?
    public var createdAt: Date

    public init(name: String, schedule: String, prompt: String) {
        self.id = UUID().uuidString.prefix(8).lowercased()
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = true
        self.lastRun = nil
        self.createdAt = Date()
    }

    public init(id: String, name: String, schedule: String, prompt: String,
                enabled: Bool, lastRun: Date?, createdAt: Date) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.lastRun = lastRun
        self.createdAt = createdAt
    }

    public func expression() throws -> CronExpression {
        try CronExpression(schedule)
    }
}

// MARK: - Cron Store (SwiftData-backed with JSON fallback)

public final class CronStore: @unchecked Sendable {
    private let file: URL
    private var jobs: [CronJob] = []
    private let lock = NSLock()
    private let store: EngramStore?

    public init(storeDir: URL, store: EngramStore? = nil) {
        self.file = storeDir.appendingPathComponent("jobs.json")
        self.store = store
        if store == nil {
            try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        }
    }

    public func load() async {
        if let store {
            let loaded = await store.loadCronJobs()
            lock.withLock {
                self.jobs = loaded.map { CronJob(id: $0.id, name: $0.name, schedule: $0.schedule,
                                                  prompt: $0.prompt, enabled: $0.enabled,
                                                  lastRun: $0.lastRun, createdAt: $0.createdAt) }
            }
        } else {
            lock.withLock {
                guard let data = try? Data(contentsOf: file) else { return }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                jobs = (try? decoder.decode([CronJob].self, from: data)) ?? []
            }
        }
    }

    public func save() {
        if let store {
            lock.lock()
            let snapshot = jobs
            lock.unlock()
            Task {
                for job in snapshot {
                    await store.saveCronJob(id: job.id, name: job.name, schedule: job.schedule,
                                            prompt: job.prompt, enabled: job.enabled, lastRun: job.lastRun)
                }
            }
        } else {
            lock.lock()
            defer { lock.unlock() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(jobs) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    public func add(_ job: CronJob) {
        lock.lock()
        jobs.append(job)
        lock.unlock()

        if let store {
            Task {
                await store.saveCronJob(id: job.id, name: job.name, schedule: job.schedule,
                                        prompt: job.prompt, enabled: job.enabled, lastRun: job.lastRun)
            }
        } else {
            save()
        }
    }

    public func remove(id: String) -> Bool {
        lock.lock()
        let before = jobs.count
        jobs.removeAll { $0.id == id }
        let removed = jobs.count < before
        lock.unlock()

        if removed {
            if let store {
                Task { _ = await store.deleteCronJob(id: id) }
            } else {
                save()
            }
        }
        return removed
    }

    public func setEnabled(id: String, enabled: Bool) {
        lock.lock()
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs[idx].enabled = enabled
        }
        lock.unlock()

        if let store {
            Task { await store.setCronJobEnabled(id: id, enabled: enabled) }
        } else {
            save()
        }
    }

    public func markRun(id: String, at date: Date = Date()) {
        lock.lock()
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs[idx].lastRun = date
        }
        lock.unlock()

        if let store {
            Task { await store.updateCronJobLastRun(id: id, date: date) }
        } else {
            save()
        }
    }

    public var allJobs: [CronJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs
    }

    public var enabledJobs: [CronJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.filter(\.enabled)
    }
}

// MARK: - Cron Scheduler

public final class CronScheduler: @unchecked Sendable {
    private let store: CronStore
    public var onFire: ((CronJob) -> Void)?

    public init(store: CronStore) {
        self.store = store
    }

    public func tick() {
        let now = Date()
        let cal = Calendar.current

        for job in store.enabledJobs {
            guard let expr = try? job.expression() else { continue }
            guard expr.matches(now) else { continue }

            if let lastRun = job.lastRun {
                let lastMinute = cal.dateComponents([.year, .month, .day, .hour, .minute], from: lastRun)
                let nowMinute = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
                if lastMinute == nowMinute { continue }
            }

            store.markRun(id: job.id, at: now)
            onFire?(job)
        }
    }
}

// MARK: - Errors

public enum CronError: Error, LocalizedError {
    case invalidExpression(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExpression(let msg): return "Invalid cron expression: \(msg)"
        }
    }
}
