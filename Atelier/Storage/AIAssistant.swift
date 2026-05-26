// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import ImageIO
import PDFKit
import Subprocess
import System
import UniformTypeIdentifiers
import os

/// One-shot Haiku queries used across the UI for routing suggestions, description
/// polish, and similar light AI-assist features. Wraps the `claude -p` CLI so we
/// inherit whichever auth mode the user has (API key or Pro/Max subscription).
enum AIAssistant {
    private static let logger = Logger(subsystem: "app.atelier", category: "ai-assistant")
    static let haikuModel = "claude-haiku-4-5-20251001"

    enum Error: Swift.Error, LocalizedError {
        case claudeNotFound
        case nonZeroExit(code: Int32, stderr: String)
        case empty
        case badResponse
        case timedOut
        case spawnFailed(underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "Could not find the `claude` executable."
            case .nonZeroExit(let code, let err):
                let preview = err.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Haiku exited \(code)\(preview.isEmpty ? "" : ": \(preview.prefix(200))")"
            case .empty: return "Haiku returned an empty response."
            case .badResponse:
                return "The model didn't return valid task JSON — it may have hit its step limit before finishing, or wrapped its answer in prose. Try again, or uncheck \u{201C}Inspect repo\u{201D}."
            case .timedOut:
                return "Repo inspection ran past its time limit and was stopped. Try again, simplify the brief, or uncheck \u{201C}Inspect repo\u{201D} for a faster brief-only decomposition."
            case .spawnFailed(let e): return "Failed to spawn Haiku: \(e.localizedDescription)"
            }
        }
    }

    /// Spawns `claude -p --model claude-haiku-4-5 --output-format text` with `prompt`
    /// and returns the captured stdout (trimmed).
    static func ask(prompt: String, apiKey: String? = nil) async throws -> String {
        guard let claudePath = ClaudeLocator.locate() else { throw Error.claudeNotFound }

        var envOverrides: [Environment.Key: String?] = [:]
        if let key = apiKey, !key.isEmpty {
            envOverrides["ANTHROPIC_API_KEY"] = key
        }
        let environment: Environment = .inherit.updating(envOverrides)

        let arguments: [String] = [
            "-p",
            "--model", haikuModel,
            "--permission-mode", "bypassPermissions",
            "--output-format", "text",
            "--max-turns", "1",
            prompt
        ]

        let collector = OutputCollector()
        do {
            let outcome = try await Subprocess.run(
                .path(FilePath(claudePath)),
                arguments: Arguments(arguments),
                environment: environment,
                workingDirectory: FilePath(NSTemporaryDirectory()),
                body: { execution, inputWriter, stdout, stderr in
                    try await inputWriter.finish()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in stdout.lines() {
                                await collector.appendStdout(line)
                            }
                        }
                        group.addTask {
                            for try await line in stderr.lines() {
                                await collector.appendStderr(line)
                            }
                        }
                        try await group.waitForAll()
                    }
                    _ = execution
                }
            )
            switch outcome.terminationStatus {
            case .exited(let code):
                if code != 0 {
                    let err = await collector.stderr
                    throw Error.nonZeroExit(code: Int32(code), stderr: err)
                }
            case .signaled(let sig):
                let err = await collector.stderr
                throw Error.nonZeroExit(code: Int32(sig), stderr: err)
            }
        } catch let err as Error {
            throw err
        } catch {
            throw Error.spawnFailed(underlying: error)
        }

        let raw = await collector.stdout
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Error.empty }
        return trimmed
    }

    // MARK: - Conversation title

    /// Generates a concise, Claude-style conversation title (3–6 words) from the
    /// opening exchange. Throws like `ask` so the caller can fall back to the
    /// first line of the message.
    static func titleForConversation(userMessage: String,
                                     assistantReply: String,
                                     apiKey: String? = nil) async throws -> String {
        let user = String(userMessage.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        let assistant = String(assistantReply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        let prompt = """
        Write a short, specific title for this conversation: 3 to 6 words, Title Case, \
        no surrounding quotes, no trailing punctuation, no emoji. Reply with ONLY the title.

        User: \(user)
        \(assistant.isEmpty ? "" : "Assistant: \(assistant)")
        """
        let raw = try await ask(prompt: prompt, apiKey: apiKey)
        let title = sanitizeTitle(raw)
        if title.isEmpty { throw Error.empty }
        return title
    }

    /// Strips the noise models sometimes add around a one-line title (a "Title:"
    /// prefix, wrapping quotes, trailing punctuation, extra lines).
    private static func sanitizeTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "Title:", options: [.caseInsensitive, .anchored]) {
            t = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        t = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”` "))
        while let last = t.last, ".!,;:".contains(last) { t.removeLast() }
        return String(t.prefix(60))
    }

    // MARK: - Improve description

    /// Asks Haiku to rewrite a task description so a Claude Code worker has a clearer
    /// brief. Preserves the user's intent; adds sensible structure (## Plan, ## AC, etc.)
    /// where helpful; returns plain markdown (no preamble, no fences).
    static func improveDescription(forTask task: AtelierTask,
                                   currentDescription: String,
                                   apiKey: String? = nil) async throws -> String {
        let labels = task.labels.isEmpty ? "(none)" : task.labels.joined(separator: ", ")
        let body = currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodySection = body.isEmpty ? "(empty)" : body

        let prompt = """
        You are a writing assistant for Atelier, a macOS IDE that orchestrates Claude Code workers.

        Rewrite the following task description so it gives a Claude Code worker a clearer brief.

        Guidelines:
        - Keep the user's original intent and constraints — do NOT invent new requirements.
        - Be concise. Cut filler. Prefer bullets and short paragraphs.
        - Add structure ONLY when it helps. Recommended sections:
            ## Goal       (one sentence)
            ## Plan       (numbered, only if there's a clear sequence)
            ## Acceptance criteria  (bullets, only if the user implied any)
            ## Notes / Out-of-scope (bullets, only if helpful)
        - Don't add a "## Description" section — the body is already the description.
        - Output in plain markdown. No preamble. No code fences around the whole thing.

        Task title: \(task.title)
        Labels: \(labels)

        Current description:
        \"\"\"
        \(bodySection)
        \"\"\"

        Output ONLY the improved markdown body. Begin directly with the content.
        """

        let raw = try await ask(prompt: prompt, apiKey: apiKey)
        return AIAssistant.stripCodeFences(raw)
    }

    // MARK: - CLAUDE.md generator

    /// Asks Haiku to draft a project-scoped `CLAUDE.md`. Runs in the project
    /// directory with tool access (Read / Glob / Grep) and `bypassPermissions`
    /// so it can inspect package.json, Cargo.toml, README, etc. without
    /// prompting the user. Returns the markdown.
    static func generateClaudeMd(projectPath: String,
                                 projectName: String,
                                 profile: ProjectProfile,
                                 apiKey: String? = nil) async throws -> String {
        guard let claudePath = ClaudeLocator.locate() else { throw Error.claudeNotFound }

        var envOverrides: [Environment.Key: String?] = [:]
        if let key = apiKey, !key.isEmpty {
            envOverrides["ANTHROPIC_API_KEY"] = key
        }
        let environment: Environment = .inherit.updating(envOverrides)

        let prompt = """
        Draft a tight `CLAUDE.md` for the project at the current working directory. \
        It will be checked into the repo and read by every Claude Code worker that \
        opens this project, so the contents MUST help the worker not make mistakes.

        Project name: \(projectName)
        Detected profile: \(profile.name) (\(profile.id))

        Steps:
        1. List the repo's top-level entries (Glob `*` and `**/*` if useful).
        2. Read whichever of these exist: `README*`, `package.json`, `pyproject.toml`, \
        `Cargo.toml`, `go.mod`, `Package.swift`, `*.xcodeproj/project.pbxproj` (use it for \
        scheme names), `.github/workflows/*.yml`, `Makefile`, `justfile`, `pnpm-workspace.yaml`.
        3. Output the CLAUDE.md content.

        Hard rules for the output:
        - 60–120 lines total. Never longer than 200.
        - Markdown. Plain `#` headings. No frontmatter.
        - Begin DIRECTLY with `# <project name>`. No preamble like "Here is...".
        - Every line answers: "would removing this cause Claude to make a mistake?". If no, drop it.

        Recommended sections (skip any that wouldn't carry information):
        ## What this is
        Two-line description. What the project does. Who uses it.

        ## Stack
        Languages + key frameworks/runtimes with versions, only where the version matters.

        ## Build / test / lint
        Exact commands (one per line, fenced). Don't paraphrase — copy what the repo declares.

        ## Layout
        Top-level directories with one-line purpose each.

        ## Gotchas
        Non-obvious things that bite: env vars required, generated files not to edit, \
        backwards-compat shims, slow tests, anything you can only learn by stepping on it.

        ## Conventions
        Project-specific decisions Claude couldn't guess: naming, error handling, \
        module boundaries, what NOT to refactor.

        Do NOT include:
        - Code style guides the linter already enforces.
        - Standard language conventions Claude already knows.
        - Marketing copy or aspirational statements.

        Output ONLY the CLAUDE.md markdown. No code fences around the whole thing.
        """

        let arguments: [String] = [
            "-p",
            "--model", haikuModel,
            "--permission-mode", "bypassPermissions",
            "--output-format", "text",
            "--max-turns", "12",
            "--add-dir", projectPath,
            "--",
            prompt
        ]

        let collector = OutputCollector()
        do {
            let outcome = try await Subprocess.run(
                .path(FilePath(claudePath)),
                arguments: Arguments(arguments),
                environment: environment,
                workingDirectory: FilePath(projectPath),
                body: { execution, inputWriter, stdout, stderr in
                    try await inputWriter.finish()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in stdout.lines() {
                                await collector.appendStdout(line)
                            }
                        }
                        group.addTask {
                            for try await line in stderr.lines() {
                                await collector.appendStderr(line)
                            }
                        }
                        try await group.waitForAll()
                    }
                    _ = execution
                }
            )
            switch outcome.terminationStatus {
            case .exited(let code):
                if code != 0 {
                    let err = await collector.stderr
                    throw Error.nonZeroExit(code: Int32(code), stderr: err)
                }
            case .signaled(let sig):
                let err = await collector.stderr
                throw Error.nonZeroExit(code: Int32(sig), stderr: err)
            }
        } catch let err as Error {
            throw err
        } catch {
            throw Error.spawnFailed(underlying: error)
        }

        let raw = await collector.stdout
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Error.empty }
        return AIAssistant.stripCodeFences(trimmed)
    }

    // MARK: - Fill kanban

    /// Draft proposed from `decomposeBrief`. Pre-fill that the user reviews
    /// in `FillKanbanSheet` before any task is actually persisted.
    struct TaskDraft: Identifiable, Hashable, Sendable {
        let id: UUID = UUID()
        var title: String
        var descriptionMd: String
        var priority: AtelierTask.Priority?
        var labels: [String]
        var workerModel: String?      // raw model id (nil = use project default)
        var ref: String?              // model-assigned ref ("t1") for dependency wiring
        var dependsOnRefs: [String] = []   // refs of tasks this one needs done first
    }

    /// Opus 4.7 decomposer. Takes a free-form brief / spec / dump and emits
    /// a flat list of well-formed task drafts. The model is asked to:
    ///   - chunk so each task fits a single Claude Code worker spawn,
    ///   - pick a priority + labels + suggested model from a fixed catalog,
    ///   - keep titles tight (≤ 70 chars) and descriptions in caveman style.
    static func decomposeBrief(_ brief: String,
                               project: Project,
                               profile: ProjectProfile,
                               existingTitles: [String],
                               attachments: [URL] = [],
                               repoPath: String? = nil,
                               apiKey: String? = nil,
                               onActivity: (@Sendable (String) async -> Void)? = nil) async throws -> [TaskDraft] {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let existing = existingTitles.isEmpty
            ? "(none yet)"
            : existingTitles.prefix(20).map { "- \($0)" }.joined(separator: "\n")

        let att = buildAttachmentContext(attachments)
        let attachmentSection = att.isEmpty ? "" : """


        Reference attachments (the user added these as extra context). Treat them as source \
        material and EXTRACT every relevant detail INTO the task descriptions, so each task is \
        self-contained — a worker only ever sees its own task, never these attachments.
        \(att.images.isEmpty ? "" : "\(att.images.count) image(s) are attached to this message — read them.")
        \(att.text.isEmpty ? "" : "Extracted text from attachments:\n\(att.text)")
        \(att.skipped.isEmpty ? "" : "Could not read (ignore these): \(att.skipped.joined(separator: "; ")).")
        """

        let repoSection = repoPath == nil ? "" : """


        You have READ access to this project's repo at the working directory. Inspect it ECONOMICALLY \
        and CONDITIONALLY on the brief — budget about 6 tool calls, no more:
        - Glob the tree ONCE to see the layout.
        - Identify the file(s) the brief touches AND one EXISTING feature similar to what's requested; \
        Grep/Read only those, to learn the repo's real architecture, naming and patterns so the new \
        tasks follow them.
        - Do NOT survey the whole repo, and never read large files in full.
        Then STOP exploring and WRITE the tasks — your FINAL message MUST be the JSON, and you must \
        leave budget to write it (never spend every turn inspecting). Ground each task's "## Files" \
        in REAL paths that exist; never invent files.
        """

        let prompt = """
        You are the task decomposer for Atelier, a macOS IDE that orchestrates Claude Code workers.

        HOW YOUR OUTPUT IS EXECUTED — this changes everything:
        - Each task you emit is handed to a SEPARATE Claude Code worker.
        - Each worker runs in its OWN git worktree, in parallel with the others.
        - A worker sees ONLY its own task description — NOT this brief, NOT the other tasks, \
        NOT this conversation, NOT any attachment. If a fact isn't in the task's own description, \
        the worker simply does not have it.
        - Worktrees merge back independently, so two tasks that edit the SAME file collide on merge.

        Therefore every task MUST be:
        1. SELF-CONTAINED — restate every relevant fact, name, value, shape and decision the worker \
        needs. Never write "as above", "per the spec", or "see the brief".
        2. SINGLE-WORKER-SIZED — one focused ~1-PR change finishable in a single spawn. Split bigger work.
        3. CONFLICT-MINIMAL — partition along file/module boundaries so parallel tasks rarely touch the \
        same file. State each task's file area AND what it must NOT touch (owned by siblings).
        4. DEPENDENCY-EXPLICIT — if a task needs another's output, declare it in depends_on, and order \
        the list so dependencies come first. Think in EXECUTION WAVES: tasks with no unmet dependency \
        run together in parallel (round 1); the next layer runs after (round 2); and so on. MAXIMISE \
        what runs in parallel — add a dependency only when a task genuinely needs another's output. \
        Prefer a few wide waves over one long sequential chain.

        Project: \(project.name)
        Profile: \(profile.name) (\(profile.id))
        Project default model: \(project.defaultModel ?? "claude-sonnet-4-6")
        Existing task titles (don't duplicate):
        \(existing)
        \(repoSection)

        Brief:
        \"\"\"
        \(trimmed)
        \"\"\"
        \(attachmentSection)

        For EACH task, the `description` IS the worker's entire brief. Write it as tight markdown \
        with these sections (drop one only if genuinely empty):
        ## Goal — one sentence: the outcome.
        ## Context — self-contained background: the relevant facts from the brief, data shapes, names, \
        endpoints, constraints. Enough to act with zero other input.
        ## Steps — numbered, concrete, in order.
        ## Files — specific files/dirs to create or edit (real paths when known), then a "Do not touch:" \
        line naming areas owned by sibling tasks.
        ## Acceptance criteria — testable bullets defining "done" (commands to run, behaviour to observe). \
        The worker self-checks against these.
        Caveman style inside sections: bullets over prose, no preamble, no platitudes.

        Pick per task:
        - id: short unique ref, "t1" "t2" …
        - title: ≤ 70 chars, imperative.
        - priority: low | medium | high | critical.
        - labels: lowercase, ≤ 3, from profile suggestions when relevant.
        - depends_on: ids this task needs done first ([] if independent).
        - suggested_model: one of
            claude-opus-4-7              (refactors / multi-file / architectural / ambiguous)
            claude-sonnet-4-6            (default for feature work)
            claude-haiku-4-5-20251001    (small chores / docs / mechanical edits)

        Output ONLY this JSON object — no preamble, no fences:

        {
          "tasks": [
            {
              "id": "t1",
              "title": "...",
              "description": "## Goal\\n...\\n## Context\\n...\\n## Steps\\n...\\n## Files\\n...\\n## Acceptance criteria\\n...",
              "priority": "medium",
              "labels": ["..."],
              "depends_on": [],
              "suggested_model": "claude-sonnet-4-6"
            }
          ]
        }

        Aim for 3–12 tasks unless the brief is genuinely tiny or huge. Prefer more small \
        self-contained tasks over few big ones — small tasks parallelise and merge cleanly.
        """

        // Repo inspection needs tool turns; otherwise 2 is plenty. We use the
        // stream-json path whenever there are images (vision needs it) OR a repo
        // to inspect — the latter so the live tool-use events surface as a progress
        // ticker. Only the plain no-repo / no-image case stays on the simple text path.
        let turns = repoPath == nil ? 2 : 16
        let raw: String
        if att.images.isEmpty && repoPath == nil {
            raw = try await askJSON(prompt: prompt,
                                    model: "claude-opus-4-7",
                                    maxTurns: turns,
                                    apiKey: apiKey,
                                    repoPath: repoPath)
        } else {
            raw = try await askJSONStreaming(promptText: prompt,
                                             imageBlocks: att.images,
                                             model: "claude-opus-4-7",
                                             maxTurns: turns,
                                             apiKey: apiKey,
                                             repoPath: repoPath,
                                             timeoutSeconds: repoPath == nil ? 120 : 240,
                                             onActivity: onActivity)
        }
        return try parseTaskDrafts(raw)
    }

    private static func parseTaskDrafts(_ raw: String) throws -> [TaskDraft] {
        let stripped = stripCodeFences(raw)
        // The model sometimes wraps the JSON in prose or a partial answer (e.g.
        // after hitting the turn limit). Pull out the outermost {...} and parse
        // only that, with `try?` so a bad payload yields our clear `.badResponse`
        // instead of Foundation's cryptic "isn't in the correct format".
        let jsonText: String
        if let lo = stripped.firstIndex(of: "{"), let hi = stripped.lastIndex(of: "}"), lo < hi {
            jsonText = String(stripped[lo...hi])
        } else {
            jsonText = stripped
        }
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["tasks"] as? [[String: Any]] else {
            throw Error.badResponse
        }
        return arr.compactMap { dict -> TaskDraft? in
            guard let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let description = (dict["description"] as? String) ?? ""
            let priorityRaw = (dict["priority"] as? String) ?? ""
            let priority = AtelierTask.Priority(rawValue: priorityRaw.lowercased())
            let labels = (dict["labels"] as? [String]) ?? []
            let model = (dict["suggested_model"] as? String).flatMap { val in
                val.isEmpty ? nil : val
            }
            let ref = (dict["id"] as? String)?.trimmingCharacters(in: .whitespaces)
            let deps = ((dict["depends_on"] as? [Any]) ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return TaskDraft(
                title: String(title.prefix(120)),
                descriptionMd: description,
                priority: priority,
                labels: labels.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty },
                workerModel: model,
                ref: (ref?.isEmpty ?? true) ? nil : ref,
                dependsOnRefs: deps
            )
        }
    }

    // MARK: - Attachment context

    /// A base64 PNG ready to drop into a stream-json `image` content block.
    struct ImageBlock: Sendable { let mediaType: String; let base64: String }

    /// Result of turning a list of attachment URLs into model-ready context:
    /// inlined text (for text/PDF), base64 image blocks (for images), and the
    /// names of anything we couldn't read so the prompt can say so.
    struct AttachmentContext: Sendable {
        var text: String
        var images: [ImageBlock]
        var skipped: [String]
        var isEmpty: Bool { text.isEmpty && images.isEmpty && skipped.isEmpty }
    }

    private static let perFileTextCap = 24_000
    private static let totalTextBudget = 120_000
    private static let maxImages = 8

    /// Classifies each URL and extracts what the model can actually use:
    /// images become downscaled base64 PNGs, PDFs/text get their text inlined.
    /// Synchronous file IO — call it off the main thread.
    static func buildAttachmentContext(_ urls: [URL]) -> AttachmentContext {
        var textParts: [String] = []
        var images: [ImageBlock] = []
        var skipped: [String] = []
        var textBudget = totalTextBudget

        for url in urls {
            let name = url.lastPathComponent
            switch classify(url) {
            case .image:
                if images.count >= maxImages {
                    skipped.append("\(name) (over the \(maxImages)-image limit)")
                } else if let b64 = encodeImagePNGBase64(url) {
                    images.append(ImageBlock(mediaType: "image/png", base64: b64))
                    textParts.append("--- FILE: \(name) (image) — attached to this message ---")
                } else {
                    skipped.append("\(name) (image could not be decoded)")
                }
            case .pdf:
                if let raw = PDFDocument(url: url)?.string,
                   !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textParts.append("--- FILE: \(name) (pdf, text extracted) ---\n\(clip(raw, &textBudget))")
                } else {
                    skipped.append("\(name) (pdf had no extractable text — maybe scanned)")
                }
            case .text:
                if let raw = try? String(contentsOf: url, encoding: .utf8) {
                    textParts.append("--- FILE: \(name) (text) ---\n\(clip(raw, &textBudget))")
                } else {
                    skipped.append("\(name) (not UTF-8 text)")
                }
            case .other:
                skipped.append("\(name) (not readable as text or image)")
            }
        }

        return AttachmentContext(text: textParts.joined(separator: "\n\n"),
                                 images: images,
                                 skipped: skipped)
    }

    /// Serialises a single stream-json `user` event with optional image content
    /// blocks followed by the text. Shared by the chat's image-attachment path.
    static func streamJSONUserEvent(text: String, images: [ImageBlock]) -> String? {
        var content: [[String: Any]] = images.map { blk in
            ["type": "image",
             "source": ["type": "base64", "media_type": blk.mediaType, "data": blk.base64]]
        }
        content.append(["type": "text", "text": text])
        let event: [String: Any] = ["type": "user",
                                    "message": ["role": "user", "content": content]]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Turns one stream-json output line into a short, human-readable activity
    /// line for the decompose progress ticker (or nil if there's nothing to show).
    static func activityLine(fromEventLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        var sawText = false
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                let name = (block["name"] as? String) ?? "tool"
                let input = (block["input"] as? [String: Any]) ?? [:]
                switch name {
                case "Read":
                    if let p = input["file_path"] as? String { return "Reading \((p as NSString).lastPathComponent)" }
                    return "Reading a file"
                case "Glob":
                    if let p = input["pattern"] as? String { return "Glob \(p)" }
                    return "Listing files"
                case "Grep":
                    if let p = input["pattern"] as? String { return "Grep \u{201C}\(p)\u{201D}" }
                    return "Searching the code"
                case "LS":
                    return "Listing a directory"
                case "Bash":
                    if let c = input["command"] as? String { return "Run \(c.prefix(36))" }
                    return "Running a command"
                default:
                    return name
                }
            case "text":
                if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    sawText = true
                }
            default:
                break
            }
        }
        // A pure-text assistant turn (no tool use) during repo inspection means the
        // model has stopped exploring and is writing the tasks.
        return sawText ? "Drafting tasks…" : nil
    }

    private enum AttachmentKind { case image, pdf, text, other }

    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "json", "yaml", "yml", "toml", "xml",
        "html", "htm", "csv", "tsv", "log", "ini", "cfg", "conf", "env",
        "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java",
        "kt", "kts", "c", "h", "cpp", "cc", "hpp", "cs", "php", "sh", "bash",
        "zsh", "sql", "gradle", "properties", "podspec", "rdoc", "tex"
    ]

    private static func classify(_ url: URL) -> AttachmentKind {
        let ext = url.pathExtension.lowercased()
        if let ct = UTType(filenameExtension: ext) {
            if ct.conforms(to: .image) { return .image }
            if ct.conforms(to: .pdf) { return .pdf }
            if ct.conforms(to: .sourceCode) || ct.conforms(to: .text) { return .text }
        }
        if ext == "pdf" { return .pdf }
        if textExtensions.contains(ext) { return .text }
        return .other
    }

    /// Decodes any image format ImageIO understands (incl. HEIC), downscales the
    /// long edge to ≤ 1568px (Claude's vision sweet spot), re-encodes as PNG, and
    /// base64-encodes it. Returns nil if the file isn't a decodable image.
    private static func encodeImagePNGBase64(_ url: URL, maxPixel: CGFloat = 1568) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }

    /// Takes from a shared text budget so a few huge files can't blow the prompt.
    private static func clip(_ s: String, _ budget: inout Int) -> String {
        let allowance = min(perFileTextCap, budget)
        if allowance <= 0 { return "[omitted — attachment text budget exhausted]" }
        if s.count <= allowance {
            budget -= s.count
            return s
        }
        budget -= allowance
        return String(s.prefix(allowance)) + "\n…[truncated]"
    }

    /// Variant of `ask` that uses a specific model and a larger turn budget,
    /// returning whatever JSON-ish payload the model emits.
    private static func askJSON(prompt: String,
                                model: String,
                                maxTurns: Int,
                                apiKey: String?,
                                repoPath: String? = nil) async throws -> String {
        var arguments: [String] = [
            "-p",
            "--model", model,
            "--permission-mode", "bypassPermissions",
            "--output-format", "text",
            "--max-turns", String(maxTurns)
        ]
        if let repoPath { arguments += ["--add-dir", repoPath] }
        arguments += ["--", prompt]
        let raw = try await runClaudeStdout(arguments: arguments,
                                            apiKey: apiKey,
                                            workingDirectory: repoPath ?? NSTemporaryDirectory())
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Error.empty }
        return trimmed
    }

    /// Like `askJSON` but uses `--output-format json` so we can read the run's
    /// `total_cost_usd` back out — used for autopilot review / conflict spend, which
    /// otherwise wouldn't be metered into the run total. Returns the model's text
    /// (the envelope's `result`) plus the cost.
    private static func askJSONWithCost(prompt: String,
                                        model: String,
                                        maxTurns: Int,
                                        apiKey: String?,
                                        repoPath: String? = nil) async throws -> (text: String, costUsd: Double) {
        var arguments: [String] = [
            "-p",
            "--model", model,
            "--permission-mode", "bypassPermissions",
            "--output-format", "json",
            "--max-turns", String(maxTurns)
        ]
        if let repoPath { arguments += ["--add-dir", repoPath] }
        arguments += ["--", prompt]
        let raw = try await runClaudeStdout(arguments: arguments,
                                            apiKey: apiKey,
                                            workingDirectory: repoPath ?? NSTemporaryDirectory())
        // The CLI wraps the model output: { "result": "...", "total_cost_usd": 0.12, ... }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw Error.empty }
            return (trimmed, 0)   // not JSON envelope — hand back raw, no cost
        }
        let text = ((obj["result"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cost = (obj["total_cost_usd"] as? Double) ?? (obj["cost_usd"] as? Double) ?? 0
        if text.isEmpty { throw Error.empty }
        return (text, cost)
    }

    /// Shared subprocess runner for the `-p` text/json helpers: spawns `claude`,
    /// streams stdout/stderr into a collector, and returns the collected stdout.
    private static func runClaudeStdout(arguments: [String],
                                        apiKey: String?,
                                        workingDirectory: String) async throws -> String {
        guard let claudePath = ClaudeLocator.locate() else { throw Error.claudeNotFound }

        var envOverrides: [Environment.Key: String?] = [:]
        if let key = apiKey, !key.isEmpty {
            envOverrides["ANTHROPIC_API_KEY"] = key
        }
        let environment: Environment = .inherit.updating(envOverrides)

        let collector = OutputCollector()
        do {
            let outcome = try await Subprocess.run(
                .path(FilePath(claudePath)),
                arguments: Arguments(arguments),
                environment: environment,
                workingDirectory: FilePath(workingDirectory),
                body: { execution, inputWriter, stdout, stderr in
                    try await inputWriter.finish()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in stdout.lines() {
                                await collector.appendStdout(line)
                            }
                        }
                        group.addTask {
                            for try await line in stderr.lines() {
                                await collector.appendStderr(line)
                            }
                        }
                        try await group.waitForAll()
                    }
                    _ = execution
                }
            )
            switch outcome.terminationStatus {
            case .exited(let code):
                if code != 0 {
                    let err = await collector.stderr
                    throw Error.nonZeroExit(code: Int32(code), stderr: err)
                }
            case .signaled(let sig):
                let err = await collector.stderr
                throw Error.nonZeroExit(code: Int32(sig), stderr: err)
            }
        } catch let err as Error {
            throw err
        } catch {
            throw Error.spawnFailed(underlying: error)
        }

        return await collector.stdout
    }

    /// stream-json variant of `askJSON`, used when the user attached images.
    /// Sends ONE user message containing the image blocks + the prompt text, then
    /// reads stream-json events until the terminal `result`.
    ///
    /// Two CLI quirks (v2.1.78) shape this:
    ///   - `--input-format stream-json` forces `--output-format stream-json` + `--verbose`.
    ///   - stdin must stay OPEN until the `result` arrives; closing it early (immediate
    ///     EOF) makes the CLI drop the turn and exit 0 with no output. So we write the
    ///     event, keep the writer open, and only `finish()` once we've seen the result.
    private static func askJSONStreaming(promptText: String,
                                         imageBlocks: [ImageBlock],
                                         model: String,
                                         maxTurns: Int,
                                         apiKey: String?,
                                         repoPath: String? = nil,
                                         timeoutSeconds: Double = 120,
                                         onActivity: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        guard let claudePath = ClaudeLocator.locate() else { throw Error.claudeNotFound }

        var envOverrides: [Environment.Key: String?] = [:]
        if let key = apiKey, !key.isEmpty {
            envOverrides["ANTHROPIC_API_KEY"] = key
        }
        let environment: Environment = .inherit.updating(envOverrides)

        var content: [[String: Any]] = imageBlocks.map { blk in
            ["type": "image",
             "source": ["type": "base64", "media_type": blk.mediaType, "data": blk.base64]]
        }
        content.append(["type": "text", "text": promptText])
        let event: [String: Any] = ["type": "user",
                                    "message": ["role": "user", "content": content]]
        guard let lineData = try? JSONSerialization.data(withJSONObject: event),
              let line = String(data: lineData, encoding: .utf8) else {
            throw Error.empty
        }
        let payload = line + "\n"

        var builtArgs: [String] = [
            "-p",
            "--model", model,
            "--permission-mode", "bypassPermissions",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--max-turns", String(maxTurns)
        ]
        // Block tools that only waste the turn budget (the model otherwise burns
        // turns on ToolSearch/Task and never leaves room to write the JSON). For
        // repo inspection keep Read/Glob/Grep; for image-only runs disallow all.
        var disallowed = ["Write", "Edit", "NotebookEdit", "Bash",
                          "TodoWrite", "Task", "Agent", "ToolSearch", "WebFetch", "WebSearch"]
        if repoPath == nil { disallowed += ["Read", "Glob", "Grep"] }
        builtArgs += ["--disallowed-tools"] + disallowed
        if let repoPath { builtArgs += ["--add-dir", repoPath] }
        let arguments = builtArgs                    // immutable for the sending closure
        let workDir = repoPath ?? NSTemporaryDirectory()

        let collector = OutputCollector()
        let result = StreamResult()

        // Race the run against a wall-clock timeout. If the timeout wins we cancel
        // the group, which terminates the child process (no more runaway 30-min
        // decompositions burning tokens with the UI stuck forever).
        enum RunOutcome { case finished, timedOut }
        do {
            let winner = try await withThrowingTaskGroup(of: RunOutcome.self) { group -> RunOutcome in
                group.addTask {
                    let outcome = try await Subprocess.run(
                        .path(FilePath(claudePath)),
                        arguments: Arguments(arguments),
                        environment: environment,
                        workingDirectory: FilePath(workDir),
                        body: { execution, inputWriter, stdout, stderr in
                            // Write, read, and drain concurrently: writing the (possibly
                            // multi-MB) image payload while we read stdout avoids a pipe
                            // deadlock, and we close stdin only after the result lands.
                            try await withThrowingTaskGroup(of: Void.self) { inner in
                                inner.addTask {
                                    _ = try? await inputWriter.write(payload)
                                }
                                inner.addTask {
                                    // Lift the default 128 KB line cap: a `Read` tool_result
                                    // arrives as one big JSONL line and would otherwise throw.
                                    for try await ln in stdout.lines(encoding: UTF8.self,
                                                                     bufferingPolicy: .maxLineLength(16 * 1024 * 1024)) {
                                        if let onActivity, let line = activityLine(fromEventLine: ln) {
                                            await onActivity(line)
                                        }
                                        if await result.ingest(ln) {
                                            try? await inputWriter.finish()
                                        }
                                    }
                                }
                                inner.addTask {
                                    for try await ln in stderr.lines() {
                                        await collector.appendStderr(ln)
                                    }
                                }
                                try await inner.waitForAll()
                            }
                            _ = execution
                        }
                    )
                    if case .exited(let code) = outcome.terminationStatus, code != 0,
                       await result.text == nil {
                        throw Error.nonZeroExit(code: Int32(code), stderr: await collector.stderr)
                    }
                    if case .signaled(let sig) = outcome.terminationStatus,
                       await result.text == nil {
                        throw Error.nonZeroExit(code: Int32(sig), stderr: await collector.stderr)
                    }
                    return .finished
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                _ = try? await group.next()   // drain the loser (ignore its cancellation)
                return first
            }
            if winner == .timedOut, await result.text == nil {
                throw Error.timedOut
            }
        } catch let err as Error {
            throw err
        } catch {
            if await result.text == nil { throw Error.spawnFailed(underlying: error) }
        }

        guard let text = await result.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let msg = await result.errorMessage {
                throw Error.nonZeroExit(code: -1, stderr: msg)
            }
            throw Error.empty
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Suggest model

    /// Picks one of the four Claude models based on the task. Calls Haiku with a
    /// structured JSON prompt; falls back to a parseable error if the response can't
    /// be decoded.
    static func suggestModel(forTask task: AtelierTask,
                             apiKey: String? = nil) async throws -> ModelRouter.Suggestion {
        let labels = task.labels.isEmpty ? "(none)" : task.labels.joined(separator: ", ")
        let descCount = task.descriptionMd?.count ?? 0
        let descPreview = (task.descriptionMd ?? "").prefix(1500)
        let depsCount = task.dependsOn.count

        let prompt = """
        You are the model router for Atelier, a macOS IDE that orchestrates Claude Code workers.

        Given a coding task, pick the SINGLE best Claude model from this list:
        - claude-opus-4-7    — deep refactors, complex architecture work, performance investigations. Most capable, most expensive.
        - claude-opus-4-6    — long multi-step features, large surface area, or when you need a strong reasoner without the latest tokenizer cost.
        - claude-sonnet-4-6  — default for typical feature work. Best perf/$ ratio.
        - claude-haiku-4-5-20251001 — simple chores, renames, docs edits, trivial tweaks. Fast and very cheap.

        Task title: \(task.title)
        Labels: \(labels)
        Dependencies on other tasks: \(depsCount)
        Description length: \(descCount) characters
        Description preview:
        \"\"\"
        \(descPreview)
        \"\"\"

        Respond with EXACTLY one line of JSON, no prose, no markdown fences:
        {"model":"<id>","reason":"<one short sentence — under 120 chars>"}

        The "model" field MUST be one of the four ids above, verbatim.
        """

        let raw = try await ask(prompt: prompt, apiKey: apiKey)
        return try parseModelSuggestion(raw)
    }

    private static func parseModelSuggestion(_ raw: String) throws -> ModelRouter.Suggestion {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}") else {
            throw Error.empty
        }
        let jsonSlice = trimmed[firstBrace...lastBrace]
        guard let data = String(jsonSlice).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelStr = obj["model"] as? String,
              let reason = obj["reason"] as? String,
              let model = ModelRouter.Model(rawValue: modelStr) else {
            throw Error.empty
        }
        return ModelRouter.Suggestion(model: model, reason: reason)
    }

    // MARK: - Autopilot: structured review

    /// Opus 4.7 review of a finished worktree, emitting a machine-readable `ReviewReport`
    /// (per-finding severity + a verdict) so the autopilot can auto-apply ONLY critical/major
    /// fixes. Runs read-capable in the worktree (it diffs against `baseBranch`). Throws on an
    /// empty/unparseable response so the caller blocks rather than merging an unknown review.
    static func reviewWorktree(taskTitle: String,
                               taskDescription: String,
                               worktreePath: String,
                               baseBranch: String,
                               apiKey: String? = nil) async throws -> ReviewReport {
        let brief = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        You are reviewing a feature branch a worker just completed, checked out in the current
        directory (its git worktree). The task it was given:

        Title: \(taskTitle)
        Brief:
        \"\"\"
        \(brief.isEmpty ? "(no description)" : brief)
        \"\"\"

        Inspect the ACTUAL change: run `git diff \(baseBranch)...HEAD` and read changed files as
        needed to see exactly what changed vs the base branch. Judge whether it correctly and
        completely does what the task asked, and whether it's safe to merge.

        Classify EVERY issue by severity:
        - critical: wrong behavior, crash, data loss, security hole, or a broken build/tests.
        - major: a stated acceptance criterion unmet, a real edge-case bug, a meaningful perf
          regression, or required tests missing.
        - minor: style, naming, small non-functional improvements.
        - cosmetic: formatting / whitespace / comment phrasing.

        Output ONLY this JSON object — no prose, no fences:
        {
          "verdict": "APPROVE | CHANGES_REQUESTED | NEEDS_DISCUSSION",
          "summary": "1-3 sentence overall assessment",
          "findings": [
            {"severity":"critical","file":"path/file.swift","line":42,"summary":"what is wrong","suggested_fix":"what to change"}
          ]
        }
        Use [] for findings when the change is clean. Quote REAL file paths/lines from the diff. Be
        strict about critical/major (those get auto-fixed); be lenient about minor/cosmetic.
        """
        let (raw, cost) = try await askJSONWithCost(prompt: prompt,
                                                    model: "claude-opus-4-7",
                                                    maxTurns: 25,
                                                    apiKey: apiKey,
                                                    repoPath: worktreePath)
        var report = try parseReviewReport(raw)
        report.costUsd = cost
        return report
    }

    private static func parseReviewReport(_ raw: String) throws -> ReviewReport {
        let stripped = stripCodeFences(raw)
        let jsonText: String
        if let lo = stripped.firstIndex(of: "{"), let hi = stripped.lastIndex(of: "}"), lo < hi {
            jsonText = String(stripped[lo...hi])
        } else {
            jsonText = stripped
        }
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.badResponse
        }
        let verdict = ReviewVerdict(lenient: (obj["verdict"] as? String) ?? "")
        let summary = (obj["summary"] as? String) ?? ""
        let findings: [ReviewFinding] = ((obj["findings"] as? [[String: Any]]) ?? []).compactMap { d in
            guard let sevRaw = d["severity"] as? String,
                  let sum = (d["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sum.isEmpty else { return nil }
            let line: Int? = (d["line"] as? Int) ?? (d["line"] as? String).flatMap { Int($0) }
            let file = (d["file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ReviewFinding(severity: ReviewSeverity(lenient: sevRaw),
                                 file: file, line: line,
                                 summary: sum,
                                 suggestedFix: (d["suggested_fix"] as? String) ?? "")
        }
        return ReviewReport(verdict: verdict, summary: summary, findings: findings, rawMarkdown: raw)
    }

    // MARK: - Autopilot: merge-conflict resolver

    /// Resolves an IN-PROGRESS merge conflict in the main repo with a write-capable Opus run, then
    /// finishes the merge (`git commit --no-edit`). Success is judged by the git state (no unmerged
    /// paths, MERGE_HEAD gone) — not by the model's stdout. Never pushes or aborts.
    static func resolveMergeConflict(projectPath: String,
                                     baseBranch: String,
                                     branch: String,
                                     conflictFiles: [String],
                                     taskTitle: String,
                                     apiKey: String? = nil) async throws -> (resolved: Bool, costUsd: Double) {
        let files = conflictFiles.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        A `git merge` is IN PROGRESS in the current directory and hit conflicts. Finish it.
        Merging branch `\(branch)` into `\(baseBranch)`. That branch came from the task:
        "\(taskTitle)".

        Conflicted files (resolve ONLY these — do not touch anything else):
        \(files)

        Steps:
        1. Open each conflicted file and resolve the <<<<<<< / ======= / >>>>>>> markers by
           correctly combining BOTH sides' intent (don't blindly pick one side unless that's clearly
           right). Remove all markers.
        2. `git add` each resolved file.
        3. Complete the merge: `git commit --no-edit`.

        Do NOT run `git push`, `git rebase`, or `git merge --abort`. Do NOT edit files outside the
        list above. When done there must be no remaining conflict markers and no MERGE_HEAD.
        """
        // We don't care about the model's text — the git state is the source of truth.
        let cost = (try? await askJSONWithCost(prompt: prompt,
                                               model: "claude-opus-4-7",
                                               maxTurns: 30,
                                               apiKey: apiKey,
                                               repoPath: projectPath))?.costUsd ?? 0
        let unmerged = try await GitService.unmergedFiles(projectPath: projectPath)
        let stillMerging = try await GitService.isMergeInProgress(projectPath: projectPath)
        return (unmerged.isEmpty && !stillMerging, cost)
    }

    // MARK: - Internals

    /// Removes ```… or ```markdown fences if Haiku ignored the "no fences" instruction.
    private static func stripCodeFences(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        // Drop the first line (``` or ```markdown) and the closing fence.
        var lines = trimmed.components(separatedBy: "\n")
        if !lines.isEmpty && lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor OutputCollector {
    var stdout: String = ""
    var stderr: String = ""
    func appendStdout(_ line: String) { if !line.isEmpty { stdout += line + "\n" } }
    func appendStderr(_ line: String) { if !line.isEmpty { stderr += line + "\n" } }
}

/// Parses `--output-format stream-json` events line by line. Accumulates assistant
/// text as a fallback and captures the terminal `result` event's payload.
private actor StreamResult {
    var text: String?
    var errorMessage: String?
    private var assistantText = ""

    /// Feeds one JSONL line. Returns true once the terminal `result` event is seen,
    /// signalling the caller to close stdin so the process can exit.
    func ingest(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return false
        }
        switch type {
        case "assistant":
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "text" {
                    if let txt = block["text"] as? String { assistantText += txt }
                }
            }
            return false
        case "result":
            if let r = obj["result"] as? String, !r.isEmpty {
                text = r
            } else if !assistantText.isEmpty {
                text = assistantText
            }
            if text == nil {
                let subtype = obj["subtype"] as? String
                let isError = (obj["is_error"] as? Bool) ?? false
                if isError || (subtype != nil && subtype != "success") {
                    errorMessage = "Opus stream ended without output (\(subtype ?? "error"))."
                }
            }
            return true
        default:
            return false
        }
    }
}
