// SPDX-License-Identifier: MIT
//
// AtelierMCPServer — the stdio Model Context Protocol server Atelier hands to
// feature-scoped claude workers via `--mcp-config`. It speaks MCP JSON-RPC on
// stdin/stdout and bridges mutating / real-time ops to the running app over a
// Unix domain socket (`AtelierBridgeListener`), so the app stays the single
// GRDB writer. Capability only — never touches the approval flow.
//
// Mirrors AtelierApprovalHelper's zero-dependency, POSIX-socket profile. The
// shared MCP protocol + server core live in Atelier/MCP/*.swift, compiled into
// this target too.
//
// Args: --socket <path> --feature-id <id> --task-id <id> --project-path <path> --agent-id <id>

import Foundation

#if canImport(Darwin)
import Darwin.POSIX
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Args

struct ServerArgs {
    var socketPath: String?
    var featureId: String?
    var taskId: String?
    var projectPath: String?
    var agentId: String?

    static func parse(_ raw: [String]) -> ServerArgs {
        var out = ServerArgs()
        var i = 1
        func next() -> String? { if i + 1 < raw.count { defer { i += 2 }; return raw[i + 1] } else { i += 1; return nil } }
        while i < raw.count {
            switch raw[i] {
            case "--socket": out.socketPath = next()
            case "--feature-id": out.featureId = next()
            case "--task-id": out.taskId = next()
            case "--project-path": out.projectPath = next()
            case "--agent-id": out.agentId = next()
            default: i += 1
            }
        }
        return out
    }
}

func logErr(_ msg: String) {
    FileHandle.standardError.write(Data("[atelier-mcp] \(msg)\n".utf8))
}

// MARK: - POSIX socket helpers

enum Sock {
    static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { c in
                for (i, b) in bytes.enumerated() { c[i] = CChar(bitPattern: b) }
                c[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var rest = data
        while !rest.isEmpty {
            let n = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            rest.removeFirst(n)
        }
        return true
    }

    /// Reads one newline-delimited line from `fd`. Returns nil on EOF/error.
    static func readLine(_ fd: Int32) -> Data? {
        var buf = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { return buf.isEmpty ? nil : buf }
            if byte == 0x0A { return buf }
            buf.append(byte)
        }
    }
}

// MARK: - Socket bridge (server → app)

/// Real MCPBridge: a persistent, serial Unix-socket connection to the app.
/// Reconnects on demand; fails soft (returns a failure response) rather than
/// hanging the worker when the app is unreachable.
actor SocketBridge: MCPBridge {
    private let socketPath: String
    private var fd: Int32 = -1

    init(socketPath: String) { self.socketPath = socketPath }

    func send(_ request: BridgeRequest) async -> BridgeResponse {
        guard !socketPath.isEmpty else { return .failure(id: request.id, error: "no bridge socket configured") }
        if fd < 0 {
            guard let opened = Sock.connect(socketPath) else {
                return .failure(id: request.id, error: "bridge socket unavailable")
            }
            fd = opened
        }
        guard var data = try? MCPCodec.encoder.encode(request) else {
            return .failure(id: request.id, error: "encode failed")
        }
        data.append(0x0A)
        guard Sock.writeAll(fd, data) else {
            Darwin.close(fd); fd = -1
            return .failure(id: request.id, error: "bridge write failed")
        }
        guard let line = Sock.readLine(fd) else {
            Darwin.close(fd); fd = -1
            return .failure(id: request.id, error: "bridge closed")
        }
        guard let resp = try? MCPCodec.decoder.decode(BridgeResponse.self, from: line) else {
            return .failure(id: request.id, error: "malformed bridge response")
        }
        return resp
    }
}

// MARK: - stdio helpers

func writeStdout(_ data: Data) {
    var payload = data
    payload.append(0x0A)
    _ = Sock.writeAll(FileHandle.standardOutput.fileDescriptor, payload)
}

// MARK: - Main loop

// A dead stdout/socket peer must not kill us with SIGPIPE — writes return EOF/EPIPE instead,
// which the loops already handle (they exit cleanly).
signal(SIGPIPE, SIG_IGN)

let args = ServerArgs.parse(CommandLine.arguments)
logErr("start feature=\(args.featureId ?? "-") task=\(args.taskId ?? "-") socket=\(args.socketPath ?? "-")")

let core = MCPServerCore(context: MCPContext(
    featureId: args.featureId,
    taskId: args.taskId,
    projectPath: args.projectPath
))
let bridge = SocketBridge(socketPath: args.socketPath ?? "")

let stdinFD = FileHandle.standardInput.fileDescriptor
while let line = Sock.readLine(stdinFD) {
    if line.isEmpty { continue }
    guard let request = MCPCodec.decodeRequest(line) else {
        writeStdout(MCPCodec.encodeResponse(.failure(id: nil, error: .parseError())))
        continue
    }
    if let response = await core.handle(request, bridge: bridge) {
        writeStdout(MCPCodec.encodeResponse(response))
    }
}
logErr("stdin closed, exiting")
