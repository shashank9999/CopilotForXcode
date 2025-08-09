import SwiftUI
import Client
import HostApp
import LaunchAgentManager
import SharedUIComponents
import UpdateChecker
import XPCShared
import HostAppActivator
import ComposableArchitecture

struct VisualEffect: NSViewRepresentable {
  func makeNSView(context: Self.Context) -> NSView { return NSVisualEffectView() }
  func updateNSView(_ nsView: NSView, context: Context) { }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var permissionAlertShown = false
    
    // Launch modes supported by the app
    enum LaunchMode {
        case chat
        case settings
        case mcp
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 13.0, *) {
            checkBackgroundPermissions()
        }
        
        let launchMode = determineLaunchMode()
        handleLaunchMode(launchMode)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            checkBackgroundPermissions()
        }
        
        let launchMode = determineLaunchMode()
        handleLaunchMode(launchMode)
        return true
    }
    
    // MARK: - Helper Methods
    
    private func determineLaunchMode() -> LaunchMode {
        let launchArgs = CommandLine.arguments
        if launchArgs.contains("--settings") {
            return .settings
        } else if launchArgs.contains("--mcp") {
            return .mcp
        } else {
            return .chat
        }
    }
    
    private func handleLaunchMode(_ mode: LaunchMode) {
        switch mode {
        case .settings:
            openSettings()
        case .mcp:
            openMCPSettings()
        case .chat:
            openChat()
        }
    }
    
    private func openSettings() {
        DispatchQueue.main.async {
            activateAndOpenSettings()
        }
    }
    
    private func openChat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task {
                let service = try? getService()
                try? await service?.openChat()
            }
        }
    }
    
    private func openMCPSettings() {
        DispatchQueue.main.async {
            activateAndOpenSettings()
            hostAppStore.send(.setActiveTab(2))
        }
    }
    
    @available(macOS 13.0, *)
    private func checkBackgroundPermissions() {
        Task {
            // Direct check of permission status
            let launchAgentManager = LaunchAgentManager()
            let isPermissionGranted = await launchAgentManager.isBackgroundPermissionGranted()
            
            if !isPermissionGranted {
                // Only show alert if permission isn't granted
                DispatchQueue.main.async {
                    if !self.permissionAlertShown {
                        showBackgroundPermissionAlert()
                        self.permissionAlertShown = true
                    }
                }
            } else {
                // Permission is granted, reset flag
                self.permissionAlertShown = false
            }
        }
    }
    
    // MARK: - Application Termination
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Immediately terminate extension service if it's running
        if let extensionService = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "\(Bundle.main.bundleIdentifier!).ExtensionService"
        }) {
            extensionService.terminate()
        }
        
        // Start cleanup in background without waiting
        Task {
            let quitTask = Task {
                let service = try? getService()
                try? await service?.quitService()
            }
            
            // Wait just a tiny bit to allow cleanup to start
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        
        return .terminateLater
    }
    
    func applicationWillTerminate(_ notification: Notification) {        
        if let extensionService = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "\(Bundle.main.bundleIdentifier!).ExtensionService"
        }) {
            extensionService.terminate()
        }
    }
}

class AppUpdateCheckerDelegate: UpdateCheckerDelegate {
    func prepareForRelaunch(finish: @escaping () -> Void) {
        Task {
            let service = try? getService()
            try? await service?.quitService()
            finish()
        }
    }
}

@main
struct CopilotForXcodeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    
    init() {
        UserDefaults.setupDefaultSettings()
        
        Task {
            await hostAppStore
                .send(.general(.setupLaunchAgentIfNeeded))
                .finish()
        }
        
        DistributedNotificationCenter.default().addObserver(
            forName: .openSettingsWindowRequest,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                activateAndOpenSettings()
            }
        }
        
        DistributedNotificationCenter.default().addObserver(
            forName: .openMCPSettingsWindowRequest,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                activateAndOpenSettings()
                hostAppStore.send(.setActiveTab(2))
            }
        }
    }

    var body: some Scene {
        WithPerceptionTracking {
            Settings {
                TabContainer()
                    .frame(minWidth: 800, minHeight: 600)
                    .background(VisualEffect().ignoresSafeArea())
                    .environment(\.updateChecker, UpdateChecker(
                        hostBundle: Bundle.main,
                        checkerDelegate: AppUpdateCheckerDelegate()
                    ))
            }
        }
    }
}

@MainActor 
func activateAndOpenSettings() {
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14.0, *) {
        let environment = SettingsEnvironment()
        environment.open()
    } else if #available(macOS 13.0, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

var isPreview: Bool { ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
