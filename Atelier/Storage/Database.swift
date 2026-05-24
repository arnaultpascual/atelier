// SPDX-License-Identifier: MIT
import Foundation
import GRDB
import os

/// Owns the Atelier SQLite database at `~/Library/Application Support/Atelier/atelier.sqlite`.
///
/// WAL mode is enabled for cheap concurrent reads while writes happen serially.
/// Migrations are registered at boot via `Schema.register(_:)`; every launch is idempotent.
final class Database: @unchecked Sendable {
    static let shared = Database()

    private let logger = Logger(subsystem: "app.atelier", category: "db")
    let dbPool: DatabasePool

    private init() {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = supportRoot.appendingPathComponent("Atelier", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create Atelier support directory: \(error)")
        }
        let dbURL = appDir.appendingPathComponent("atelier.sqlite")

        var config = Configuration()
        config.label = "atelier.sqlite"
        config.maximumReaderCount = 4
        config.busyMode = .timeout(5)
        config.publicStatementArguments = false
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { event in
                // os_log signpost trace; keep it cheap
            }
        }
        #endif

        do {
            self.dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        } catch {
            fatalError("Could not open Atelier DB at \(dbURL.path): \(error)")
        }

        do {
            try Schema.migrate(self.dbPool)
            logger.info("DB ready at \(dbURL.path, privacy: .public)")
        } catch {
            fatalError("DB migration failed: \(error)")
        }
    }

    /// Convenience read accessor.
    func read<T: Sendable>(_ block: @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await dbPool.read(block)
    }

    /// Convenience write accessor.
    @discardableResult
    func write<T: Sendable>(_ block: @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await dbPool.write(block)
    }
}
