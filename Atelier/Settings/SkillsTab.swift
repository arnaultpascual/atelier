// SPDX-License-Identifier: MIT
import SwiftUI

/// Skills tab in the global Settings scene. Lists what's bundled in
/// `Atelier.app/Contents/Resources/Skills/` — both the universal set
/// (loaded into every worktree) and the per-profile sets. Each row can be
/// expanded to view the SKILL.md content, since that's the actual contract
/// the worker reads.
struct SkillsTab: View {
    @State private var bundles: [SkillBundle] = []
    @State private var expandedKey: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader

            if let error {
                Text(error)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(bundles) { bundle in
                        bundleSection(bundle)
                    }
                    Spacer(minLength: 12)
                }
            }
        }
        .onAppear(perform: scan)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bundled Skills")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            Text("Copied into `<worktree>/.claude/skills/` at every spawn. Claude auto-discovers them and decides when to apply each based on its frontmatter description. Universal skills load for every project; profile-specific ones only when the project's profile matches.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
                .lineSpacing(2)
        }
    }

    private func bundleSection(_ bundle: SkillBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: bundle.iconSystemName)
                    .foregroundStyle(Color.atelierAccent)
                Text(bundle.label)
                    .font(AtelierFont.callout.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                Spacer()
                Text("\(bundle.skills.count) skill\(bundle.skills.count == 1 ? "" : "s")")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            VStack(spacing: 6) {
                ForEach(bundle.skills) { skill in
                    skillRow(skill)
                }
            }
        }
        .padding(12)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func skillRow(_ skill: SkillEntry) -> some View {
        let isExpanded = expandedKey == skill.id
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: { toggle(skill.id) }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(AtelierFont.captionMono.weight(.semibold))
                            .foregroundStyle(Color.atelierInk)
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(AtelierFont.caption)
                                .foregroundStyle(Color.atelierInkSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(skill.body)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.atelierInk.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 280)
                .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.5), lineWidth: 1))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Color.atelierBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.4), lineWidth: 1))
    }

    private func toggle(_ key: String) {
        expandedKey = (expandedKey == key) ? nil : key
    }

    private func scan() {
        let fm = FileManager.default
        guard let root = Bundle.main.url(forResource: "Skills", withExtension: nil)
                ?? Bundle.main.resourceURL?.appendingPathComponent("Skills") else {
            error = "Skills/ missing from app bundle Resources."
            return
        }
        var out: [SkillBundle] = []

        // Universal bundle (first)
        let universal = root.appendingPathComponent("universal")
        if fm.fileExists(atPath: universal.path) {
            out.append(SkillBundle(
                id: "universal",
                label: "Universal — loaded for every spawn",
                iconSystemName: "globe",
                skills: scanDir(universal)
            ))
        }

        // Per-profile bundles, in the catalog's order so docs are
        // consistent with the rest of the UI.
        let profiles = root.appendingPathComponent("profiles")
        if fm.fileExists(atPath: profiles.path) {
            for profile in ProjectProfile.catalog {
                let dir = profiles.appendingPathComponent(profile.id)
                guard fm.fileExists(atPath: dir.path) else { continue }
                let skills = scanDir(dir)
                if skills.isEmpty { continue }
                out.append(SkillBundle(
                    id: "profile:\(profile.id)",
                    label: "\(profile.name) — loads when project profile = \(profile.id)",
                    iconSystemName: profile.iconSystemName,
                    skills: skills
                ))
            }
        }
        bundles = out
    }

    private func scanDir(_ dir: URL) -> [SkillEntry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out: [SkillEntry] = []
        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let md = child.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: md.path),
                  let body = try? String(contentsOf: md, encoding: .utf8) else { continue }
            let (name, description, content) = SkillEntry.parse(body, fallbackName: child.lastPathComponent)
            out.append(SkillEntry(
                id: "\(dir.lastPathComponent)/\(child.lastPathComponent)",
                name: name,
                description: description,
                body: content
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    struct SkillBundle: Identifiable {
        let id: String
        let label: String
        let iconSystemName: String
        let skills: [SkillEntry]
    }

    struct SkillEntry: Identifiable {
        let id: String
        let name: String
        let description: String
        let body: String

        /// Splits a SKILL.md into frontmatter (name + description) and body.
        /// Frontmatter is YAML between two `---` fences at the very top.
        static func parse(_ source: String, fallbackName: String) -> (name: String, description: String, body: String) {
            var lines = source.components(separatedBy: "\n")
            var name = fallbackName
            var description = ""
            if lines.first == "---" {
                lines.removeFirst()
                var frontEnd = -1
                for (i, l) in lines.enumerated() {
                    if l == "---" { frontEnd = i; break }
                }
                if frontEnd >= 0 {
                    let front = lines.prefix(frontEnd)
                    for raw in front {
                        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2 else { continue }
                        let key = parts[0].trimmingCharacters(in: .whitespaces)
                        let val = parts[1].trimmingCharacters(in: .whitespaces)
                        switch key {
                        case "name": name = val
                        case "description": description = val
                        default: break
                        }
                    }
                    lines.removeFirst(frontEnd + 1)
                }
            }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, description, body)
        }
    }
}
