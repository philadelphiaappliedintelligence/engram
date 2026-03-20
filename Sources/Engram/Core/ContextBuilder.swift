import Foundation

/// Builds the system prompt and context preamble from identity files,
/// memory state, skills, and platform hints.
public enum ContextBuilder {

    /// Load AGENTS.md and CLAUDE.md files walking up from cwd.
    public static func loadAgentsContext() -> String {
        let fm = FileManager.default
        var parts: [String] = []

        let home = fm.homeDirectoryForCurrentUser
        let globalAgents = home.appendingPathComponent(".engram/AGENTS.md")
        if let content = try? String(contentsOf: globalAgents, encoding: .utf8) {
            parts.append(content)
        }

        let names = ["AGENTS.md", "CLAUDE.md"]
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        var visited = Set<String>()

        while dir.path != "/" && dir.path != home.path {
            if visited.contains(dir.path) { break }
            visited.insert(dir.path)
            for name in names {
                let file = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path),
                   let content = try? String(contentsOf: file, encoding: .utf8) {
                    parts.append("[\(file.path)]:\n\(content)")
                }
            }
            dir = dir.deletingLastPathComponent()
        }

        return parts.joined(separator: "\n\n---\n\n")
    }

    /// Build the full identity/context block from SOUL.md, USER.md, BOOTSTRAP.md,
    /// promoted memory, skills, platform hints, and tool guidelines.
    public static func buildContextBlock(
        shelf: Shelf,
        skillLoader: SkillLoader,
        agentsContext: String = "",
        platformHint: String? = nil
    ) -> String {
        var parts: [String] = []

        // Identity files
        let identityFiles: [(name: String, header: String)] = [
            ("SOUL.md", "## Identity"),
            ("USER.md", "## User"),
            ("BOOTSTRAP.md", "## Bootstrap"),
        ]
        var hasIdentity = false
        var hasUserInfo = false
        for (filename, header) in identityFiles {
            let file = AgentConfig.configDir.appendingPathComponent(filename)
            if let content = try? String(contentsOf: file, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let stripped = content
                    .replacingOccurrences(of: "<!--[^>]*-->", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let noHeaders = stripped
                    .replacingOccurrences(of: "#[^\n]*\n?", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !noHeaders.isEmpty else { continue }
                parts.append("\(header)\n\(content)")
                hasIdentity = true
                if filename == "USER.md" { hasUserInfo = true }
            }
        }

        if hasUserInfo {
            parts.append("You already know this user. Do not introduce yourself or ask who they are. Use the information above naturally.")
        }

        if !hasIdentity {
            parts.append("""
            Your name is Engram. You are a persistent AI agent with holographic memory running natively on macOS.
            You learn from every conversation. Facts you recall often become permanent knowledge.
            You have surgical file editing (edit tool), terminal access, and persistent memory.
            """)
        }

        // AGENTS.md context
        if !agentsContext.isEmpty {
            parts.append("## Project Context\n\(agentsContext)")
        }

        // Promoted facts
        let promoted = shelf.promotedFacts()
        if !promoted.isEmpty {
            parts.append("## Permanent Memory (frequently recalled)")
            for item in promoted {
                parts.append("- [\(item.nugget)] \(item.fact.key): \(item.fact.value)")
            }
        }

        // Memory summary
        let statuses = shelf.status()
        if !statuses.isEmpty {
            parts.append("## Memory Status")
            for s in statuses {
                parts.append("- \(s.name): \(s.factCount) facts (\(s.promotableCount) promoted)")
            }
        }

        // Auto-loaded skills
        let autoSkills = skillLoader.autoLoadSkills
        if !autoSkills.isEmpty {
            parts.append("## Active Skills")
            for skill in autoSkills {
                parts.append("### \(skill.metadata.name)\n\(skill.content)")
            }
        }

        // Available skills
        let allSkills = skillLoader.all
        if !allSkills.isEmpty {
            let nonAutoNames = allSkills.filter { !$0.metadata.autoLoad }.map(\.metadata.name)
            if !nonAutoNames.isEmpty {
                parts.append("## Available Skills (use skill_view to load)\n\(nonAutoNames.joined(separator: ", "))")
            }
        }

        // Platform context
        if let platform = platformHint {
            parts.append("""
            ## Platform
            You are running on \(platform). The user is chatting with you through this platform.
            You have a send_message tool to send messages and files through \(platform).
            You can also use terminal, file operations, and all other tools -- you have full access to the local machine.
            """)
        }

        // Tool guidelines
        parts.append("""
        ## Tool Guidelines
        - Use memory_remember to store facts. Organize into topic nuggets (preferences, project, people, etc.)
        - Use memory_recall before answering questions -- check if you already know the answer
        - Use edit for surgical file changes (always read the file first)
        - Use file_write only for new files or complete rewrites
        - Use terminal for shell commands
        - Use skill_list and skill_view to access skills for specialized tasks
        - Use skill_create to build new reusable skills
        - Remember proactively -- names, dates, preferences, decisions, anything the user might want recalled later

        ## Identity Files
        You have three identity files in ~/.engram/ that persist across sessions. Update them silently as you learn:
        - **~/.engram/USER.md** -- Update when you learn the user's name, role, preferences, projects, or anything about them. Use the edit tool to fill in fields.
        - **~/.engram/SOUL.md** -- Your personality and name. Update when the user gives you a name or asks you to change your tone/behavior.
        - **~/.engram/BOOTSTRAP.md** -- First-run instructions. Once you know who the user is, delete this file.

        ## IMPORTANT: Memory is invisible to the user
        Never narrate or announce memory operations or file updates. Do NOT say things like "Let me check my memory" or "Let me update my files" or "I'll store that". Just do it silently and respond naturally. Memory tools and identity file updates are internal -- the user should never know you're using them. Act as if you simply know things.
        """)

        return parts.joined(separator: "\n\n")
    }
}
