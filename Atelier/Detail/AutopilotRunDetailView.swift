// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Compact card shown at the top of the Done column: one autopilot run grouped as a
/// single entity (its integration branch + tasks). Tap to open the run detail.
struct AutopilotRunCard: View {
    let record: AutopilotRunRecord
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "infinity")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atelierAccent)
                    Text("Autopilot run")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                    Spacer()
                    Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Text(record.integrationBranch)
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text("\(record.mergedCount) merged")
                        .foregroundStyle(Palette.success)
                    if record.blockedCount > 0 {
                        Text("· \(record.blockedCount) blocked")
                            .foregroundStyle(Palette.warning)
                    }
                    Spacer()
                    if record.totalCostUsd > 0 {
                        Text(String(format: "$%.4f", record.totalCostUsd))
                            .foregroundStyle(Color.atelierAccent)
                    }
                }
                .font(AtelierFont.captionMono)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.atelierAccentSoft.opacity(hover ? 0.5 : 0.3),
                        in: RoundedRectangle(cornerRadius: AtelierCorner.card))
            .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card)
                .stroke(Color.atelierAccent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open this autopilot run — combined diff + merge the whole branch.")
    }
}

/// The run as one entity: its tasks, the combined diff of the integration branch vs
/// the base it was cut from, and a one-shot "Merge the whole branch into <base>".
struct AutopilotRunDetailView: View {
    let record: AutopilotRunRecord
    let project: Project
    /// True while an autopilot run is currently active for this project — merging /
    /// dismissing is disabled then (it would fight the live run's checkout).
    let autopilotActive: Bool
    let onClose: () -> Void
    let onChanged: () -> Void

    @State private var stat: GitService.DiffStat?
    @State private var files: [GitService.ChangedFile] = []
    @State private var loadingDiff = true
    @State private var diffError: String?
    @State private var merging = false
    @State private var mergeError: String?
    @State private var mergedOk = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if mergedOk {
                        CalloutBanner(.info, "Merged \(record.integrationBranch) into \(record.baseBranch). You're now on \(record.baseBranch).")
                    }
                    if let mergeError {
                        CalloutBanner(.danger, mergeError)
                    }
                    tasksSection
                    diffSection
                }
                .padding(24)
            }
            Divider().background(Color.atelierDivider).opacity(0.6)
            footer
        }
        .frame(minWidth: 720, idealWidth: 880, maxWidth: 1300,
               minHeight: 540, idealHeight: 720, maxHeight: 1200)
        .background(Color.atelierBackground)
        .task { await loadDiff() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "infinity").foregroundStyle(Color.atelierAccent)
                    Text("Autopilot run")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                    Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Text(record.integrationBranch)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled)
                Text("Cut from \(record.baseBranch) · \(record.mergedCount) merged\(record.blockedCount > 0 ? " · \(record.blockedCount) blocked" : "") · \(String(format: "$%.4f", record.totalCostUsd))")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("TASKS IN THIS RUN")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(record.tasks) { t in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: t.status))
                            .font(.system(size: 11))
                            .foregroundStyle(color(for: t.status))
                            .frame(width: 16)
                        Text(t.id)
                            .font(AtelierFont.eyebrow)
                            .foregroundStyle(Color.atelierInkSecondary)
                        Text(t.title)
                            .font(AtelierFont.caption)
                            .foregroundStyle(Color.atelierInk)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let reason = t.reason, t.status == .blocked {
                            Text(reason)
                                .font(AtelierFont.eyebrow)
                                .foregroundStyle(Palette.warning)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 280, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
            }
            .padding(6)
            .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
        }
    }

    // MARK: Combined diff

    @ViewBuilder
    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel("COMBINED DIFF")
                Text("\(record.baseBranch)…\(record.integrationBranch)")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let stat, !stat.isEmpty {
                    Text("+\(stat.insertions)").foregroundStyle(Palette.success)
                    Text("−\(stat.deletions)").foregroundStyle(Palette.error)
                }
            }
            .font(AtelierFont.captionMono.weight(.semibold))

            if loadingDiff {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading git diff…").font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                }
            } else if let diffError {
                Text(diffError).font(AtelierFont.caption).foregroundStyle(Palette.warning).lineLimit(3)
            } else if files.isEmpty {
                Text("No file changes on this branch vs \(record.baseBranch).")
                    .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { f in
                        HStack(spacing: 8) {
                            Text(f.status.symbol)
                                .font(AtelierFont.captionMono.weight(.bold))
                                .foregroundStyle(symbolColor(f.status))
                                .frame(width: 14)
                            Text(f.path)
                                .font(AtelierFont.captionMono)
                                .foregroundStyle(Color.atelierInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Text(f.status.label)
                                .font(AtelierFont.eyebrow)
                                .foregroundStyle(Color.atelierInkSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
                .padding(6)
                .background(Color.atelierBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
            }
        }
    }

    // MARK: Footer (actions)

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Copy merge command") { copy(mergeCommand) }
                Button("Copy branch name") { copy(record.integrationBranch) }
                Button("Reveal repo in Finder", action: revealRepo)
                Divider()
                Button("Remove from list", role: .destructive) {
                    AutopilotRunStore.remove(id: record.id, projectPath: project.path)
                    onChanged(); onClose()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if autopilotActive {
                Text("An autopilot run is active — merge once it finishes.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            Button(action: mergeIntoBase) {
                HStack(spacing: 5) {
                    if merging { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.triangle.merge").font(.system(size: 10, weight: .semibold)) }
                    Text(merging ? "Merging…" : "Merge into \(record.baseBranch)")
                        .font(.system(.callout).weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(merging || mergedOk || autopilotActive)
            .help("Check out \(record.baseBranch) and merge the whole run branch into it (--no-ff). Conflicts abort cleanly.")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Derived / actions

    private var mergeCommand: String {
        "git -C \"\(project.path)\" checkout \(record.baseBranch) && git -C \"\(project.path)\" merge --no-ff \(record.integrationBranch)"
    }

    private func loadDiff() async {
        loadingDiff = true; diffError = nil
        do {
            let (s, f) = try await GitService.runDiff(projectPath: project.path,
                                                      base: record.baseBranch,
                                                      branch: record.integrationBranch)
            await MainActor.run { stat = s; files = f; loadingDiff = false }
        } catch {
            await MainActor.run { diffError = error.localizedDescription; loadingDiff = false }
        }
    }

    private func mergeIntoBase() {
        merging = true; mergeError = nil
        Task {
            do {
                try await GitService.checkoutBranch(projectPath: project.path, branch: record.baseBranch)
                let result = try await GitService.merge(into: record.baseBranch,
                                                        branch: record.integrationBranch,
                                                        projectPath: project.path)
                switch result {
                case .clean, .upToDate:
                    await MainActor.run { mergedOk = true; merging = false }
                case .conflict(let files):
                    try? await GitService.abortMerge(projectPath: project.path)
                    let names = files.prefix(3).joined(separator: ", ")
                    await MainActor.run {
                        mergeError = "Conflicts in \(files.count) file\(files.count == 1 ? "" : "s") (\(names)\(files.count > 3 ? "…" : "")). Aborted — use the copy command to merge and resolve by hand."
                        merging = false
                    }
                }
            } catch {
                await MainActor.run { mergeError = error.localizedDescription; merging = false }
            }
        }
    }

    private func revealRepo() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func icon(for s: AutopilotRunRecord.TaskOutcome.Status) -> String {
        switch s {
        case .merged: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .incomplete: return "circle.dotted"
        }
    }
    private func color(for s: AutopilotRunRecord.TaskOutcome.Status) -> Color {
        switch s {
        case .merged: return Palette.success
        case .blocked: return Palette.warning
        case .incomplete: return Color.atelierInkSecondary
        }
    }
    private func symbolColor(_ s: GitService.ChangeStatus) -> Color {
        switch s {
        case .added, .untracked: return Palette.success
        case .modified: return Color.atelierAccent
        case .deleted: return Palette.error
        case .renamed: return Palette.warning
        case .other: return Color.atelierInkSecondary
        }
    }
}
