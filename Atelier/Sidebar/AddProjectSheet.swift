// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Two-step flow: pick a folder → confirm name → Atelier scaffolds `backlog/` +
/// `.atelier/` and adds the project to the DB.
struct AddProjectSheet: View {
    @Bindable var store: AppStore
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var pickedURL: URL?
    @State private var projectName: String = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var report: ProjectScaffolder.Report?
    @State private var gitDetected: Bool = false
    @State private var detectedProfileId: String = ProjectProfile.generic.id
    @State private var detectionHits: [String] = []
    @State private var toolchain: ToolchainChecker.Report?

    private var selectedProfile: ProjectProfile { ProjectProfile.find(id: detectedProfileId) ?? .generic }
    /// Re-probe the toolchain whenever the chosen folder OR mode changes (both feed the check).
    private var toolchainTaskKey: String { "\(pickedURL?.path ?? "")|\(detectedProfileId)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            folderRow

            if let url = pickedURL {
                Divider().background(Color.atelierDivider)
                detailsForm(url: url)
                Divider().background(Color.atelierDivider)
                profileRow
                if !selectedProfile.build.requiredTools.isEmpty {
                    Divider().background(Color.atelierDivider)
                    toolchainPreflight
                }
                Divider().background(Color.atelierDivider)
                preview
            }

            if let error {
                Text(error)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add project")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isWorking)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Color.atelierBackground)
        .foregroundStyle(Color.atelierInk)
        .task(id: toolchainTaskKey) {
            // Preflight the mode's toolchain when a folder + mode are chosen, so the user is warned
            // up front if the tests can't run (non-blocking — they can add anyway and fix later).
            toolchain = nil
            guard let url = pickedURL, !selectedProfile.build.requiredTools.isEmpty else { return }
            toolchain = await ToolchainChecker.check(profile: selectedProfile, projectPath: url.path)
        }
    }

    /// Non-blocking toolchain preflight shown at add time: the readiness panel + a soft "is that
    /// expected?" warning when something required is missing. Adding stays enabled (Add anyway);
    /// Cancel goes back; the per-tool install hints above point at how to fix it.
    private var toolchainPreflight: some View {
        let p = selectedProfile
        return VStack(alignment: .leading, spacing: 8) {
            ToolchainReadinessView(profile: p, report: toolchain)
            if let r = toolchain, !r.ready {
                CalloutBanner(.warning,
                    "Heads up — \(r.missingSummary) missing for the \(p.name) test gate. Is that expected? "
                    + "You can add the project anyway and install the tooling later (hints above), or pick another mode. "
                    + "It only means autopilot can't run this mode's tests until the toolchain is present.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add a project")
                .font(AtelierFont.title)
            HStack(spacing: 6) {
                Circle().fill(Color(hex: workspace.color)).frame(width: 8, height: 8)
                Text("to workspace ")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                + Text(workspace.name)
                    .font(AtelierFont.caption.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
            }
        }
    }

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folder").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.atelierInkSecondary)
                if let url = pickedURL {
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder selected")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Spacer()
                Button(pickedURL == nil ? "Choose…" : "Change…", action: pick)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
            .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
        }
    }

    private func detailsForm(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
            TextField(url.lastPathComponent, text: $projectName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                .onSubmit(submit)
            if !gitDetected {
                HStack(alignment: .top, spacing: 8) {
                    Label("No `.git` directory found — worktrees require git, so initialize a repo here before spawning workers.",
                          systemImage: "exclamationmark.triangle")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Initialize git") { initGit() }
                        .controlSize(.small)
                        .disabled(isWorking)
                }
            }
        }
    }

    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Profile")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                if !detectionHits.isEmpty {
                    Text("detected via \(detectionHits.joined(separator: ", "))")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                }
            }
            Picker("", selection: $detectedProfileId) {
                ForEach(ProjectProfile.catalog) { p in
                    Label(p.name, systemImage: p.iconSystemName).tag(p.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if let p = ProjectProfile.find(id: detectedProfileId) {
                Text("Default model: \(modelLabel(p.defaultModel)) · suggested labels: \(p.suggestedLabels.isEmpty ? "—" : p.suggestedLabels.joined(separator: ", "))")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(p.description)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
            }
        }
    }

    private func modelLabel(_ raw: String) -> String {
        switch raw {
        case "claude-opus-4-8": return "Opus 4.8"
        case "claude-opus-4-8[1m]": return "Opus 4.8 (1M)"
        case "claude-opus-4-7[1m]": return "Opus 4.7 (1M)"
        case "claude-opus-4-7": return "Opus 4.7"
        case "claude-opus-4-6": return "Opus 4.6"
        case "claude-sonnet-4-6": return "Sonnet 4.6"
        case "claude-haiku-4-5-20251001": return "Haiku 4.5"
        default: return raw
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Atelier will do")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            VStack(alignment: .leading, spacing: 4) {
                bulletRow("Create", "backlog/config.yml + backlog/tasks/ + backlog/archive/")
                bulletRow("Create", ".atelier/config.yml")
                bulletRow("Append", "`.atelier-worktrees/` and `.atelier/audit.jsonl` to .gitignore")
                bulletRow("Skip", "anything that already exists — never overwrites your files")
            }
            Text("Convention: tasks are markdown files under `backlog/tasks/<id>.md` — fully compatible with the `backlog` CLI from MrLesk/Backlog.md.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
    }

    private func bulletRow(_ verb: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verb.uppercased())
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierAccent)
                .frame(width: 60, alignment: .leading)
            Text(what)
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInk)
        }
    }

    private var canSubmit: Bool {
        guard let _ = pickedURL else { return false }
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    // MARK: - Actions

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a project folder"
        panel.message = "Atelier will scaffold backlog/ + .atelier/ inside this folder."
        if panel.runModal() == .OK, let url = panel.url {
            pickedURL = url
            if projectName.isEmpty {
                projectName = url.lastPathComponent
            }
            gitDetected = FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".git").path
            )
            let detection = ProjectProfileDetector.detect(at: url.path)
            detectedProfileId = detection.profile.id
            detectionHits = detection.hits
            // Reject duplicates
            if store.projectByPath(url.path) != nil {
                error = "A project at \(url.path) is already added."
                pickedURL = nil
                projectName = ""
            } else {
                error = nil
            }
        }
    }

    private func submit() {
        guard canSubmit, !isWorking, let url = pickedURL else { return }
        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        error = nil
        Task {
            do {
                let scaffoldReport = try ProjectScaffolder.scaffold(at: url.path, projectName: trimmedName)
                let profile = ProjectProfile.find(id: detectedProfileId) ?? .generic
                _ = try await store.addProject(workspace: workspace,
                                               name: trimmedName,
                                               path: url.path,
                                               profileId: profile.id,
                                               defaultModel: profile.defaultModel)
                report = scaffoldReport
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func initGit() {
        guard let url = pickedURL else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await GitService.initRepo(path: url.path)
                gitDetected = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
