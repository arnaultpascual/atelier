// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// One workspace = one client / context (e.g. "Acme", "Personal", "Open Source").
/// Holds N projects.
struct Workspace: Identifiable, Hashable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var name: String
    var color: String       // hex string, e.g. "#C96442"
    var createdAt: Date

    static let databaseTableName = "workspace"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let color = Column(CodingKeys.color)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    static let projects = hasMany(Project.self)
}

extension Workspace {
    /// Curated palette of workspace accent colours, named for human-friendly menus.
    struct ColorChoice: Hashable, Sendable {
        let name: String
        let hex: String
    }

    static let colorChoices: [ColorChoice] = [
        .init(name: "Terracotta", hex: "#C96442"),
        .init(name: "Moss",       hex: "#5F8050"),
        .init(name: "Dusk",       hex: "#5772A8"),
        .init(name: "Rose",       hex: "#A86A6A"),
        .init(name: "Heather",    hex: "#7E6BA8"),
        .init(name: "Sand",       hex: "#A88B5F"),
        .init(name: "Steel",      hex: "#6B8B9E")
    ]

    static let suggestedColors: [String] = colorChoices.map(\.hex)

    static func colorName(for hex: String) -> String {
        colorChoices.first(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame })?.name ?? hex
    }

    static func newDraft(name: String, color: String = suggestedColors[0]) -> Workspace {
        Workspace(id: UUID().uuidString, name: name, color: color, createdAt: Date())
    }
}
