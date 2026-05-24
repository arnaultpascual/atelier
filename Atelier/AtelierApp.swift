// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct AtelierApp: App {
    @State private var store = AppStore()
    @State private var approvalServer = ApprovalServer()
    @State private var spawner = TaskSpawner()
    @State private var approvalQueue = ApprovalQueue()
    @State private var chatSpawner = ChatSpawner()
    @State private var featureRunner = FeatureBuildRunner()

    var body: some Scene {
        // Primary 3-column shell. The title bar is hidden so our cream background
        // and custom panes own the entire window chrome.
        WindowGroup("Atelier") {
            MainView(store: store, server: approvalServer, spawner: spawner, approvalQueue: approvalQueue, chatSpawner: chatSpawner, featureRunner: featureRunner)
                .frame(minWidth: 1440, minHeight: 760)
                .background(WindowAccessor { window in
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.styleMask.insert(.fullSizeContentView)
                    window.isMovableByWindowBackground = false
                })
                .task {
                    do {
                        try await approvalServer.startIfNeeded()
                    } catch {}
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                QuickSpawnMenuItem()
                SetupAssistantMenuItem()
            }
        }

        Settings {
            SettingsView()
        }

        // Single auxiliary window: lets you spawn a worker without a project/task.
        Window("Quick Spawn", id: WindowID.quickSpawn) {
            QuickSpawnWindowContent(server: approvalServer)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    do {
                        try await approvalServer.startIfNeeded()
                    } catch {}
                }
        }
        .windowResizability(.contentMinSize)
    }
}

enum WindowID {
    static let quickSpawn = "atelier.quick-spawn"
}

/// Helper view so we can read `@Environment(\.openWindow)` from a `.commands { }` block.
private struct QuickSpawnMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Quick Spawn…") {
            openWindow(id: WindowID.quickSpawn)
        }
        .keyboardShortcut("q", modifiers: [.command, .shift])
    }
}

/// Re-opens the first-launch Setup Assistant (claude / git / auth check). Flips a
/// shared AppStorage flag that `MainView` observes to present the sheet.
private struct SetupAssistantMenuItem: View {
    @AppStorage("atelier.onboarding.reopen") private var reopen = false
    var body: some View {
        Button("Setup Assistant…") { reopen = true }
    }
}

/// Each Quick Spawn window owns its own ephemeral AgentState + Orchestrator;
/// they reuse the app-wide ApprovalServer.
private struct QuickSpawnWindowContent: View {
    @Bindable var server: ApprovalServer
    @State private var state = AgentState()
    @State private var orchestrator = Orchestrator()

    var body: some View {
        ContentView(state: state, server: server, orchestrator: orchestrator)
    }
}

/// Lets us reach into the underlying `NSWindow` after the SwiftUI scene materialises,
/// to tune title-bar appearance / full-size content beyond what `.windowStyle` exposes.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window)
            }
        }
    }
}
