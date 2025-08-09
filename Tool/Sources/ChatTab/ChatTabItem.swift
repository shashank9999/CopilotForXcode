import ComposableArchitecture
import Foundation

public struct AnyChatTabBuilder: Equatable {
    public static func == (lhs: AnyChatTabBuilder, rhs: AnyChatTabBuilder) -> Bool {
        true
    }

    public let chatTabBuilder: any ChatTabBuilder

    public init(_ chatTabBuilder: any ChatTabBuilder) {
        self.chatTabBuilder = chatTabBuilder
    }
}

@Reducer
public struct ChatTabItem {
    public typealias State = ChatTabInfo

    public enum Action: Equatable {
        case updateTitle(String)
        case openNewTab(AnyChatTabBuilder)
        case tabContentUpdated
        case close
        case focus
        case setCLSConversationID(String)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            // the actions will be handled elsewhere in the ChatPanelFeature
            switch action {
            case .updateTitle:
                return .none
            case .openNewTab:
                return .none
            case .tabContentUpdated:
                return .none
            case .close:
                return .none
            case .focus:
                state.focusTrigger += 1
                return .none
            case .setCLSConversationID:
                return .none
            }
        }
    }
}

