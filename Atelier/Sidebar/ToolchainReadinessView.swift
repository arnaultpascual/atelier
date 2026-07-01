// SPDX-License-Identifier: MIT
import SwiftUI

/// Per-mode toolchain readiness panel — whether Atelier can actually run this mode's tests
/// (JDK / Android SDK / Gradle wrapper / .NET SDK …). Shared by `ProjectSettingsSheet` (shown
/// before launching) and `AddProjectSheet` (preflight at add time) so the readiness UI lives in
/// one place. Pure presentation: the caller owns running `ToolchainChecker.check` and hands in the
/// `report` (nil = still probing). Renders nothing when the mode declares no required tools.
struct ToolchainReadinessView: View {
    let profile: ProjectProfile
    let report: ToolchainChecker.Report?

    var body: some View {
        if !profile.build.requiredTools.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("TOOLCHAIN").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                    if let r = report {
                        Text(r.ready ? "ready" : "missing: \(r.missingSummary)")
                            .font(AtelierFont.eyebrow)
                            .foregroundStyle(r.ready ? Palette.success : Palette.warning)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let r = report {
                    ForEach(r.tools) { t in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: t.present ? "checkmark.circle.fill" : (t.required ? "xmark.octagon.fill" : "minus.circle"))
                                .font(.system(size: 9))
                                .foregroundStyle(t.present ? Palette.success : (t.required ? Palette.error : Color.atelierInkSecondary))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(t.label)\(t.required ? "" : " (optional)")")
                                    .font(AtelierFont.caption).foregroundStyle(Color.atelierInk)
                                Text(t.present ? t.detail : t.installHint)
                                    .font(AtelierFont.eyebrow)
                                    .foregroundStyle(Color.atelierInkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}
