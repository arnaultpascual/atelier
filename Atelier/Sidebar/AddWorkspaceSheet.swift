// SPDX-License-Identifier: MIT
import SwiftUI

struct AddWorkspaceSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedColor: String = Workspace.suggestedColors[0]
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New workspace")
                    .font(AtelierFont.title)
                Text("A workspace groups projects by client or context.\nPick a name and a colour that helps you spot it in the sidebar.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                TextField("e.g. Acme, Personal, Open Source", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                    .onSubmit(submit)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Colour").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                HStack(spacing: 8) {
                    ForEach(Workspace.suggestedColors, id: \.self) { hex in
                        ColorDot(hex: hex, isSelected: hex == selectedColor)
                            .onTapGesture { selectedColor = hex }
                    }
                    Spacer()
                }
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
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Color.atelierBackground)
        .foregroundStyle(Color.atelierInk)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreating else { return }
        isCreating = true
        error = nil
        Task {
            do {
                _ = try await store.createWorkspace(name: trimmed, color: selectedColor)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCreating = false
            }
        }
    }
}

private struct ColorDot: View {
    let hex: String
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: hex)).frame(width: 26, height: 26)
            if isSelected {
                Circle()
                    .stroke(Color.atelierInk, lineWidth: 2)
                    .frame(width: 32, height: 32)
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
}
