import Foundation

// MARK: - Skill Metadata (YAML frontmatter)

public struct SkillMetadata: Sendable {
    public let name: String
    public let description: String
    public let version: String
    public let autoLoad: Bool       // inject into system prompt automatically
    public let tags: [String]

    public init(name: String, description: String, version: String = "1.0.0",
                autoLoad: Bool = false, tags: [String] = []) {
        self.name = name
        self.description = description
        self.version = version
        self.autoLoad = autoLoad
        self.tags = tags
    }
}

// MARK: - Skill

/// A skill is a markdown file with YAML frontmatter that provides
/// instructions the agent can load on demand. Compatible with agentskills.io.
///
/// Structure:
///   ~/.engram/skills/my-skill/
///     SKILL.md          — Main instructions (required)
///     references/       — Supporting docs
///     templates/        — Output templates
public struct Skill: Sendable {
    public let metadata: SkillMetadata
    public let content: String          // full markdown body
    public let directory: URL
    public let filePath: URL

    /// List reference files bundled with the skill
    public var referenceFiles: [URL] {
        let refsDir = directory.appendingPathComponent("references")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: refsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// List template files bundled with the skill
    public var templateFiles: [URL] {
        let tplDir = directory.appendingPathComponent("templates")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tplDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Skill Loader

/// Discovers and loads skills from multiple directories.
/// Search order:
///   1. ~/.engram/skills/           (user skills)
///   2. .engram/skills/             (project skills, walking up from cwd)
///   3. Bundled skills in the binary (none for now)
public final class SkillLoader: Sendable {
    private let searchDirs: [URL]
    private let _skills: LockedValue<[String: Skill]>

    public init(searchDirs: [URL]) {
        self.searchDirs = searchDirs
        self._skills = LockedValue([:])
    }

    /// Convenience: standard search dirs for ~/.engram/skills + project skills
    public convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".engram/skills")]

        // Walk up from cwd looking for .engram/skills/
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        var visited = Set<String>()
        while dir.path != "/" && dir.path != home.path {
            if visited.contains(dir.path) { break }
            visited.insert(dir.path)
            let projectSkills = dir.appendingPathComponent(".engram/skills")
            if fm.fileExists(atPath: projectSkills.path) {
                dirs.append(projectSkills)
            }
            // Also check .agents/skills for compatibility
            let agentsSkills = dir.appendingPathComponent(".agents/skills")
            if fm.fileExists(atPath: agentsSkills.path) {
                dirs.append(agentsSkills)
            }
            dir = dir.deletingLastPathComponent()
        }

        self.init(searchDirs: dirs)
    }

    /// Scan all search directories and load skills.
    public func loadAll() {
        let fm = FileManager.default
        var found: [String: Skill] = [:]

        for searchDir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: searchDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for item in contents {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }

                if isDir.boolValue {
                    // Directory skill: look for SKILL.md inside
                    let skillFile = item.appendingPathComponent("SKILL.md")
                    if let skill = loadSkill(at: skillFile, directory: item) {
                        found[skill.metadata.name] = skill
                    }
                } else if item.pathExtension == "md" {
                    // Single-file skill
                    if let skill = loadSkill(at: item, directory: item.deletingLastPathComponent()) {
                        found[skill.metadata.name] = skill
                    }
                }
            }
        }

        _skills.withLock { $0 = found }
    }

    // MARK: - Access

    public func get(_ name: String) -> Skill? {
        _skills.withLock { $0[name] }
    }

    public var all: [Skill] {
        _skills.withLock { Array($0.values) }.sorted { $0.metadata.name < $1.metadata.name }
    }

    public var names: [String] {
        _skills.withLock { Array($0.keys) }.sorted()
    }

    /// Skills marked with autoLoad: true — injected into every system prompt
    public var autoLoadSkills: [Skill] {
        _skills.withLock { Array($0.values) }.filter(\.metadata.autoLoad)
    }

    public var count: Int {
        _skills.withLock { $0.count }
    }

    // MARK: - Parsing

    private func loadSkill(at file: URL, directory: URL) -> Skill? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        let (metadata, body) = parseFrontmatter(raw, fallbackName: file.deletingPathExtension().lastPathComponent)

        // Basic safety scan
        guard !containsInjection(body) else { return nil }

        return Skill(metadata: metadata, content: body, directory: directory, filePath: file)
    }

    /// Parse YAML-ish frontmatter between --- delimiters.
    /// We do minimal parsing (key: value) to avoid a YAML dependency.
    private func parseFrontmatter(_ raw: String, fallbackName: String) -> (SkillMetadata, String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (SkillMetadata(name: fallbackName, description: ""), raw)
        }

        var frontmatterEnd = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                frontmatterEnd = i
                break
            }
        }

        guard frontmatterEnd > 0 else {
            return (SkillMetadata(name: fallbackName, description: ""), raw)
        }

        // Parse key: value pairs
        var dict: [String: String] = [:]
        for i in 1..<frontmatterEnd {
            let line = lines[i]
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            dict[key] = value
        }

        let body = lines[(frontmatterEnd + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse tags from comma-separated or bracketed list
        var tags: [String] = []
        if let tagsStr = dict["tags"] {
            let cleaned = tagsStr.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            tags = cleaned.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.filter { !$0.isEmpty }
        }

        let metadata = SkillMetadata(
            name: dict["name"] ?? fallbackName,
            description: dict["description"] ?? "",
            version: dict["version"] ?? "1.0.0",
            autoLoad: dict["auto_load"]?.lowercased() == "true",
            tags: tags
        )

        return (metadata, body)
    }

    /// Reject skills with obvious prompt injection or exfiltration patterns.
    private func containsInjection(_ content: String) -> Bool {
        let lower = content.lowercased()
        let patterns = [
            "ignore previous instructions",
            "disregard all prior",
            "you are now",
            "new system prompt",
            "curl.*api_key",
            "curl.*authorization",
            "cat.*\\.env",
            "echo.*\\$.*key",
        ]
        return patterns.contains { lower.contains($0) || (lower.range(of: $0, options: .regularExpression) != nil) }
    }
}
