// SPDX-License-Identifier: MIT
import Foundation

/// Computes "execution waves" (rounds) from a set of tasks' `dependsOn` graph against the
/// live status of all tasks in the project.
///
/// Round 1 = tasks whose every dependency is already `.done` (runnable right now); round N =
/// tasks whose deepest still-unmet dependency lands in round N-1.
///
/// Single source of truth shared by the Kanban UI (`BacklogPane`) and the autopilot
/// (`FeatureBuildRunner`) so they never disagree about what can run. (The Fill-Kanban sheet
/// keeps its own variant — it operates on un-persisted `TaskDraft`s with no status.)
enum ExecutionPlanner {
    /// - Parameters:
    ///   - tasks: the candidate set to group (typically a project's To Do column).
    ///   - allTasks: every task in the project, used to resolve dependency status.
    static func waves(tasks: [AtelierTask],
                      allTasks: [AtelierTask]) -> [(round: Int, tasks: [AtelierTask])] {
        let statusById = Dictionary(allTasks.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        let candidateById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cache: [String: Int] = [:]
        var visiting: Set<String> = []
        func depth(_ t: AtelierTask) -> Int {
            if let c = cache[t.id] { return c }
            if visiting.contains(t.id) { return 0 }   // cycle guard
            visiting.insert(t.id)
            let unmet = t.dependsOn.filter { $0 != t.id && (statusById[$0] ?? .done) != .done }
            let result = unmet.isEmpty ? 0 : 1 + (unmet.map { candidateById[$0].map(depth) ?? 0 }.max() ?? 0)
            visiting.remove(t.id)
            cache[t.id] = result
            return result
        }
        let grouped = Dictionary(grouping: tasks) { depth($0) }
        return grouped.keys.sorted().map { (round: $0 + 1, tasks: grouped[$0]!) }
    }

    /// The subset of `tasks` that can run right now — round 1 (every dependency `.done`).
    static func runnableNow(tasks: [AtelierTask], allTasks: [AtelierTask]) -> [AtelierTask] {
        waves(tasks: tasks, allTasks: allTasks).first(where: { $0.round == 1 })?.tasks ?? []
    }
}
