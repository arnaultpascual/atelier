// SPDX-License-Identifier: MIT
//
// Atelier approval helper — runs as a claude-code PreToolUse hook.
//
// Spawn flow:
//   Atelier writes a settings JSON file with a PreToolUse hook pointing at this
//   binary, then spawns claude with `--settings <path>`.
//   On every tool call, claude invokes us, passes the tool name + input as JSON
//   on stdin, and waits for us to exit.
//   We relay the request to Atelier over a Unix domain socket and translate the
//   user's decision into the hook's exit-code / stdout JSON protocol.
//
// Why hooks instead of MCP `--permission-prompt-tool`:
//   claude validates `--permission-prompt-tool mcp__server__tool` synchronously
//   at startup, before any MCP server (HTTP or stdio) finishes connecting. The
//   validator never sees our tool. Hooks are loaded from settings JSON in a
//   single sync pass, so no race.

import Foundation

#if canImport(Darwin)
import Darwin.POSIX
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Args

struct HelperArgs {
    var socketPath: String?
    var agentId: String?
    var allowOnFailure: Bool = true

    static func parse(_ raw: [String]) -> HelperArgs {
        var out = HelperArgs()
        var i = 1
        while i < raw.count {
            switch raw[i] {
            case "--socket":
                if i + 1 < raw.count { out.socketPath = raw[i + 1]; i += 2 } else { i += 1 }
            case "--agent-id":
                if i + 1 < raw.count { out.agentId = raw[i + 1]; i += 2 } else { i += 1 }
            case "--deny-on-failure":
                out.allowOnFailure = false
                i += 1
            default:
                i += 1
            }
        }
        return out
    }
}

let args = HelperArgs.parse(CommandLine.arguments)

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[atelier-helper] \(msg)\n".utf8))
}

// MARK: - Read hook input from stdin

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let stdinObj = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
    log("could not parse stdin JSON")
    if args.allowOnFailure {
        exit(0)
    } else {
        FileHandle.standardOutput.write(Data(#"{"decision":"block","reason":"approval helper got malformed stdin"}"#.utf8))
        exit(0)
    }
}

let toolName = stdinObj["tool_name"] as? String ?? "?"
let sessionId = stdinObj["session_id"] as? String ?? ""
let toolInput = stdinObj["tool_input"] ?? [String: Any]()
let inputJSON: String = {
    guard let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return s
}()

log("hook fired tool=\(toolName) session=\(sessionId)")

// MARK: - Socket round-trip

func connectSocket(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        log("socket() failed errno=\(errno)")
        return nil
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        log("socket path too long")
        Darwin.close(fd)
        return nil
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cPtr in
            for (i, b) in pathBytes.enumerated() { cPtr[i] = CChar(bitPattern: b) }
            cPtr[pathBytes.count] = 0
        }
    }
    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else {
        log("connect() failed errno=\(errno) path=\(path)")
        Darwin.close(fd)
        return nil
    }
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var remaining = data
    while !remaining.isEmpty {
        let written = remaining.withUnsafeBytes { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress, ptr.count)
        }
        if written <= 0 { return false }
        remaining.removeFirst(written)
    }
    return true
}

func readLine(_ fd: Int32) -> Data? {
    var buffer = Data()
    var byte: UInt8 = 0
    while true {
        let n = Darwin.read(fd, &byte, 1)
        if n <= 0 { return buffer.isEmpty ? nil : buffer }
        if byte == 0x0A { return buffer }
        buffer.append(byte)
    }
}

func sendDecision(allow: Bool, message: String?) -> Never {
    if allow {
        // Decision: approve. Skip the standard permission flow and run the tool.
        FileHandle.standardOutput.write(Data(#"{"decision":"approve","reason":"Atelier user accepted"}"#.utf8))
        exit(0)
    } else {
        let safe = (message ?? "User declined").replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"{"decision":"block","reason":"\#(safe)"}"#
        FileHandle.standardOutput.write(Data(json.utf8))
        exit(0)
    }
}

guard let socketPath = args.socketPath else {
    log("no --socket, falling back to \(args.allowOnFailure ? "allow" : "deny")")
    sendDecision(allow: args.allowOnFailure, message: "no approval socket configured")
}

guard let fd = connectSocket(path: socketPath) else {
    log("socket connect failed, falling back to \(args.allowOnFailure ? "allow" : "deny")")
    sendDecision(allow: args.allowOnFailure, message: "approval socket unavailable")
}

let reqId = UUID().uuidString
let request: [String: Any] = [
    "type": "request",
    "id": reqId,
    "agent_id": args.agentId ?? "",
    "tool_name": toolName,
    "tool_use_id": sessionId,
    "input_json": inputJSON
]
guard var requestData = try? JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes]) else {
    log("could not serialize request")
    Darwin.close(fd)
    sendDecision(allow: args.allowOnFailure, message: "internal error")
}
requestData.append(0x0A)

guard writeAll(fd, requestData) else {
    log("write failed")
    Darwin.close(fd)
    sendDecision(allow: args.allowOnFailure, message: "approval socket write failed")
}

guard let responseLine = readLine(fd) else {
    log("read failed / connection closed")
    Darwin.close(fd)
    sendDecision(allow: args.allowOnFailure, message: "approval socket read failed")
}
Darwin.close(fd)

guard let response = try? JSONSerialization.jsonObject(with: responseLine) as? [String: Any] else {
    log("malformed response from atelier")
    sendDecision(allow: args.allowOnFailure, message: "malformed approval response")
}

let behavior = response["behavior"] as? String ?? "allow"
if behavior == "allow" {
    log("decision: allow")
    sendDecision(allow: true, message: nil)
} else {
    let msg = response["message"] as? String ?? "User declined"
    log("decision: deny — \(msg)")
    sendDecision(allow: false, message: msg)
}
