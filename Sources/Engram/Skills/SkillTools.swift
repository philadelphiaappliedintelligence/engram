import Foundation

// MARK: - Skill List Tool

/// Lists available skills (names + descriptions only — progressive disclosure tier 1)
public struct SkillListTool: Tool {
    private let loader: SkillLoader

    public init(loader: SkillLoader) { self.loader = loader }

    public var name: String { "skill_list" }
    public var description: String {
        "List all available skills. Shows names and descriptions. Use skill_view to see full instructions."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [:])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        let skills = loader.all
        guard !skills.isEmpty else {
            return "No skills installed. Create skills in ~/.engram/skills/"
        }
        var lines: [String] = ["\(skills.count) skills available:\n"]
        for skill in skills {
            let auto = skill.metadata.autoLoad ? " [auto]" : ""
            let tags = skill.metadata.tags.isEmpty ? "" : " (\(skill.metadata.tags.joined(separator: ", ")))"
            lines.append("  \(skill.metadata.name)\(auto)\(tags)")
            lines.append("    \(skill.metadata.description)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Skill View Tool

/// Load full skill content (progressive disclosure tier 2)
public struct SkillViewTool: Tool {
    private let loader: SkillLoader

    public init(loader: SkillLoader) { self.loader = loader }

    public var name: String { "skill_view" }
    public var description: String {
        "View the full instructions for a skill. Also lists any reference files or templates bundled with it."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "name": Schema.string(description: "Name of the skill to view"),
            "file": Schema.string(description: "Optional: specific reference or template file to read"),
        ], required: ["name"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let name = input["name"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: name\"}"
        }

        guard let skill = loader.get(name) else {
            let available = loader.names.joined(separator: ", ")
            return "{\"error\": \"Skill '\(name)' not found. Available: \(available)\"}"
        }

        // If a specific file was requested, read that
        if let file = input["file"]?.stringValue {
            let refs = skill.referenceFiles + skill.templateFiles
            if let match = refs.first(where: { $0.lastPathComponent == file }) {
                if let content = try? String(contentsOf: match, encoding: .utf8) {
                    return "[\(file)]:\n\(content)"
                }
                return "{\"error\": \"Could not read file: \(file)\"}"
            }
            return "{\"error\": \"File '\(file)' not found in skill '\(name)'\"}"
        }

        var output = "# \(skill.metadata.name)\n\n\(skill.content)"

        let refs = skill.referenceFiles
        if !refs.isEmpty {
            output += "\n\n## Reference Files\n"
            for ref in refs {
                output += "  - \(ref.lastPathComponent)\n"
            }
        }

        let tpls = skill.templateFiles
        if !tpls.isEmpty {
            output += "\n\n## Templates\n"
            for tpl in tpls {
                output += "  - \(tpl.lastPathComponent)\n"
            }
        }

        return output
    }
}

// MARK: - Skill Create Tool

/// Create or edit a skill at runtime (the agent can extend its own capabilities)
public struct SkillCreateTool: Tool {
    private let skillsDir: URL
    private let loader: SkillLoader

    public init(skillsDir: URL, loader: SkillLoader) {
        self.skillsDir = skillsDir
        self.loader = loader
    }

    public var name: String { "skill_create" }
    public var description: String {
        """
        Create or update a skill. Skills are markdown files with YAML frontmatter \
        that provide reusable instructions. Created skills persist across sessions.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "name": Schema.string(description: "Skill name (lowercase, hyphens ok)"),
            "description": Schema.string(description: "One-line description of what this skill does"),
            "content": Schema.string(description: "Full skill instructions in markdown"),
            "auto_load": Schema.boolean(description: "Auto-inject into system prompt every session (default: false)"),
            "tags": Schema.string(description: "Comma-separated tags"),
        ], required: ["name", "description", "content"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let name = input["name"]?.stringValue,
              let description = input["description"]?.stringValue,
              let content = input["content"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: name, description, content\"}"
        }

        let autoLoad = input["auto_load"]?.boolValue ?? false
        let tags = input["tags"]?.stringValue?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        // Create skill directory
        let skillDir = skillsDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        // Build SKILL.md with frontmatter
        var md = "---\n"
        md += "name: \(name)\n"
        md += "description: \(description)\n"
        md += "version: 1.0.0\n"
        if autoLoad { md += "auto_load: true\n" }
        if !tags.isEmpty { md += "tags: [\(tags.joined(separator: ", "))]\n" }
        md += "---\n\n"
        md += content

        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        try md.write(to: skillFile, atomically: true, encoding: .utf8)

        // Reload skills
        loader.loadAll()

        return "{\"created\": true, \"name\": \"\(name)\", \"path\": \"\(skillFile.path)\"}"
    }
}
