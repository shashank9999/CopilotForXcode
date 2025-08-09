import Client
import ComposableArchitecture
import SwiftUI
import Toast
import XcodeInspector

struct ChatSection: View {
    @AppStorage(\.autoAttachChatToXcode) var autoAttachChatToXcode
    
    var body: some View {
        SettingsSection(title: "Chat Settings") {
            // Auto Attach toggle
            SettingsToggle(
                title: "Auto-attach Chat Window to Xcode", 
                isOn: $autoAttachChatToXcode
            )
            
            Divider()
            
            // Response language picker
            ResponseLanguageSetting()
                .padding(SettingsToggle.defaultPadding)
            
            Divider()
            
            // Custom instructions
            CustomInstructionSetting()
                .padding(SettingsToggle.defaultPadding)
        }
    }
}

struct ResponseLanguageSetting: View {
    @AppStorage(\.chatResponseLocale) var chatResponseLocale

    // Locale codes mapped to language display names
    // reference: https://code.visualstudio.com/docs/configure/locales#_available-locales
    private let localeLanguageMap: [String: String] = [
        "en": "English",
        "zh-cn": "Chinese, Simplified",
        "zh-tw": "Chinese, Traditional",
        "fr": "French",
        "de": "German",
        "it": "Italian",
        "es": "Spanish",
        "ja": "Japanese",
        "ko": "Korean",
        "ru": "Russian",
        "pt-br": "Portuguese (Brazil)",
        "tr": "Turkish",
        "pl": "Polish",
        "cs": "Czech",
        "hu": "Hungarian"
    ]
    
    var selectedLanguage: String {
        if chatResponseLocale == "" {
            return "English"
        }
        
        return localeLanguageMap[chatResponseLocale] ?? "English"
    }

    // Display name to locale code mapping (for the picker UI)
    var sortedLanguageOptions: [(displayName: String, localeCode: String)] {
        localeLanguageMap.map { (displayName: $0.value, localeCode: $0.key) }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        WithPerceptionTracking {
            HStack {
                VStack(alignment: .leading) {
                    Text("Response Language")
                        .font(.body)
                    Text("This change applies only to new chat sessions. Existing ones won’t be impacted.")
                        .font(.footnote)
                }

                Spacer()

                Picker("", selection: $chatResponseLocale) {
                    ForEach(sortedLanguageOptions, id: \.localeCode) { option in
                        Text(option.displayName).tag(option.localeCode)
                    }
                }
                .frame(maxWidth: 200, alignment: .leading)
            }
        }
    }
}

struct CustomInstructionSetting: View {
    @State var isGlobalInstructionsViewOpen = false
    @Environment(\.toast) var toast

    var body: some View {
        WithPerceptionTracking {
            HStack {
                VStack(alignment: .leading) {
                    Text("Custom Instructions")
                        .font(.body)
                    Text("Configure custom instructions for GitHub Copilot to follow during chat sessions.")
                        .font(.footnote)
                }

                Spacer()

                Button("Current Workspace") {
                    openCustomInstructions()
                }

                Button("Global") {
                    isGlobalInstructionsViewOpen = true
                }
            }
            .sheet(isPresented: $isGlobalInstructionsViewOpen) {
                GlobalInstructionsView(isOpen: $isGlobalInstructionsViewOpen)
            }
        }
    }

    func openCustomInstructions() {
        Task {
            let service = try? getService()
            let inspectorData = try? await service?.getXcodeInspectorData()
            var currentWorkspace: URL? = nil
            if let url = inspectorData?.realtimeActiveWorkspaceURL, let workspaceURL = URL(string: url), workspaceURL.path != "/" {
                currentWorkspace = workspaceURL
            } else if let url = inspectorData?.latestNonRootWorkspaceURL {
                currentWorkspace = URL(string: url)
            }

            // Open custom instructions for the current workspace
            if let workspaceURL = currentWorkspace, let projectURL = WorkspaceXcodeWindowInspector.extractProjectURL(workspaceURL: workspaceURL, documentURL: nil)  {

                let configFile = projectURL.appendingPathComponent(".github/copilot-instructions.md")

                // If the file doesn't exist, create one with a proper structure
                if !FileManager.default.fileExists(atPath: configFile.path) {
                    do {
                        // Create directory if it doesn't exist
                        try FileManager.default.createDirectory(
                            at: projectURL.appendingPathComponent(".github"),
                            withIntermediateDirectories: true
                        )
                        // Create empty file
                        try "".write(to: configFile, atomically: true, encoding: .utf8)
                    } catch {
                        toast("Failed to create config file .github/copilot-instructions.md: \(error)", .error)
                    }
                }

                if FileManager.default.fileExists(atPath: configFile.path) {
                    NSWorkspace.shared.open(configFile)
                }
            }
        }
    }
}

#Preview {
    ChatSection()
        .frame(width: 600)
}
