import ActiveApplicationMonitor
import AppKit
import AsyncAlgorithms
import ChatTab
import Combine
import ComposableArchitecture
import Preferences
import SwiftUI
import UserDefaultsObserver
import XcodeInspector

@MainActor
public final class SuggestionWidgetController: NSObject {
    let store: StoreOf<WidgetFeature>
    let chatTabPool: ChatTabPool
    let windowsController: WidgetWindowsController
    private var cancellable = Set<AnyCancellable>()

    public let dependency: SuggestionWidgetControllerDependency

    public init(
        store: StoreOf<WidgetFeature>,
        chatTabPool: ChatTabPool,
        dependency: SuggestionWidgetControllerDependency
    ) {
        self.dependency = dependency
        self.store = store
        self.chatTabPool = chatTabPool
        windowsController = .init(store: store, chatTabPool: chatTabPool)

        super.init()

        if ProcessInfo.processInfo.environment["IS_UNIT_TEST"] == "YES" { return }

        dependency.windowsController = windowsController

        store.send(.startup)
        Task {
            await windowsController.start()
        }
    }
}

// MARK: - Handle Events

public extension SuggestionWidgetController {
    func suggestCode() {
        store.send(.panel(.presentSuggestion))
    }
    
    func expandSuggestion() {
          store.withState { state in
              if state.panelState.content.suggestion != nil {
                  store.send(.panel(.expandSuggestion))
              }
          }
      }
    
    func discardSuggestion() {
        store.withState { state in
            if state.panelState.content.suggestion != nil {
                store.send(.panel(.discardSuggestion))
            }
        }
    }

    #warning("TODO: Make a progress controller that doesn't use TCA.")
    func markAsProcessing(_ isProcessing: Bool) {
        store.withState { state in
            if isProcessing, !state.circularWidgetState.isProcessing {
                store.send(.circularWidget(.markIsProcessing))
            } else if !isProcessing, state.circularWidgetState.isProcessing {
                store.send(.circularWidget(.endIsProcessing))
            }
        }
    }

    func presentError(_ errorDescription: String) {
        store.send(.toastPanel(.toast(.toast(errorDescription, .error, nil))))
    }

    func presentChatRoom() {
        store.send(.chatPanel(.presentChatPanel(forceDetach: false)))
    }

    func presentDetachedGlobalChat() {
        store.send(.chatPanel(.presentChatPanel(forceDetach: true)))
    }

    func closeChatRoom() {
//        store.send(.chatPanel(.closeChatPanel))
    }
}

extension SuggestionWidgetController {
    public func presentWarning(message: String, url: String?) {
        store.send(.panel(.presentWarning(message: message, url: url)))
    }
    
    public func dismissWarning() {
        store.send(.panel(.dismissWarning))
    }
}

