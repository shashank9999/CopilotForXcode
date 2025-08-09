import AppKit
import Foundation
import Logger
import XPCShared

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: CommunicationBridgeXPCServiceProtocol.self
        )

        let exportedObject = XPCService()
        newConnection.exportedObject = exportedObject
        newConnection.resume()

        Logger.communicationBridge.info("Accepted new connection.")

        return true
    }
}

class XPCService: CommunicationBridgeXPCServiceProtocol {
    static let eventHandler = EventHandler()

    func launchExtensionServiceIfNeeded(
        withReply reply: @escaping (NSXPCListenerEndpoint?) -> Void
    ) {
        Task {
            await Self.eventHandler.launchExtensionServiceIfNeeded(withReply: reply)
        }
    }

    func quit(withReply reply: @escaping () -> Void) {
        Task {
            await Self.eventHandler.quit(withReply: reply)
        }
    }

    func updateServiceEndpoint(
        endpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping () -> Void
    ) {
        Task {
            await Self.eventHandler.updateServiceEndpoint(endpoint: endpoint, withReply: reply)
        }
    }
}

actor EventHandler {
    var endpoint: NSXPCListenerEndpoint?
    let launcher = ExtensionServiceLauncher()
    var exitTask: Task<Void, Error>?

    init() {
        Task { await rescheduleExitTask() }
    }

    func launchExtensionServiceIfNeeded(
        withReply reply: @escaping (NSXPCListenerEndpoint?) -> Void
    ) async {
        rescheduleExitTask()
        #if DEBUG
        if let endpoint, !(await testXPCListenerEndpoint(endpoint)) {
            self.endpoint = nil
        }
        reply(endpoint)
        #else
        if await launcher.isApplicationValid {
            Logger.communicationBridge.info("Service app is still valid")
            reply(endpoint)
        } else {
            endpoint = nil
            await launcher.launch()
            reply(nil)
        }
        #endif
    }

    func quit(withReply reply: () -> Void) {
        Logger.communicationBridge.info("Exiting service.")
        listener.invalidate()
        exit(0)
    }

    func updateServiceEndpoint(endpoint: NSXPCListenerEndpoint, withReply reply: () -> Void) {
        rescheduleExitTask()
        self.endpoint = endpoint
        reply()
    }

    /// The bridge will kill itself when it's not used for a period.
    /// It's fine that the bridge is killed because it will be launched again when needed.
    private func rescheduleExitTask() {
        exitTask?.cancel()
        exitTask = Task {
            #if DEBUG
            try await Task.sleep(nanoseconds: 60_000_000_000)
            Logger.communicationBridge.info("Exit will be called in release build.")
            #else
            try await Task.sleep(nanoseconds: 1_800_000_000_000)
            Logger.communicationBridge.info("Exiting service.")
            listener.invalidate()
            exit(0)
            #endif
        }
    }
}

actor ExtensionServiceLauncher {
    let appIdentifier = bundleIdentifierBase.appending(".ExtensionService")
    let appURL = Bundle.main.bundleURL.appendingPathComponent(
        "GitHub Copilot for Xcode Extension.app"
    )
    var isLaunching: Bool = false
    var application: NSRunningApplication?
    var isApplicationValid: Bool {
        guard let application else { return false }
        if application.isTerminated { return false }
        let identifier = application.processIdentifier
        if let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == identifier
        }) {
            Logger.communicationBridge.info(
                "Service app found: \(application.processIdentifier) \(String(describing: application.bundleIdentifier))"
            )
            return true
        }
        return false
    }

    func launch() {
        guard !isLaunching else { return }
        isLaunching = true

        Logger.communicationBridge.info("Launching extension service app.")
        
        // First check if the app is already running
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { 
            $0.bundleIdentifier == appIdentifier 
        }) {
            Logger.communicationBridge.info("Extension service app already running with PID: \(runningApp.processIdentifier)")
            self.application = runningApp
            self.isLaunching = false
            return
        }
        
        // Implement a retry mechanism with exponential backoff
        Task {
            var retryCount = 0
            let maxRetries = 3
            var success = false
            
            while !success && retryCount < maxRetries {
                do {
                    // Add a delay between retries with exponential backoff
                    if retryCount > 0 {
                        let delaySeconds = pow(2.0, Double(retryCount - 1)) 
                        Logger.communicationBridge.info("Retrying launch after \(delaySeconds) seconds (attempt \(retryCount + 1) of \(maxRetries))")
                        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    }
                    
                    // Use a task-based approach for launching with timeout
                    let launchTask = Task<NSRunningApplication?, Error> { () -> NSRunningApplication? in
                        return await withCheckedContinuation { continuation in
                            NSWorkspace.shared.openApplication(
                                at: appURL,
                                configuration: {
                                    let configuration = NSWorkspace.OpenConfiguration()
                                    configuration.createsNewApplicationInstance = false
                                    configuration.addsToRecentItems = false
                                    configuration.activates = false
                                    return configuration
                                }()
                            ) { app, error in
                                if let error = error {
                                    continuation.resume(returning: nil)
                                } else {
                                    continuation.resume(returning: app)
                                }
                            }
                        }
                    }
                    
                    // Set a timeout for the launch operation
                    let timeoutTask = Task {
                        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                        return
                    }
                    
                    // Wait for either the launch or the timeout
                    let app = try await withTaskCancellationHandler {
                        try await launchTask.value ?? nil
                    } onCancel: {
                        launchTask.cancel()
                    }
                    
                    // Cancel the timeout task
                    timeoutTask.cancel()
                    
                    if let app = app {
                        // Success!
                        self.application = app
                        success = true
                        break
                    } else {
                        // App is nil, retry
                        retryCount += 1
                        Logger.communicationBridge.info("Launch attempt \(retryCount) failed, app is nil")
                    }
                } catch {
                    retryCount += 1
                    Logger.communicationBridge.error("Error during launch attempt \(retryCount): \(error.localizedDescription)")
                }
            }
            
            // Double-check we have a valid application
            if !success && self.application == nil {
                // After all retries, check once more if the app is running (it might have launched but we missed the callback)
                if let runningApp = NSWorkspace.shared.runningApplications.first(where: { 
                    $0.bundleIdentifier == appIdentifier 
                }) {
                    Logger.communicationBridge.info("Found running extension service after retries: \(runningApp.processIdentifier)")
                    self.application = runningApp
                    success = true
                } else {
                    Logger.communicationBridge.info("Failed to launch extension service after \(maxRetries) attempts")
                }
            }
            
            self.isLaunching = false
        }
    }
}

