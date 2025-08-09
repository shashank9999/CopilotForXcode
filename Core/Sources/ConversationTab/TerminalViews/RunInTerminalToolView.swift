import SwiftUI
import XcodeInspector
import ConversationServiceProvider
import ComposableArchitecture
import Terminal

struct RunInTerminalToolView: View {
    let tool: AgentToolCall
    let command: String?
    let explanation: String?
    let isBackground: Bool?
    let chat: StoreOf<Chat>
    private var title: String = "Run command in terminal"

    @AppStorage(\.codeBackgroundColorLight) var codeBackgroundColorLight
    @AppStorage(\.codeForegroundColorLight) var codeForegroundColorLight
    @AppStorage(\.codeBackgroundColorDark) var codeBackgroundColorDark
    @AppStorage(\.codeForegroundColorDark) var codeForegroundColorDark
    @AppStorage(\.chatFontSize) var chatFontSize
    @AppStorage(\.chatCodeFont) var chatCodeFont
    @Environment(\.colorScheme) var colorScheme
    
    init(tool: AgentToolCall, chat: StoreOf<Chat>) {
        self.tool = tool
        self.chat = chat
        if let input = tool.invokeParams?.input as? [String: AnyCodable] {
            self.command = input["command"]?.value as? String
            self.explanation = input["explanation"]?.value as? String
            self.isBackground = input["isBackground"]?.value as? Bool
            self.title = (isBackground != nil && isBackground!) ? "Run command in background terminal" : "Run command in terminal"
        } else {
            self.command = nil
            self.explanation = nil
            self.isBackground = nil
        }
    }

    var terminalSession: TerminalSession? {
        return TerminalSessionManager.shared.getSession(for: tool.id)
    }

    var statusIcon: some View {
        Group {
            switch tool.status {
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            case .completed:
                Image(systemName: "checkmark")
                    .foregroundColor(.green.opacity(0.5))
            case .error:
                Image(systemName: "xmark.circle")
                    .foregroundColor(.red.opacity(0.5))
            case .cancelled:
                Image(systemName: "slash.circle")
                    .foregroundColor(.gray.opacity(0.5))
            case .waitForConfirmation:
                EmptyView()
            case .accepted:
                EmptyView()
            }
        }
    }
    
    var body: some View {
        WithPerceptionTracking {
            if tool.status == .waitForConfirmation || terminalSession != nil {
                VStack {
                    HStack {
                        Image("Terminal")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)

                        Text(self.title)
                            .font(.system(size: chatFontSize))
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .background(Color.clear)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    toolView
                }
                .padding(8)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            } else {
                toolView
            }
        }
    }

    var codeBackgroundColor: Color {
        if colorScheme == .light, let color = codeBackgroundColorLight.value {
            return color.swiftUIColor
        } else if let color = codeBackgroundColorDark.value {
            return color.swiftUIColor
        }
        return Color(nsColor: .textBackgroundColor).opacity(0.7)
    }

    var codeForegroundColor: Color {
        if colorScheme == .light, let color = codeForegroundColorLight.value {
            return color.swiftUIColor
        } else if let color = codeForegroundColorDark.value {
            return color.swiftUIColor
        }
        return Color(nsColor: .textColor)
    }

    var toolView: some View {
        WithPerceptionTracking {
            VStack {
                if command != nil {
                    HStack(spacing: 4) {
                        statusIcon
                            .frame(width: 16, height: 16)

                        Text(command!)
                            .textSelection(.enabled)
                            .font(.system(size: chatFontSize, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(codeForegroundColor)
                            .background(codeBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            }
                    }
                } else {
                    Text("Invalid parameter in the toolcall for runInTerminal")
                }

                if let terminalSession = terminalSession {
                    XTermView(
                        terminalSession: terminalSession,
                        onTerminalInput: terminalSession.handleTerminalInput
                    )
                    .frame(minHeight: 200, maxHeight: 400)
                } else if tool.status == .waitForConfirmation {
                    ThemedMarkdownText(text: explanation ?? "", chat: chat)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Button("Cancel") {
                            chat.send(.toolCallCancelled(tool.id))
                        }

                        Button("Continue") {
                            chat.send(.toolCallAccepted(tool.id))
                        }
                        .buttonStyle(BorderedProminentButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
        }
    }
}
