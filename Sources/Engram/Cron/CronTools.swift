import Foundation

// MARK: - Cron List Tool

public struct CronListTool: Tool {
    private let store: CronStore

    public init(store: CronStore) { self.store = store }

    public var name: String { "cron_list" }
    public var description: String {
        "List all scheduled cron jobs."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [:])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        let jobs = store.allJobs
        guard !jobs.isEmpty else {
            return "No cron jobs scheduled. Use cron_create to add one."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = ["\(jobs.count) jobs:\n"]
        for job in jobs {
            let status = job.enabled ? "on" : "off"
            let lastRun = job.lastRun.map { formatter.string(from: $0) } ?? "never"
            lines.append("  [\(job.id)] \(job.name) (\(status))")
            lines.append("    Schedule: \(job.schedule)")
            lines.append("    Prompt: \(job.prompt)")
            lines.append("    Last run: \(lastRun)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Cron Create Tool

public struct CronCreateTool: Tool {
    private let store: CronStore

    public init(store: CronStore) { self.store = store }

    public var name: String { "cron_create" }
    public var description: String {
        """
        Create a scheduled cron job. The prompt will be sent to the agent \
        on the specified schedule. Uses standard 5-field cron syntax: \
        minute hour day-of-month month day-of-week. \
        Examples: "0 9 * * *" (daily 9am), "*/30 * * * *" (every 30min), \
        "0 9 * * 1-5" (weekdays 9am).
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "name": Schema.string(description: "Short name for this job"),
            "schedule": Schema.string(description: "Cron expression (5 fields: min hour dom month dow)"),
            "prompt": Schema.string(description: "Message to send to the agent when the job fires"),
        ], required: ["name", "schedule", "prompt"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let name = input["name"]?.stringValue,
              let schedule = input["schedule"]?.stringValue,
              let prompt = input["prompt"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: name, schedule, prompt\"}"
        }

        // Validate the expression
        do {
            _ = try CronExpression(schedule)
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }

        let job = CronJob(name: name, schedule: schedule, prompt: prompt)
        store.add(job)

        return "{\"created\": true, \"id\": \"\(job.id)\", \"name\": \"\(name)\", \"schedule\": \"\(schedule)\"}"
    }
}

// MARK: - Cron Delete Tool

public struct CronDeleteTool: Tool {
    private let store: CronStore

    public init(store: CronStore) { self.store = store }

    public var name: String { "cron_delete" }
    public var description: String {
        "Delete a scheduled cron job by its ID."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "id": Schema.string(description: "Job ID to delete (from cron_list)"),
        ], required: ["id"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let id = input["id"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: id\"}"
        }
        let removed = store.remove(id: id)
        return removed
            ? "{\"deleted\": true, \"id\": \"\(id)\"}"
            : "{\"error\": \"Job not found: \(id)\"}"
    }
}
