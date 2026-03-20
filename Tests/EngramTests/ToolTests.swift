import Foundation
import Testing
@testable import Engram

// MARK: - Tool Registry

@Test func toolRegistryRegisterAndCount() {
    let registry = ToolRegistry()
    registry.register(TerminalTool())
    registry.register(FileReadTool())
    #expect(registry.count == 2)
    #expect(registry.names == ["file_read", "terminal"])
}

@Test func toolRegistryDispatch() async throws {
    let registry = ToolRegistry()
    registry.register(FileReadTool())
    let result = try await registry.dispatch(
        name: "file_read", input: ["path": .string("/nonexistent/file.txt")]
    )
    #expect(result.contains("not found") || result.contains("error"))
}

@Test func toolRegistryUnknown() async throws {
    let registry = ToolRegistry()
    let result = try await registry.dispatch(name: "nonexistent", input: [:])
    #expect(result.contains("Unknown tool"))
}

@Test func toolDefinitions() {
    let registry = ToolRegistry()
    registry.register(TerminalTool())
    registry.register(FileReadTool())
    registry.register(EditTool())
    let defs = registry.definitions
    #expect(defs.count == 3)
    #expect(defs.contains { $0.name == "terminal" })
    #expect(defs.contains { $0.name == "file_read" })
    #expect(defs.contains { $0.name == "edit" })
}

@Test func toolRegistryDuplicate() {
    let registry = ToolRegistry()
    registry.register(TerminalTool())
    registry.register(TerminalTool())
    #expect(registry.count == 1, "Duplicate names should overwrite")
}

// MARK: - Edit Tool

@Test func editToolMissingFile() async throws {
    let tool = EditTool()
    let result = try await tool.execute(input: [
        "path": .string("/tmp/nonexistent_\(UUID().uuidString).txt"),
        "old_text": .string("hello"),
        "new_text": .string("world"),
    ])
    #expect(result.contains("not found"))
}

@Test func editToolSuccess() async throws {
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("edit_test_\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    try "hello world".write(to: tmpFile, atomically: true, encoding: .utf8)
    let tool = EditTool()
    let result = try await tool.execute(input: [
        "path": .string(tmpFile.path),
        "old_text": .string("hello"),
        "new_text": .string("goodbye"),
    ])
    #expect(result.contains("edited"))
    #expect(try String(contentsOf: tmpFile, encoding: .utf8) == "goodbye world")
}

@Test func editToolNoMatch() async throws {
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("edit_nomatch_\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    try "hello world".write(to: tmpFile, atomically: true, encoding: .utf8)
    let tool = EditTool()
    let result = try await tool.execute(input: [
        "path": .string(tmpFile.path),
        "old_text": .string("xyz"),
        "new_text": .string("abc"),
    ])
    #expect(result.contains("not found"))
}

@Test func editToolReplaceAll() async throws {
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("edit_all_\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    try "aaa bbb aaa".write(to: tmpFile, atomically: true, encoding: .utf8)
    let tool = EditTool()
    _ = try await tool.execute(input: [
        "path": .string(tmpFile.path),
        "old_text": .string("aaa"),
        "new_text": .string("ccc"),
        "replace_all": .bool(true),
    ])
    #expect(try String(contentsOf: tmpFile, encoding: .utf8) == "ccc bbb ccc")
}

// MARK: - File Read Tool

@Test func fileReadWithLineNumbers() async throws {
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("read_test_\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    try "line1\nline2\nline3".write(to: tmpFile, atomically: true, encoding: .utf8)
    let tool = FileReadTool()
    let result = try await tool.execute(input: ["path": .string(tmpFile.path)])
    #expect(result.contains("1\tline1"))
    #expect(result.contains("2\tline2"))
    #expect(result.contains("3\tline3"))
}

@Test func fileReadWithOffset() async throws {
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("read_offset_\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    try "a\nb\nc\nd\ne".write(to: tmpFile, atomically: true, encoding: .utf8)
    let tool = FileReadTool()
    let result = try await tool.execute(input: [
        "path": .string(tmpFile.path),
        "offset": .number(3),
        "limit": .number(2),
    ])
    #expect(result.contains("\tc"))
    #expect(result.contains("\td"))
}

@Test func fileReadMissing() async throws {
    let tool = FileReadTool()
    let result = try await tool.execute(input: [
        "path": .string("/nonexistent_\(UUID().uuidString)")
    ])
    #expect(result.contains("not found"))
}

// MARK: - File Write Tool

@Test func fileWriteCreate() async throws {
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("write_test_\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let tool = FileWriteTool()
    let result = try await tool.execute(input: [
        "path": .string(tmpFile.path),
        "content": .string("hello"),
    ])
    #expect(result.contains("written"))
    #expect(try String(contentsOf: tmpFile, encoding: .utf8) == "hello")
}

@Test func fileWriteAppend() async throws {
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("append_test_\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    try "hello".write(to: tmpFile, atomically: true, encoding: .utf8)
    let tool = FileWriteTool()
    _ = try await tool.execute(input: [
        "path": .string(tmpFile.path),
        "content": .string(" world"),
        "append": .bool(true),
    ])
    #expect(try String(contentsOf: tmpFile, encoding: .utf8) == "hello world")
}

// MARK: - Terminal Tool

@Test func terminalEcho() async throws {
    let tool = TerminalTool()
    let result = try await tool.execute(input: [
        "command": .string("echo hello"),
    ])
    #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test func terminalExitCode() async throws {
    let tool = TerminalTool()
    let result = try await tool.execute(input: [
        "command": .string("exit 42"),
    ])
    #expect(result.contains("Exit code 42"))
}

@Test func terminalDangerous() async throws {
    let tool = TerminalTool()
    let result = try await tool.execute(input: [
        "command": .string("rm -rf /"),
    ])
    #expect(result.contains("Blocked") || result.contains("destructive"))
}

@Test func terminalCwd() async throws {
    let tool = TerminalTool()
    let result = try await tool.execute(input: [
        "command": .string("pwd"),
        "cwd": .string("/tmp"),
    ])
    #expect(result.contains("/tmp") || result.contains("/private/tmp"))
}

// MARK: - Grep Tool

@Test func grepFindsMatch() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("grep_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try "hello world\nfoo bar\nhello again".write(
        to: tmpDir.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)

    let tool = GrepTool()
    let result = try await tool.execute(input: [
        "pattern": .string("hello"),
        "path": .string(tmpDir.path),
    ])
    #expect(result.contains("hello"))
}

@Test func grepNoMatch() async throws {
    let tool = GrepTool()
    let result = try await tool.execute(input: [
        "pattern": .string("zzzznonexistent"),
        "path": .string("/tmp"),
    ])
    #expect(result.contains("no matches"))
}

// MARK: - Web Fetch Tool

@Test func webFetchMissingURL() async throws {
    let tool = WebFetchTool()
    let result = try await tool.execute(input: [:])
    #expect(result.contains("error"))
}

@Test func webFetchInvalidURL() async throws {
    let tool = WebFetchTool()
    let result = try await tool.execute(input: [
        "url": .string("not a url"),
    ])
    #expect(result.contains("error") || result.contains("Invalid"))
}

// MARK: - Schema Helpers

@Test func schemaObject() {
    let schema = Schema.object(properties: [
        "name": Schema.string(description: "test"),
        "count": Schema.number(description: "test"),
    ], required: ["name"])

    #expect(schema["type"] == .string("object"))
    if case .object(let props) = schema["properties"] {
        #expect(props.count == 2)
    } else { Issue.record("properties should be object") }
    if case .array(let req) = schema["required"] {
        #expect(req.count == 1)
    } else { Issue.record("required should be array") }
}

@Test func schemaString() {
    let s = Schema.string(description: "test desc")
    if case .object(let dict) = s {
        #expect(dict["type"] == .string("string"))
        #expect(dict["description"] == .string("test desc"))
    } else { Issue.record("Should be object") }
}

@Test func schemaEnum() {
    let e = Schema.stringEnum(description: "pick", values: ["a", "b"])
    if case .object(let dict) = e {
        #expect(dict["type"] == .string("string"))
        if case .array(let vals) = dict["enum"] {
            #expect(vals.count == 2)
        } else { Issue.record("enum should be array") }
    } else { Issue.record("Should be object") }
}

// MARK: - Execute Code Tool

@Test func executeCodePython() async throws {
    let tool = ExecuteCodeTool()
    let result = try await tool.execute(input: [
        "language": .string("python"),
        "code": .string("print(2 + 2)"),
    ])
    #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
}

@Test func executeCodeBash() async throws {
    let tool = ExecuteCodeTool()
    let result = try await tool.execute(input: [
        "language": .string("bash"),
        "code": .string("echo hello"),
    ])
    #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test func executeCodeError() async throws {
    let tool = ExecuteCodeTool()
    let result = try await tool.execute(input: [
        "language": .string("python"),
        "code": .string("raise ValueError('test')"),
    ])
    #expect(result.contains("ValueError") || result.contains("Exit"))
}

// MARK: - Spotlight Tool

@Test func spotlightMissingQuery() async throws {
    let tool = SpotlightTool()
    let result = try await tool.execute(input: [:])
    #expect(result.contains("error"))
}

// MARK: - Clipboard Tool

@Test func clipboardReadWrite() async throws {
    let tool = ClipboardTool()
    _ = try await tool.execute(input: [
        "action": .string("write"),
        "text": .string("engram test clipboard"),
    ])
    let result = try await tool.execute(input: [
        "action": .string("read"),
    ])
    #expect(result.contains("engram test clipboard"))
}
