import SwiftUI
import GitHubCopilotService

/// Individual tool row
struct MCPToolRow: View {
    let tool: MCPTool
    let isServerEnabled: Bool
    @Binding var isToolEnabled: Bool
    let onToolToggleChanged: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center) {
            Toggle(isOn: Binding(
                get: { isToolEnabled },
                set: { onToolToggleChanged($0) }
            )) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(tool.name).fontWeight(.medium)
                        
                        if let description = tool.description {
                            Text(description)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .help(description)
                        }
                    }

                    Divider().padding(.vertical, 4)
                }
            }
        }
        .padding(.leading, 36)
        .padding(.vertical, 0)
        .onChange(of: tool._status) { isToolEnabled = $0 == .enabled }
        .onChange(of: isServerEnabled) { if !$0 { isToolEnabled = false } }
    }
}
