// SPDX-License-Identifier: MIT
import Foundation
import Yams

/// Parses and writes Backlog.md-compatible task files (`backlog/tasks/<id>-<slug>.md`).
///
/// File format (frontmatter between `---` fences, then markdown body):
/// ```yaml
/// ---
/// id: task-001
/// title: "Add OAuth2 login"
/// status: "To Do"
/// priority: high
/// labels: [auth, backend]
/// worker_model: claude-sonnet-4-6
/// budget_usd: 2.50
/// depends_on: []
/// created_date: "2026-05-22 14:32"
/// updated_date: "2026-05-22 14:32"
/// ---
///
/// ## Description
/// …
/// ```
///
/// We preserve unknown frontmatter keys on write (round-trip is loss-less for keys
/// we don't model, so users can hand-edit `.md` files with their own conventions).
enum BacklogMD {
    enum Error: Swift.Error, LocalizedError {
        case malformedFrontmatter(String)
        case missingRequiredField(String)
        case ioError(String, underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .malformedFrontmatter(let m): return "Malformed YAML frontmatter: \(m)"
            case .missingRequiredField(let f): return "Missing required field: \(f)"
            case .ioError(let p, let u): return "I/O error on \(p): \(u.localizedDescription)"
            }
        }
    }

    /// All fields parsed from disk + the body text. Unknown fields are preserved as
    /// `extras` so we can round-trip them on save.
    struct ParsedTask {
        var id: String
        var title: String
        var status: AtelierTask.Status
        var priority: AtelierTask.Priority?
        var labels: [String]
        var workerModel: String?
        var budgetUsd: Double?
        var dependsOn: [String]
        var attachments: [String]
        var createdAt: Date
        var updatedAt: Date
        var body: String
        var extras: [String: Any] = [:]      // unrecognised frontmatter keys
    }

    // MARK: - Parsing

    static func parse(contents: String) throws -> ParsedTask {
        let parts = splitFrontmatter(contents)
        guard let fmYAML = parts.frontmatter else {
            throw Error.malformedFrontmatter("no `---` fences found")
        }
        let node: Yams.Node
        do {
            node = try Yams.compose(yaml: fmYAML) ?? .mapping(.init())
        } catch {
            throw Error.malformedFrontmatter(error.localizedDescription)
        }
        guard case .mapping(let mapping) = node else {
            throw Error.malformedFrontmatter("frontmatter root is not a mapping")
        }

        var pulled: [String: Any] = [:]
        for (keyNode, valueNode) in mapping {
            if case .scalar(let keyScalar) = keyNode {
                pulled[keyScalar.string] = decodeNode(valueNode)
            }
        }

        guard let id = pulled.removeValue(forKey: "id") as? String else {
            throw Error.missingRequiredField("id")
        }
        guard let title = pulled.removeValue(forKey: "title") as? String else {
            throw Error.missingRequiredField("title")
        }

        let statusStr = (pulled.removeValue(forKey: "status") as? String) ?? "To Do"
        let status = AtelierTask.Status(rawValue: statusStr) ?? .toDo

        let priorityStr = pulled.removeValue(forKey: "priority") as? String
        let priority = priorityStr.flatMap { AtelierTask.Priority(rawValue: $0) }

        let labels = (pulled.removeValue(forKey: "labels") as? [Any] ?? []).compactMap { $0 as? String }
        let dependsOn = (pulled.removeValue(forKey: "depends_on") as? [Any] ?? []).compactMap { $0 as? String }
        let attachments = (pulled.removeValue(forKey: "attachments") as? [Any] ?? []).compactMap { $0 as? String }

        let workerModel = pulled.removeValue(forKey: "worker_model") as? String
        let budgetUsd: Double? = {
            let raw = pulled.removeValue(forKey: "budget_usd")
            if let d = raw as? Double { return d }
            if let i = raw as? Int { return Double(i) }
            if let s = raw as? String { return Double(s) }
            return nil
        }()

        let createdAt = (pulled.removeValue(forKey: "created_date") as? String).flatMap(parseDate) ?? Date()
        let updatedAt = (pulled.removeValue(forKey: "updated_date") as? String).flatMap(parseDate) ?? createdAt

        return ParsedTask(
            id: id,
            title: title,
            status: status,
            priority: priority,
            labels: labels,
            workerModel: workerModel,
            budgetUsd: budgetUsd,
            dependsOn: dependsOn,
            attachments: attachments,
            createdAt: createdAt,
            updatedAt: updatedAt,
            body: parts.body.trimmingCharacters(in: .whitespacesAndNewlines),
            extras: pulled
        )
    }

    static func read(at path: String) throws -> ParsedTask {
        do {
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            return try parse(contents: contents)
        } catch let err as Error {
            throw err
        } catch {
            throw Error.ioError(path, underlying: error)
        }
    }

    // MARK: - Serialization

    static func serialize(task: AtelierTask, extras: [String: Any] = [:]) throws -> String {
        var fm: [(key: String, value: Any)] = []
        fm.append(("id", task.id))
        fm.append(("title", task.title))
        fm.append(("status", task.status.rawValue))
        if let p = task.priority { fm.append(("priority", p.rawValue)) }
        fm.append(("labels", task.labels))
        if let m = task.workerModel { fm.append(("worker_model", m)) }
        if let b = task.budgetUsd { fm.append(("budget_usd", b)) }
        fm.append(("depends_on", task.dependsOn))
        if !task.attachments.isEmpty {
            fm.append(("attachments", task.attachments))
        }
        fm.append(("created_date", formatDate(task.createdAt)))
        fm.append(("updated_date", formatDate(task.updatedAt)))

        // Preserve unknown extras after the structured fields, sorted for stability.
        for key in extras.keys.sorted() {
            fm.append((key, extras[key] ?? NSNull()))
        }

        // Build a mapping node in declared order.
        var mapping: [(Yams.Node, Yams.Node)] = []
        for (key, value) in fm {
            mapping.append((Yams.Node(key), encodeYAMLValue(value)))
        }
        let root = Yams.Node.mapping(.init(mapping))
        let yaml = try Yams.serialize(node: root, indent: 2, width: -1, allowUnicode: true)

        let body = task.descriptionMd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bodyBlock = body.isEmpty ? "" : "\n\(body)\n"
        return "---\n\(yaml.trimmingCharacters(in: .whitespacesAndNewlines))\n---\n\(bodyBlock)"
    }

    static func write(task: AtelierTask, to path: String, extras: [String: Any] = [:]) throws {
        let serialized = try serialize(task: task, extras: extras)
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try serialized.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Error.ioError(path, underlying: error)
        }
    }

    // MARK: - Filename helpers

    /// `"Add OAuth2 login"` → `"add-oauth2-login"` (slug for filename).
    static func slugify(_ title: String, maxLen: Int = 48) -> String {
        let lowered = title.lowercased()
        var result = ""
        var lastWasDash = true
        for char in lowered {
            if char.isLetter || char.isNumber {
                result.append(char)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
            if result.count >= maxLen { break }
        }
        if result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "untitled" : result
    }

    static func filename(forId id: String, title: String) -> String {
        let slug = slugify(title)
        return "\(id)-\(slug).md"
    }

    /// Compute the next sequential id given existing ids (e.g. ["task-001", "task-003"] → "task-004").
    static func nextId(existing: [String]) -> String {
        let nums = existing.compactMap { id -> Int? in
            let parts = id.split(separator: "-")
            guard parts.count >= 2, parts[0] == "task" else { return nil }
            return Int(parts[1])
        }
        let next = (nums.max() ?? 0) + 1
        return String(format: "task-%03d", next)
    }

    // MARK: - Internals

    private static func splitFrontmatter(_ contents: String) -> (frontmatter: String?, body: String) {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, contents)
        }
        var fmLines: [String] = []
        var bodyStart: Int? = nil
        for idx in 1..<lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = idx + 1
                break
            }
            fmLines.append(lines[idx])
        }
        guard let bodyStart else { return (nil, contents) }
        let body = lines[bodyStart...].joined(separator: "\n")
        return (fmLines.joined(separator: "\n"), body)
    }

    private static func decodeNode(_ node: Yams.Node) -> Any {
        switch node {
        case .scalar(let s):
            // YAML scalars can be int, double, bool, or string — yams hints via tag
            if let n = Int(s.string) { return n }
            if let d = Double(s.string) { return d }
            switch s.string.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            case "null", "~": return NSNull()
            default: return s.string
            }
        case .sequence(let seq):
            return seq.map { decodeNode($0) }
        case .mapping(let m):
            var out: [String: Any] = [:]
            for (k, v) in m {
                if case .scalar(let ks) = k {
                    out[ks.string] = decodeNode(v)
                }
            }
            return out
        case .alias:
            // YAML anchors/aliases aren't used in our schema; treat as opaque string.
            return String(describing: node)
        }
    }

    private static func encodeYAMLValue(_ value: Any) -> Yams.Node {
        if value is NSNull { return Yams.Node("null", Yams.Tag(.null)) }
        if let s = value as? String { return Yams.Node(s) }
        if let b = value as? Bool { return Yams.Node(String(b), Yams.Tag(.bool)) }
        if let i = value as? Int { return Yams.Node(String(i), Yams.Tag(.int)) }
        if let d = value as? Double { return Yams.Node(String(d), Yams.Tag(.float)) }
        if let arr = value as? [Any] {
            return .sequence(.init(arr.map(encodeYAMLValue)))
        }
        if let dict = value as? [String: Any] {
            var pairs: [(Yams.Node, Yams.Node)] = []
            for k in dict.keys.sorted() {
                pairs.append((Yams.Node(k), encodeYAMLValue(dict[k] ?? NSNull())))
            }
            return .mapping(.init(pairs))
        }
        return Yams.Node(String(describing: value))
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        return df
    }()

    private static func parseDate(_ s: String) -> Date? {
        if let d = dateFormatter.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }

    private static func formatDate(_ d: Date) -> String {
        dateFormatter.string(from: d)
    }
}
