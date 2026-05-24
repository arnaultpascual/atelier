// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// Schema migrations. Each migration is registered once and idempotent.
///
/// Convention: **camelCase column names** throughout, so they line up with Swift
/// property names and GRDB's `belongsTo` foreign-key generator (which already
/// produces names like `workspaceId`). The spec §2.3 shows snake_case for clarity —
/// here we keep it Swift-native, which simplifies record decoding.
///
/// Phase 1 / slice 1.1 ships migration **v1** with the full table set from the spec
/// (§2.3). Tables we don't use yet (agent, approval, policy, event) are created empty;
/// later slices fill them in without needing a new migration.
enum Schema {
    static func migrate(_ pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "project") { t in
                t.primaryKey("id", .text).notNull()
                t.belongsTo("workspace", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("profileId", .text)
                t.column("defaultModel", .text)
                t.column("budgetUsdMonthly", .double)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "task") { t in
                t.primaryKey("id", .text).notNull()
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                t.column("priority", .text)
                t.column("labels", .text)               // JSON array
                t.column("mdPath", .text).notNull()
                t.column("dependsOn", .text)            // JSON array of task ids
                t.column("workerModel", .text)
                t.column("budgetUsd", .double)
                t.column("descriptionMd", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "agent") { t in
                t.primaryKey("id", .text).notNull()
                t.belongsTo("task", onDelete: .cascade).notNull()
                t.column("worktreePath", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("pid", .integer)
                t.column("status", .text).notNull()
                t.column("model", .text).notNull()
                t.column("sessionId", .text)
                t.column("sessionJsonlPath", .text)
                t.column("costUsd", .double).notNull().defaults(to: 0)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheReadTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheCreationTokens", .integer).notNull().defaults(to: 0)
                t.column("startedAt", .datetime)
                t.column("endedAt", .datetime)
            }

            try db.create(table: "approval") { t in
                t.primaryKey("id", .text).notNull()
                t.belongsTo("agent", onDelete: .cascade).notNull()
                t.column("toolUseId", .text).notNull()
                t.column("toolName", .text).notNull()
                t.column("inputJson", .text).notNull()
                t.column("status", .text).notNull()
                t.column("responseJson", .text)
                t.column("decidedBy", .text)
                t.column("decidedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "policy") { t in
                t.primaryKey("id", .text).notNull()
                t.belongsTo("project", onDelete: .cascade)
                t.column("toolName", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("learned", .boolean).notNull().defaults(to: false)
                t.column("hitCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("agent", onDelete: .cascade).notNull()
                t.column("ts", .datetime).notNull()
                t.column("type", .text).notNull()
                t.column("payload", .text).notNull()
            }

            try db.create(index: "event_agent_ts", on: "event", columns: ["agentId", "ts"])
            try db.create(index: "task_project_status", on: "task", columns: ["projectId", "status"])
            try db.create(index: "agent_task_status", on: "agent", columns: ["taskId", "status"])
        }

        // v2 — add the `attachments` column (JSON array of relative paths)
        migrator.registerMigration("v2_attachments") { db in
            try db.alter(table: "task") { t in
                t.add(column: "attachments", .text)
            }
        }

        // v3 — chat rooms (free-form Claude conversations not tied to a project).
        migrator.registerMigration("v3_chat_room") { db in
            try db.create(table: "chat_room") { t in
                t.primaryKey("id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("model", .text).notNull()
                t.column("sessionId", .text)
                t.column("scratchPath", .text).notNull()
                t.column("costUsd", .double).notNull().defaults(to: 0)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheReadTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheCreationTokens", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "chat_room_updated", on: "chat_room", columns: ["updatedAt"])
        }

        // v4 — per-project auto-approve level (local policy; lives only in the DB,
        // never in the repo's .atelier/config.yml).
        migrator.registerMigration("v4_project_auto_approve") { db in
            try db.alter(table: "project") { t in
                t.add(column: "autoApproveLevel", .text)
            }
        }

        try migrator.migrate(pool)
    }
}
