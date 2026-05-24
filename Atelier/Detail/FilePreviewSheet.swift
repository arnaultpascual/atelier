// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// In-app preview of a file from a task's worktree. Renders markdown nicely, shows
/// images inline, and falls back to monospaced source for code/text.
struct FilePreviewSheet: View {
    let projectPath: String
    let taskId: String
    let relativePath: String
    let changeStatus: GitService.ChangeStatus
    let onClose: () -> Void

    @State private var data: Data?
    @State private var loadError: String?
    @State private var renderMode: RenderMode = .auto

    enum RenderMode: String, CaseIterable {
        case auto, rendered, source
        var label: String {
            switch self {
            case .auto: return "Auto"
            case .rendered: return "Rendered"
            case .source: return "Source"
            }
        }
    }

    private var filename: String { (relativePath as NSString).lastPathComponent }
    private var ext: String { (filename as NSString).pathExtension.lowercased() }
    private var contentType: UTType? { ext.isEmpty ? nil : UTType(filenameExtension: ext) }
    private var isMarkdown: Bool { ["md", "markdown", "mdx"].contains(ext) }
    private var isImage: Bool { contentType?.conforms(to: .image) ?? false }
    private var isPDF: Bool { contentType?.conforms(to: .pdf) ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.atelierDivider)
            body_
            Divider().background(Color.atelierDivider)
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .background(Color.atelierBackground)
        .foregroundStyle(Color.atelierInk)
        .task { load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle().fill(Color.atelierAccentSoft).frame(width: 32, height: 32)
                Image(systemName: iconSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.atelierAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(filename)
                        .font(AtelierFont.subtitle)
                    statusPill
                }
                Text(relativePath)
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if isMarkdown {
                Picker("", selection: $renderMode) {
                    ForEach(RenderMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var statusPill: some View {
        Text(changeStatus.label)
            .font(AtelierFont.eyebrow)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusColor: Color {
        switch changeStatus {
        case .added, .untracked: return Palette.success
        case .modified: return Color.atelierAccent
        case .deleted: return Palette.error
        case .renamed: return Palette.warning
        case .other: return Color.atelierInkSecondary
        }
    }

    private var iconSymbol: String {
        if isMarkdown { return "doc.richtext" }
        if isImage { return "photo" }
        if isPDF { return "doc.text" }
        if let ct = contentType {
            if ct.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
            if ct.conforms(to: .plainText) { return "doc.plaintext" }
        }
        return "doc"
    }

    // MARK: Body

    @ViewBuilder
    private var body_: some View {
        if let data {
            content(for: data)
        } else if let err = loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.warning)
                Text("Could not read file")
                    .font(AtelierFont.subtitle)
                Text(err)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading file…")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(for data: Data) -> some View {
        if isImage, let img = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            }
            .background(Color.atelierBackground)
        } else if isPDF {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 40))
                    .foregroundStyle(Color.atelierInkSecondary)
                Text("PDF previews aren't built in yet.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                Button(action: openInDefaultApp) {
                    Label("Open in default app", systemImage: "arrow.up.forward.app")
                        .font(AtelierFont.caption.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = String(data: data, encoding: .utf8) {
            textBody(text: text)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "lock.doc").font(.system(size: 30))
                    .foregroundStyle(Color.atelierInkSecondary)
                Text("Binary file — \(byteCountLabel(data.count))")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                Button("Open in default app", action: openInDefaultApp)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func textBody(text: String) -> some View {
        if isMarkdown && renderMode != .source {
            MarkdownRendered(source: text)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.atelierBackground)
        }
    }

    private func byteCountLabel(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: revealInFinder) {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(AtelierFont.caption.weight(.medium))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()
            Button(action: openInDefaultApp) {
                Label("Open in default app", systemImage: "arrow.up.forward.app")
                    .font(AtelierFont.caption.weight(.medium))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()
            Spacer()
            Button("Close", action: onClose)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func load() {
        if let data = GitService.readWorktreeFile(projectPath: projectPath,
                                                  taskId: taskId,
                                                  relativePath: relativePath) {
            self.data = data
        } else {
            self.loadError = "File not found in worktree (deleted, perhaps?)"
        }
    }

    private var absoluteURL: URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".atelier-worktrees")
            .appendingPathComponent(taskId)
            .appendingPathComponent(relativePath)
    }

    private func revealInFinder() {
        let url = absoluteURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openInDefaultApp() {
        let url = absoluteURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Markdown rendering

private struct MarkdownRendered: View {
    let source: String

    var body: some View {
        ScrollView(.vertical) {
            MarkdownView(source: source)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.atelierBackground)
    }

}
