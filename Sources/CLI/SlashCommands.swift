import Engram
import Foundation

func handleSlashCommand(
    _ cmd: String, shelf: Shelf, config: AgentConfig,
    agent: AgentLoop, session: SessionManager, skills: SkillLoader,
    cronStore: CronStore
) async -> Bool {
    let parts = cmd.split(separator: " ", maxSplits: 1)
    let command = parts.first.map(String.init)?.lowercased() ?? ""

    switch command {
    case "memory", "mem":
        let statuses = shelf.status()
        if statuses.isEmpty {
            print("  Memory is empty.")
        } else {
            for s in statuses {
                print("  \(s.name): \(s.factCount) facts (\(s.promotableCount) promoted)")
            }
        }
        return true

    case "skills":
        let all = skills.all
        if all.isEmpty {
            print("  No skills installed.")
        } else {
            for s in all {
                let auto = s.metadata.autoLoad ? " [auto]" : ""
                print("  \(s.metadata.name)\(auto) -- \(s.metadata.description)")
            }
        }
        return true

    case "new", "clear":
        await agent.clearHistory()
        print(dim("New session started. Memory preserved."))
        return true

    case "tokens", "cost":
        let usage = await agent.tokenUsage
        let cache = await agent.cacheUsage
        let ctx = await agent.contextUsage
        let pct = ctx.max > 0 ? Int(Double(ctx.current) / Double(ctx.max) * 100) : 0
        print("  Input: \(usage.input) | Output: \(usage.output)")
        if cache.read > 0 || cache.write > 0 {
            print("  Cache: \(cache.read) read, \(cache.write) written")
        }
        print("  Context: ~\(ctx.current)/\(ctx.max) (\(pct)%)")
        let inputCost = Double(usage.input - cache.read) * 3.0 / 1_000_000
        let cacheCost = Double(cache.read) * 0.30 / 1_000_000
        let outputCost = Double(usage.output) * 15.0 / 1_000_000
        print("  Est. cost: $\(String(format: "%.4f", inputCost + cacheCost + outputCost))")
        return true

    case "sessions":
        let sessions = await session.listSessions()
        if sessions.isEmpty {
            print("  No saved sessions.")
        } else {
            for s in sessions.suffix(5) {
                print("  \(dim(s.filename)) -- \(String(s.preview.prefix(50)))")
            }
        }
        return true

    case "save":
        shelf.saveAll()
        print(dim("Memory saved."))
        return true

    case "cron":
        let jobs = cronStore.allJobs
        if jobs.isEmpty {
            print("  No cron jobs. The agent can create them with cron_create.")
        } else {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            for job in jobs {
                let status = job.enabled ? "on" : "off"
                let last = job.lastRun.map { f.string(from: $0) } ?? "never"
                print("  [\(job.id)] \(job.name) (\(status)) -- \(job.schedule) -- last: \(last)")
            }
        }
        print(dim("  Cron jobs run in the daemon. Start with: engram daemon start"))
        return true

    case "daemon":
        print("  Daemon: \(Daemon.status().rawValue)")
        return true

    case "help":
        print("""
          /memory    -- Memory status
          /skills    -- List skills
          /cron      -- List cron jobs
          /tokens    -- Token usage & cost
          /sessions  -- Recent sessions
          /new       -- Start new session (keeps memory)
          /save      -- Force save memory
          /daemon    -- Daemon status
          /help      -- This help
          exit       -- Quit
        """)
        return true

    default:
        print(dim("Unknown: /\(command). Try /help"))
        return true
    }
}
