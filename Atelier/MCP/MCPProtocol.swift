// SPDX-License-Identifier: MIT
//
// Hand-rolled JSON-RPC 2.0 + Model Context Protocol wire types.
//
// There is no official Swift MCP SDK, so we implement the minimal subset the
// `AtelierMCPServer` executable needs on stdio: `initialize`, `tools/list`,
// `tools/call`, `resources/list`, `resources/read`, `prompts/list`,
// `prompts/get`. This file is PURE Foundation — it is compiled into both the
// app target (so `AtelierTests` can `@testable import Atelier`) and the
// `AtelierMCPServer` tool target. Keep it dependency-free.

import Foundation

// MARK: - JSONValue

/// A faithful, order-independent representation of an arbitrary JSON value.
/// Used for JSON-RPC `params`/`result` and for tool arguments so we never lose
/// or coerce types crossing the wire.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        // Try Int before Double so whole numbers stay integers.
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // Convenience accessors ------------------------------------------------
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int(d)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// Object subscript — returns `nil` for non-objects or missing keys.
    public subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var d: [String: JSONValue] = [:]
        for (k, v) in pairs { d[k] = v }
        return .object(d)
    }
}

// MARK: - JSON-RPC id

/// A JSON-RPC request/response id: string or number (notifications omit it).
public enum JSONRPCID: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Int.self) { self = .number(n); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be a string or number")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .number(let n): try c.encode(n) }
    }
}

// MARK: - Request

public struct JSONRPCRequest: Sendable, Equatable {
    public let id: JSONRPCID?          // absent → notification
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCID?, method: String, params: JSONValue?) {
        self.id = id; self.method = method; self.params = params
    }

    public var isNotification: Bool { id == nil }
}

extension JSONRPCRequest: Decodable {
    enum CodingKeys: String, CodingKey { case id, method, params }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(JSONRPCID.self, forKey: .id)
        self.method = try c.decode(String.self, forKey: .method)
        self.params = try c.decodeIfPresent(JSONValue.self, forKey: .params)
    }
}

// MARK: - Error

public struct JSONRPCError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }
    public static func parseError(_ msg: String = "Parse error") -> JSONRPCError { .init(code: -32700, message: msg) }
    public static func invalidRequest(_ msg: String = "Invalid request") -> JSONRPCError { .init(code: -32600, message: msg) }
    public static func methodNotFound(_ method: String) -> JSONRPCError { .init(code: -32601, message: "Method not found: \(method)") }
    public static func invalidParams(_ msg: String) -> JSONRPCError { .init(code: -32602, message: msg) }
    public static func internalError(_ msg: String) -> JSONRPCError { .init(code: -32603, message: msg) }
}

// MARK: - Response

public struct JSONRPCResponse: Sendable, Equatable {
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public static func success(id: JSONRPCID?, result: JSONValue) -> JSONRPCResponse {
        .init(id: id, result: result, error: nil)
    }
    public static func failure(id: JSONRPCID?, error: JSONRPCError) -> JSONRPCResponse {
        .init(id: id, result: nil, error: error)
    }
    private init(id: JSONRPCID?, result: JSONValue?, error: JSONRPCError?) {
        self.id = id; self.result = result; self.error = error
    }
}

extension JSONRPCResponse: Encodable {
    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("2.0", forKey: .jsonrpc)
        if let id { try c.encode(id, forKey: .id) } else { try c.encodeNil(forKey: .id) }
        if let error {
            try c.encode(error, forKey: .error)
        } else {
            try c.encode(result ?? .null, forKey: .result)
        }
    }
}

// MARK: - Codec

/// Newline-delimited JSON codec for the stdio MCP transport.
public enum MCPCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    public static let decoder = JSONDecoder()

    /// Decodes one JSON-RPC request line. Returns nil on malformed input.
    public static func decodeRequest(_ data: Data) -> JSONRPCRequest? {
        try? decoder.decode(JSONRPCRequest.self, from: data)
    }

    /// Encodes a response to compact JSON (no trailing newline — the transport adds it).
    public static func encodeResponse(_ response: JSONRPCResponse) -> Data {
        (try? encoder.encode(response)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#.utf8)
    }
}
