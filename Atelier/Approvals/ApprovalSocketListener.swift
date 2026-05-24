// SPDX-License-Identifier: MIT
import Darwin.POSIX
import Foundation
import os

/// Per-spawn Unix-socket listener that the bundled `AtelierApprovalHelper`
/// connects to.
///
/// Protocol (newline-delimited JSON, both directions):
///
/// Helper → Atelier:
/// `{"type":"request","id":"<uuid>","agent_id":"<uuid>","tool_name":"Read",`
/// `"tool_use_id":"tu_…","input_json":"{...}"}`
///
/// Atelier → Helper:
/// `{"type":"response","id":"<uuid>","behavior":"allow","updated_input":"{...}"}`
/// or
/// `{"type":"response","id":"<uuid>","behavior":"deny","message":"…"}`
///
/// Lifecycle: TaskSpawner constructs a listener per spawn, calls
/// `start(socketPath:)` before spawning claude, then `stop()` once the worker
/// exits. On stop the socket file is removed and any in-flight pending
/// approvals for this agent are denied (so the helper doesn't deadlock).
actor ApprovalSocketListener {
    private static let logger = Logger(subsystem: "app.atelier", category: "approval-socket")

    let agentId: String
    let taskId: String?
    let projectName: String?
    private weak var queue: ApprovalQueue?

    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private(set) var socketPath: String?

    init(agentId: String, taskId: String?, projectName: String?, queue: ApprovalQueue) {
        self.agentId = agentId
        self.taskId = taskId
        self.projectName = projectName
        self.queue = queue
    }

    func start() throws -> String {
        // `sockaddr_un.sun_path` is 104 bytes on macOS, so we keep the path
        // tiny by using `/tmp/` and the first 8 chars of the agent UUID.
        let shortId = String(agentId.prefix(8))
        let path = "/tmp/at-ap-\(shortId).sock"
        unlink(path)   // remove stale

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXErrno("socket() failed")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw POSIXErrno("socket path too long (\(pathBytes.count) bytes)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cPtr in
                for (i, b) in pathBytes.enumerated() { cPtr[i] = CChar(bitPattern: b) }
                cPtr[pathBytes.count] = 0
            }
        }
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else {
            Darwin.close(fd)
            throw POSIXErrno("bind() failed at path \(path)")
        }
        guard listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXErrno("listen() failed")
        }

        self.serverFD = fd
        self.socketPath = path
        Self.logger.info("approval socket listening at \(path, privacy: .public)")

        self.acceptTask = Task { [weak self] in
            await self?.acceptLoop()
        }
        return path
    }

    func stop(reason: String = "worker exited") async {
        acceptTask?.cancel()
        readTask?.cancel()
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        if let p = socketPath { unlink(p); socketPath = nil }
        if let queue {
            await MainActor.run {
                queue.cancelPending(forAgent: agentId, reason: reason)
            }
        }
    }

    private func acceptLoop() async {
        let fd = serverFD
        while !Task.isCancelled, fd >= 0 {
            let cfd = await Task.detached { Darwin.accept(fd, nil, nil) }.value
            if Task.isCancelled || cfd < 0 { break }
            self.clientFD = cfd
            Self.logger.info("approval helper connected fd=\(cfd)")
            await readLoop(clientFD: cfd)
        }
    }

    private func readLoop(clientFD: Int32) async {
        var buffer = Data()
        outer: while !Task.isCancelled {
            let chunk = await Task.detached { () -> Data? in
                var raw = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(clientFD, &raw, raw.count)
                if n <= 0 { return nil }
                return Data(raw[0..<n])
            }.value
            guard let chunk else { break outer }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                await handleLine(line, clientFD: clientFD)
            }
        }
    }

    private func handleLine(_ line: Data, clientFD: Int32) async {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            Self.logger.warning("malformed line from helper")
            return
        }
        guard (obj["type"] as? String) == "request",
              let id = obj["id"] as? String else { return }
        let toolName = obj["tool_name"] as? String ?? "?"
        let toolUseId = obj["tool_use_id"] as? String ?? ""
        let inputJSON = obj["input_json"] as? String ?? "{}"
        let agentId = self.agentId
        let taskId = self.taskId
        let projectName = self.projectName
        guard let queue else {
            await respond(clientFD: clientFD, id: id, decision: .deny(message: "queue gone"))
            return
        }

        // Park a continuation, hand the approval to the queue, await user decision.
        let decision: ApprovalDecision = await withCheckedContinuation { cont in
            Task { @MainActor in
                let approval = PendingApproval(
                    id: id,
                    agentId: agentId,
                    taskId: taskId,
                    projectName: projectName,
                    toolName: toolName,
                    toolUseId: toolUseId,
                    inputJSON: inputJSON,
                    requestedAt: Date(),
                    status: .pending,
                    continuation: cont
                )
                queue.enqueue(approval)
            }
        }

        await respond(clientFD: clientFD, id: id, decision: decision)
    }

    private func respond(clientFD: Int32, id: String, decision: ApprovalDecision) async {
        var payload: [String: Any] = [
            "type": "response",
            "id": id
        ]
        switch decision {
        case .accept(let updated):
            payload["behavior"] = "allow"
            if let updated { payload["updated_input"] = updated }
        case .deny(let msg):
            payload["behavior"] = "deny"
            payload["message"] = msg
        }
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { ptr -> Int in
            Darwin.write(clientFD, ptr.baseAddress, ptr.count)
        }
    }
}

struct POSIXErrno: Swift.Error, LocalizedError {
    let code: Int32
    let context: String
    init(_ context: String) {
        self.code = errno
        self.context = context
    }
    var errorDescription: String? {
        let msg = String(cString: strerror(code))
        return "\(context): \(msg) (\(code))"
    }
}
