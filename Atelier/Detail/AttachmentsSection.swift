// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Compact attachments section for the task inspector. Lists existing attachments
/// (icon + name + size + remove on hover), exposes an `+ Add` affordance, and
/// accepts drag-drop of any file via `.onDrop`.
struct AttachmentsSection: View {
    @Bindable var store: AppStore
    let task: AtelierTask

    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    private var project: Project? { store.projectByID(task.projectId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            if let errorMessage {
                Text(errorMessage)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("ATTACHMENTS")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            if !task.attachments.isEmpty {
                Text("\(task.attachments.count)")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            Button(action: pick) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                    Text("Add").font(AtelierFont.caption.weight(.medium))
                }
                .foregroundStyle(Color.atelierAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Add files to this task — they're copied into `.atelier/attachments/\(task.id)/` and gitignored.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if task.attachments.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.system(size: 11))
                .foregroundStyle(Color.atelierInkSecondary)
            Text(isDropTargeted ? "Drop to attach" : "Drag files here or click + Add")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .fill(isDropTargeted ? Color.atelierAccentSoft.opacity(0.5) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .strokeBorder(
                    isDropTargeted ? Color.atelierAccent : Color.atelierDivider.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(task.attachments, id: \.self) { rel in
                AttachmentRow(
                    info: AttachmentService.info(
                        relativePath: rel,
                        projectRoot: project?.path ?? ""
                    ),
                    onReveal: { revealInFinder(rel) },
                    onRemove: { remove(rel) }
                )
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .fill(isDropTargeted ? Color.atelierAccentSoft.opacity(0.5) : Color.atelierSurface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .stroke(isDropTargeted ? Color.atelierAccent : Color.atelierDivider.opacity(0.6),
                        lineWidth: isDropTargeted ? 1.5 : 1)
        )
    }

    // MARK: - Actions

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach files to \(task.id)"
        panel.message = "Atelier copies the files into `.atelier/attachments/\(task.id)/`."
        if panel.runModal() == .OK {
            for url in panel.urls {
                attach(url)
            }
        }
    }

    private func attach(_ url: URL) {
        errorMessage = nil
        Task {
            do {
                _ = try await store.attachFile(to: task, sourceURL: url)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func remove(_ relativePath: String) {
        errorMessage = nil
        Task {
            do {
                _ = try await store.detachFile(from: task, relativePath: relativePath)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func revealInFinder(_ relativePath: String) {
        guard let project else { return }
        let url = AttachmentService.absoluteURL(relativePath: relativePath, projectRoot: project.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var anyHandled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            anyHandled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in attach(url) }
            }
        }
        return anyHandled
    }
}

// MARK: - Row

private struct AttachmentRow: View {
    let info: AttachmentService.Info
    let onReveal: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onReveal) {
            HStack(spacing: 8) {
                Image(systemName: info.iconSymbol)
                    .font(.system(size: 12))
                    .foregroundStyle(info.exists ? Color.atelierAccent : Color.atelierInkSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.filename)
                        .font(AtelierFont.callout)
                        .foregroundStyle(info.exists ? Color.atelierInk : Color.atelierInkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if info.exists {
                            Text(info.displaySize)
                                .font(AtelierFont.eyebrow)
                                .foregroundStyle(Color.atelierInkSecondary)
                        } else {
                            Text("missing")
                                .font(AtelierFont.eyebrow)
                                .foregroundStyle(Palette.error)
                        }
                        if let ct = info.contentType {
                            Text("· \(ct.preferredFilenameExtension ?? ct.identifier)")
                                .font(AtelierFont.eyebrow)
                                .foregroundStyle(Color.atelierInkSecondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                if hover {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.atelierInkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove attachment (file is deleted from `.atelier/attachments/`)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hover ? Color.atelierBackground.opacity(0.6) : Color.clear)
        )
        .onHover { hover = $0 }
        .help(info.exists ? "Reveal in Finder" : "File is missing from disk")
    }
}
