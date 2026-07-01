// SPDX-License-Identifier: MIT
import Darwin.POSIX
import Foundation
import os

/// Per-spawn Unix-socket listener for the MCP capability bridge — the mirror of
/// `ApprovalSocketListener`, but for capability ops instead of approvals. The
/// embedded `AtelierMCPServer` connects here and round-trips `BridgeRequest` /
/// `BridgeResponse` (newline-delimited JSON). Every mutation is marshalled onto
/// @MainActor through `AppStore`, keeping the app the single GRDB writer.
///
/// Capability only — this never participates in the permission/approval flow.
///
/// Ops (Phase 1):
///   task_report_progress → ephemeral in-memory progress (live kanban %)
///   resource_read        → the living brief.md for the scoped feature
actor AtelierBridgeListener {
    private static let logger = Logger(subsystem: "app.atelier", category: "mcp-bridge")

    let agentId: String
    let featureId: String
    let projectPath: String
    private weak var store: AppStore?

    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private(set) var socketPath: String?

    init(agentId: String, featureId: String, projectPath: String, store: AppStore) {
        self.agentId = agentId
        self.featureId = featureId
        self.projectPath = projectPath
        self.store = store
    }

    func start() throws -> String {
        let shortId = String(agentId.prefix(8))
        let path = "/tmp/at-mcp-\(shortId).sock"   // sun_path is 104 bytes — keep it short
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXErrno("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd); throw POSIXErrno("socket path too long (\(pathBytes.count) bytes)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cPtr in
                for (i, b) in pathBytes.enumerated() { cPtr[i] = CChar(bitPattern: b) }
                cPtr[pathBytes.count] = 0
            }
        }
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else { Darwin.close(fd); throw POSIXErrno("bind() failed at \(path)") }
        guard listen(fd, 1) == 0 else { Darwin.close(fd); throw POSIXErrno("listen() failed") }

        self.serverFD = fd
        self.socketPath = path
        Self.logger.info("mcp bridge listening at \(path, privacy: .public)")
        self.acceptTask = Task { [weak self] in await self?.acceptLoop() }
        return path
    }

    func stop(reason: String = "worker exited") async {
        acceptTask?.cancel()
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        if let p = socketPath { unlink(p); socketPath = nil }
        Self.logger.info("mcp bridge stopped: \(reason, privacy: .public)")
    }

    private func acceptLoop() async {
        let fd = serverFD
        while !Task.isCancelled, fd >= 0 {
            let cfd = await Task.detached { Darwin.accept(fd, nil, nil) }.value
            if Task.isCancelled || cfd < 0 { break }
            self.clientFD = cfd
            await readLoop(clientFD: cfd)
        }
    }

    private func readLoop(clientFD: Int32) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = await Task.detached { () -> Data? in
                var raw = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(clientFD, &raw, raw.count)
                if n <= 0 { return nil }
                return Data(raw[0..<n])
            }.value
            guard let chunk else { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                await handleLine(line, clientFD: clientFD)
            }
        }
    }

    private func handleLine(_ line: Data, clientFD: Int32) async {
        guard let request = try? MCPCodec.decoder.decode(BridgeRequest.self, from: line) else {
            Self.logger.warning("malformed bridge request")
            return
        }
        let response = await handle(request)
        respond(clientFD: clientFD, response: response)
    }

    private func respond(clientFD: Int32, response: BridgeResponse) {
        guard var data = try? MCPCodec.encoder.encode(response) else { return }
        data.append(0x0A)
        var rest = data
        while !rest.isEmpty {
            let n = rest.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            rest.removeFirst(n)
        }
    }

    // MARK: - Op routing (all app state touched on @MainActor)

    private func handle(_ req: BridgeRequest) async -> BridgeResponse {
        guard let store = self.store else {
            return .failure(id: req.id, error: "app store unavailable")
        }
        let featureId = self.featureId
        switch req.op {
        case "task_report_progress":
            guard let taskId = req.taskId, !taskId.isEmpty else {
                return .failure(id: req.id, error: "missing taskId")
            }
            let pct = req.args["pct"]?.intValue ?? 0
            let note = req.args["note"]?.stringValue
            await MainActor.run { store.reportProgress(taskId: taskId, pct: pct, note: note) }
            return .success(id: req.id, result: nil)

        case "resource_read":
            // Resolve the living-brief URL on @MainActor (store access only), then
            // read the file OFF the main actor (no blocking I/O on MainActor).
            let (featureFound, url): (Bool, URL?) = await MainActor.run {
                guard let feature = store.featureByID(featureId) else { return (false, nil) }
                return (true, feature.briefRoomId.flatMap { store.chatRoom(id: $0) }?.briefFileURL)
            }
            switch Self.briefResolution(featureFound: featureFound, briefURL: url) {
            case .notFound(let err):
                return .failure(id: req.id, error: err)
            case .empty:
                return .success(id: req.id, result: Self.markdownResource(""))
            case .url(let fileURL):
                return .success(id: req.id, result: Self.markdownResource(Self.readBriefFile(fileURL)))
            }

        default:
            return .failure(id: req.id, error: "unknown op: \(req.op)")
        }
    }

    /// Pure decision for a living-brief resource read (unit-tested):
    /// - feature absent → error; feature present but no brief room yet → empty
    ///   (brief stage not entered); otherwise read the resolved URL.
    enum BriefResolution: Equatable, Sendable { case url(URL); case empty; case notFound(String) }

    static func briefResolution(featureFound: Bool, briefURL: URL?) -> BriefResolution {
        guard featureFound else { return .notFound("feature not found") }
        guard let briefURL else { return .empty }   // brief stage not entered yet
        return .url(briefURL)
    }

    /// Reads a brief file, tolerating a not-yet-created file (→ empty string).
    static func readBriefFile(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func markdownResource(_ text: String) -> JSONValue {
        .object(["text": .string(text), "mimeType": .string("text/markdown")])
    }
}
