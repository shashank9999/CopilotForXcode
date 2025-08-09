import AppKit
import AsyncAlgorithms
import ChatTab
import Combine
import ComposableArchitecture
import Dependencies
import Foundation
import SwiftUI
import XcodeInspector

actor WidgetWindowsController: NSObject {
    let userDefaultsObservers = WidgetUserDefaultsObservers()
    var xcodeInspector: XcodeInspector { .shared }

    nonisolated let windows: WidgetWindows
    nonisolated let store: StoreOf<WidgetFeature>
    nonisolated let chatTabPool: ChatTabPool

    var currentApplicationProcessIdentifier: pid_t?
    
    weak var currentXcodeApp: XcodeAppInstanceInspector?
    weak var previousXcodeApp: XcodeAppInstanceInspector?

    var cancellable: Set<AnyCancellable> = []
    var observeToAppTask: Task<Void, Error>?
    var observeToFocusedEditorTask: Task<Void, Error>?

    var updateWindowOpacityTask: Task<Void, Error>?
    var lastUpdateWindowOpacityTime = Date(timeIntervalSince1970: 0)

    var updateWindowLocationTask: Task<Void, Error>?
    var lastUpdateWindowLocationTime = Date(timeIntervalSince1970: 0)

    var beatingCompletionPanelTask: Task<Void, Error>?

    deinit {
        userDefaultsObservers.presentationModeChangeObserver.onChange = {}
        observeToAppTask?.cancel()
        observeToFocusedEditorTask?.cancel()
    }

    init(store: StoreOf<WidgetFeature>, chatTabPool: ChatTabPool) {
        self.store = store
        self.chatTabPool = chatTabPool
        windows = .init(store: store, chatTabPool: chatTabPool)
        super.init()
        windows.controller = self
    }

    @MainActor func send(_ action: WidgetFeature.Action) {
        store.send(action)
    }

    func start() {
        cancellable.removeAll()

        xcodeInspector.$activeApplication.sink { [weak self] app in
            guard let app else { return }
            Task { [weak self] in await self?.activate(app) }
        }.store(in: &cancellable)

        xcodeInspector.$focusedEditor.sink { [weak self] editor in
            guard let editor else { return }
            Task { [weak self] in await self?.observe(toEditor: editor) }
        }.store(in: &cancellable)

        xcodeInspector.$completionPanel.sink { [weak self] newValue in
            Task { [weak self] in
                await self?.handleCompletionPanelChange(isDisplaying: newValue != nil)
            }
        }.store(in: &cancellable)

        userDefaultsObservers.presentationModeChangeObserver.onChange = { [weak self] in
            Task { [weak self] in
                await self?.updateWindowLocation(animated: false, immediately: false)
                await self?.send(.updateColorScheme)
            }
        }
    }
}

// MARK: - Observation

private extension WidgetWindowsController {
    func activate(_ app: AppInstanceInspector) {
        Task {
            if app.isXcode {
                updateWindowLocation(animated: false, immediately: true)
                updateWindowOpacity(immediately: false)
                
                if let xcodeApp = app as? XcodeAppInstanceInspector {
                    previousXcodeApp = currentXcodeApp ?? xcodeApp
                    currentXcodeApp = xcodeApp
                }
                
            } else {
                updateWindowOpacity(immediately: true)
                updateWindowLocation(animated: false, immediately: false)
                await hideSuggestionPanelWindow()
            }
            await adjustChatPanelWindowLevel()
        }
        guard currentApplicationProcessIdentifier != app.processIdentifier else { return }
        currentApplicationProcessIdentifier = app.processIdentifier
        observe(toApp: app)
    }

    func observe(toApp app: AppInstanceInspector) {
        guard let app = app as? XcodeAppInstanceInspector else { return }
        let notifications = app.axNotifications
        observeToAppTask?.cancel()
        observeToAppTask = Task {
            await windows.orderFront()

            for await notification in await notifications.notifications() {
                try Task.checkCancellation()

                /// Hide the widgets before switching to another window/editor
                /// so the transition looks better.
                func hideWidgetForTransitions() async {
                    let newDocumentURL = await xcodeInspector.safe.realtimeActiveDocumentURL
                    let documentURL = await MainActor
                        .run { store.withState { $0.focusingDocumentURL } }
                    if documentURL != newDocumentURL {
                        await send(.panel(.removeDisplayedContent))
                        await hidePanelWindows()
                    }
                    await send(.updateFocusingDocumentURL)
                }

                func removeContent() async {
                    await send(.panel(.removeDisplayedContent))
                }

                func updateWidgetsAndNotifyChangeOfEditor(immediately: Bool) async {
                    await send(.panel(.switchToAnotherEditorAndUpdateContent))
                    updateWindowLocation(animated: false, immediately: immediately)
                    updateWindowOpacity(immediately: immediately)
                }

                func updateWidgets(immediately: Bool) async {
                    updateWindowLocation(animated: false, immediately: immediately)
                    updateWindowOpacity(immediately: immediately)
                }

                switch notification.kind {
                case .focusedWindowChanged, .focusedUIElementChanged:
                    await hideWidgetForTransitions()
                    await updateWidgetsAndNotifyChangeOfEditor(immediately: true)
                case .applicationActivated:
                    await updateWidgetsAndNotifyChangeOfEditor(immediately: false)
                case .mainWindowChanged:
                    await updateWidgetsAndNotifyChangeOfEditor(immediately: false)
                case .windowMiniaturized, .windowDeminiaturized:
                    await updateWidgets(immediately: false)
                case .resized,
                    .moved,
                    .windowMoved,
                    .windowResized:
                    await updateWidgets(immediately: false)
                    await updateAttachedChatWindowLocation(notification)
                case .created, .uiElementDestroyed, .xcodeCompletionPanelChanged,
                     .applicationDeactivated:
                    continue
                case .titleChanged:
                    continue
                }
            }
        }
    }

    func observe(toEditor editor: SourceEditor) {
        observeToFocusedEditorTask?.cancel()
        observeToFocusedEditorTask = Task {
            let selectionRangeChange = await editor.axNotifications.notifications()
                .filter { $0.kind == .selectedTextChanged }
            let scroll = await editor.axNotifications.notifications()
                .filter { $0.kind == .scrollPositionChanged }

            if #available(macOS 13.0, *) {
                for await notification in merge(
                    scroll,
                    selectionRangeChange.debounce(for: Duration.milliseconds(0))
                ) {
                    guard await xcodeInspector.safe.latestActiveXcode != nil else { return }
                    try Task.checkCancellation()

                    // for better looking
                    if notification.kind == .scrollPositionChanged {
                        await hideSuggestionPanelWindow()
                    }

                    updateWindowLocation(animated: false, immediately: false)
                    updateWindowOpacity(immediately: false)
                }
            } else {
                for await notification in merge(selectionRangeChange, scroll) {
                    guard await xcodeInspector.safe.latestActiveXcode != nil else { return }
                    try Task.checkCancellation()

                    // for better looking
                    if notification.kind == .scrollPositionChanged {
                        await hideSuggestionPanelWindow()
                    }

                    updateWindowLocation(animated: false, immediately: false)
                    updateWindowOpacity(immediately: false)
                }
            }
        }
    }

    func handleCompletionPanelChange(isDisplaying: Bool) {
        beatingCompletionPanelTask?.cancel()
        beatingCompletionPanelTask = Task {
            if !isDisplaying {
                // so that the buttons on the suggestion panel could be
                // clicked
                // before the completion panel updates the location of the
                // suggestion panel
                try await Task.sleep(nanoseconds: 400_000_000)
            }

            updateWindowLocation(animated: false, immediately: false)
            updateWindowOpacity(immediately: false)
        }
    }
}

// MARK: - Window Updating

extension WidgetWindowsController {
    @MainActor
    func hidePanelWindows() {
        windows.sharedPanelWindow.alphaValue = 0
        windows.suggestionPanelWindow.alphaValue = 0
    }

    @MainActor
    func hideSuggestionPanelWindow() {
        windows.suggestionPanelWindow.alphaValue = 0
        send(.panel(.hidePanel))
    }

    func generateWidgetLocation() -> WidgetLocation? {
        // Default location when no active application/window
        let defaultLocation = generateDefaultLocation()
        
        if let application = xcodeInspector.latestActiveXcode?.appElement {
            if let focusElement = xcodeInspector.focusedEditor?.element,
               let parent = focusElement.parent,
               let frame = parent.rect,
               let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
               let firstScreen = NSScreen.main
            {
                let positionMode = UserDefaults.shared
                    .value(for: \.suggestionWidgetPositionMode)
                let suggestionMode = UserDefaults.shared
                    .value(for: \.suggestionPresentationMode)

                switch positionMode {
                case .fixedToBottom:
                    var result = UpdateLocationStrategy.FixedToBottom().framesForWindows(
                        editorFrame: frame,
                        mainScreen: screen,
                        activeScreen: firstScreen
                    )
                    switch suggestionMode {
                    case .nearbyTextCursor:
                        result.suggestionPanelLocation = UpdateLocationStrategy
                            .NearbyTextCursor()
                            .framesForSuggestionWindow(
                                editorFrame: frame, mainScreen: screen,
                                activeScreen: firstScreen,
                                editor: focusElement,
                                completionPanel: xcodeInspector.completionPanel
                            )
                    default:
                        break
                    }
                    return result
                case .alignToTextCursor:
                    var result = UpdateLocationStrategy.AlignToTextCursor().framesForWindows(
                        editorFrame: frame,
                        mainScreen: screen,
                        activeScreen: firstScreen,
                        editor: focusElement
                    )
                    switch suggestionMode {
                    case .nearbyTextCursor:
                        result.suggestionPanelLocation = UpdateLocationStrategy
                            .NearbyTextCursor()
                            .framesForSuggestionWindow(
                                editorFrame: frame, mainScreen: screen,
                                activeScreen: firstScreen,
                                editor: focusElement,
                                completionPanel: xcodeInspector.completionPanel
                            )
                    default:
                        break
                    }
                    return result
                }
            } else if var window = application.focusedWindow,
                      var frame = application.focusedWindow?.rect,
                      !["menu bar", "menu bar item"].contains(window.description),
                      frame.size.height > 300,
                      let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
                      let firstScreen = NSScreen.main
            {
                if ["open_quickly"].contains(window.identifier)
                    || ["alert"].contains(window.label)
                {
                    // fallback to use workspace window
                    guard let workspaceWindow = application.windows
                        .first(where: { $0.identifier == "Xcode.WorkspaceWindow" }),
                        let rect = workspaceWindow.rect
                    else {
                        return defaultLocation
                    }

                    window = workspaceWindow
                    frame = rect
                }

                var expendedSize = CGSize.zero
                if ["Xcode.WorkspaceWindow"].contains(window.identifier) {
                    // extra padding to bottom so buttons won't be covered
                    frame.size.height -= 40
                } else {
                    // move a bit away from the window so buttons won't be covered
                    frame.origin.x -= Style.widgetPadding + Style.widgetWidth / 2
                    frame.size.width += Style.widgetPadding * 2 + Style.widgetWidth
                    expendedSize.width = (Style.widgetPadding * 2 + Style.widgetWidth) / 2
                    expendedSize.height += Style.widgetPadding
                }

                return UpdateLocationStrategy.FixedToBottom().framesForWindows(
                    editorFrame: frame,
                    mainScreen: screen,
                    activeScreen: firstScreen,
                    preferredInsideEditorMinWidth: 9_999_999_999, // never
                    editorFrameExpendedSize: expendedSize
                )
            }
        }
        return defaultLocation
    }
    
    // Generate a default location when no workspace is opened
    private func generateDefaultLocation() -> WidgetLocation {
        let chatPanelFrame = UpdateLocationStrategy.getChatPanelFrame()
        
        return WidgetLocation(
            widgetFrame: .zero,
            tabFrame: .zero,
            defaultPanelLocation: .init(
                frame: chatPanelFrame,
                alignPanelTop: false
            ),
            suggestionPanelLocation: nil
        )
    }

    func updatePanelState(_ location: WidgetLocation) async {
        await send(.updatePanelStateToMatch(location))
    }

    func updateWindowOpacity(immediately: Bool) {
        let shouldDebounce = !immediately &&
            !(Date().timeIntervalSince(lastUpdateWindowOpacityTime) > 3)
        lastUpdateWindowOpacityTime = Date()
        updateWindowOpacityTask?.cancel()

        let task = Task {
            if shouldDebounce {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try Task.checkCancellation()
            let xcodeInspector = self.xcodeInspector
            let activeApp = await xcodeInspector.safe.activeApplication
            let latestActiveXcode = await xcodeInspector.safe.latestActiveXcode
            let previousActiveApplication = xcodeInspector.previousActiveApplication
            await MainActor.run {
                let state = store.withState { $0 }
                let isChatPanelDetached = state.chatPanelState.isDetached
                // Check if the user has requested to display the panel, regardless of workspace state
                let isPanelDisplayed = state.chatPanelState.isPanelDisplayed
                
                // Keep the chat panel visible even when there's no workspace/tabs if it's explicitly displayed
                // This ensures the login screen remains visible
                let shouldShowChatPanel = isPanelDisplayed || (
                    state.chatPanelState.currentChatWorkspace != nil &&
                    !state.chatPanelState.currentChatWorkspace!.tabInfo.isEmpty
                )

                if let activeApp, activeApp.isXcode {
                    let application = activeApp.appElement
                    /// We need this to hide the windows when Xcode is minimized.
                    let noFocus = application.focusedWindow == nil
                    windows.sharedPanelWindow.alphaValue = noFocus ? 0 : 1
                    send(.panel(noFocus ? .hidePanel : .showPanel))
                    windows.suggestionPanelWindow.alphaValue = noFocus ? 0 : 1
                    windows.widgetWindow.alphaValue = noFocus ? 0 : 1
                    windows.toastWindow.alphaValue = noFocus ? 0 : 1

                    if isChatPanelDetached {
                        windows.chatPanelWindow.isWindowHidden = !shouldShowChatPanel
                    } else {
                        windows.chatPanelWindow.isWindowHidden = noFocus
                    }
                } else if let activeApp, activeApp.isExtensionService {
                    let noFocus = {
                        guard let xcode = latestActiveXcode else { return true }
                        if let window = xcode.appElement.focusedWindow,
                           window.role == "AXWindow"
                        {
                            return false
                        }
                        return true
                    }()

                    let previousAppIsXcode = previousActiveApplication?.isXcode ?? false

                    send(.panel(noFocus ? .hidePanel : .showPanel))
                    windows.sharedPanelWindow.alphaValue = noFocus ? 0 : 1
                    windows.suggestionPanelWindow.alphaValue = noFocus ? 0 : 1
                    windows.widgetWindow.alphaValue = if noFocus {
                        0
                    } else if previousAppIsXcode {
                        1
                    } else {
                        0
                    }
                    windows.toastWindow.alphaValue = noFocus ? 0 : 1
                    if isChatPanelDetached {
                        windows.chatPanelWindow.isWindowHidden = !shouldShowChatPanel
                    } else {
                        windows.chatPanelWindow.isWindowHidden = noFocus && !windows
                            .chatPanelWindow.isKeyWindow
                    }
                } else {
                    windows.sharedPanelWindow.alphaValue = 0
                    windows.suggestionPanelWindow.alphaValue = 0
                    windows.widgetWindow.alphaValue = 0
                    windows.toastWindow.alphaValue = 0
                    if !isChatPanelDetached {
                        windows.chatPanelWindow.isWindowHidden = true
                    }
                }
            }
        }

        updateWindowOpacityTask = task
    }
    
    @MainActor
    func updateAttachedChatWindowLocation(_ notif: XcodeAppInstanceInspector.AXNotification? = nil) async {
        guard let currentXcodeApp = (await currentXcodeApp),
              let currentFocusedWindow = currentXcodeApp.appElement.focusedWindow,
              let currentXcodeScreen = currentXcodeApp.appScreen,
              let currentXcodeRect = currentFocusedWindow.rect,
              let notif = notif
        else { return }
        
        if let previousXcodeApp = (await previousXcodeApp),
           currentXcodeApp.processIdentifier == previousXcodeApp.processIdentifier {
            if currentFocusedWindow.isFullScreen == true {
                return
            }
        }
        
        let isAttachedToXcodeEnabled = UserDefaults.shared.value(for: \.autoAttachChatToXcode)
        guard isAttachedToXcodeEnabled else { return }
        
        guard notif.element.isXcodeWorkspaceWindow else { return }
        
        let state = store.withState { $0 }
        if state.chatPanelState.isPanelDisplayed && !windows.chatPanelWindow.isWindowHidden {
            var frame = UpdateLocationStrategy.getAttachedChatPanelFrame(
                NSScreen.main ?? NSScreen.screens.first!, 
                workspaceWindowElement: notif.element
            )
            
            let screenMaxX = currentXcodeScreen.visibleFrame.maxX
            if screenMaxX - currentXcodeRect.maxX < Style.minChatPanelWidth
            {
                if let previousXcodeRect = (await previousXcodeApp?.appElement.focusedWindow?.rect),
                   screenMaxX - previousXcodeRect.maxX < Style.minChatPanelWidth
                {
                    let isSameScreen = currentXcodeScreen.visibleFrame.intersects(windows.chatPanelWindow.frame)
                    // Only update y and height
                    frame = .init(
                        x: isSameScreen ? windows.chatPanelWindow.frame.minX : frame.minX,
                        y: frame.minY,
                        width: isSameScreen ? windows.chatPanelWindow.frame.width : frame.width,
                        height: frame.height
                    )
                }
            }
            
            windows.chatPanelWindow.setFrame(frame, display: true, animate: true)
            
            await adjustChatPanelWindowLevel()
        }
    }

    func updateWindowLocation(
        animated: Bool,
        immediately: Bool,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        @Sendable @MainActor
        func update() async {
            let state = store.withState { $0 }
            let isChatPanelDetached = state.chatPanelState.isDetached
            guard let widgetLocation = await generateWidgetLocation() else { return }
            await updatePanelState(widgetLocation)

            windows.widgetWindow.setFrame(
                widgetLocation.widgetFrame,
                display: false,
                animate: animated
            )
            windows.toastWindow.setFrame(
                widgetLocation.defaultPanelLocation.frame,
                display: false,
                animate: animated
            )
            windows.sharedPanelWindow.setFrame(
                widgetLocation.defaultPanelLocation.frame,
                display: false,
                animate: animated
            )

            if let suggestionPanelLocation = widgetLocation.suggestionPanelLocation {
                windows.suggestionPanelWindow.setFrame(
                    suggestionPanelLocation.frame,
                    display: false,
                    animate: animated
                )
            }
            
            let isAttachedToXcodeEnabled = UserDefaults.shared.value(for: \.autoAttachChatToXcode)
            if isAttachedToXcodeEnabled {
                // update in `updateAttachedChatWindowLocation`
            } else if isChatPanelDetached {
                // don't update it!
            } else {
                windows.chatPanelWindow.setFrame(
                    widgetLocation.defaultPanelLocation.frame,
                    display: false,
                    animate: animated
                )
            }

            await adjustChatPanelWindowLevel()
        }

        let now = Date()
        let shouldThrottle = !immediately &&
            !(now.timeIntervalSince(lastUpdateWindowLocationTime) > 3)

        updateWindowLocationTask?.cancel()
        let interval: TimeInterval = 0.05

        if shouldThrottle {
            let delay = max(
                0,
                interval - now.timeIntervalSince(lastUpdateWindowLocationTime)
            )

            updateWindowLocationTask = Task {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
                await update()
            }
        } else {
            Task {
                await update()
            }
        }
        lastUpdateWindowLocationTime = Date()
    }

    @MainActor
    func adjustChatPanelWindowLevel() async {
        let window = windows.chatPanelWindow
        
        let disableFloatOnTopWhenTheChatPanelIsDetached = UserDefaults.shared
            .value(for: \.disableFloatOnTopWhenTheChatPanelIsDetached)
        guard disableFloatOnTopWhenTheChatPanelIsDetached else {
            window.setFloatOnTop(true)
            return
        }

        let state = store.withState { $0 }
        let isChatPanelDetached = state.chatPanelState.isDetached

        guard isChatPanelDetached else {
            window.setFloatOnTop(true)
            return
        }

        let floatOnTopWhenOverlapsXcode = UserDefaults.shared
            .value(for: \.keepFloatOnTopIfChatPanelAndXcodeOverlaps)

        let latestApp = await xcodeInspector.safe.activeApplication
        let latestAppIsXcodeOrExtension = if let latestApp {
            latestApp.isXcode || latestApp.isExtensionService
        } else {
            false
        }
        
        if !floatOnTopWhenOverlapsXcode || !latestAppIsXcodeOrExtension {
            window.setFloatOnTop(false)
        } else {
            guard let xcode = await xcodeInspector.safe.latestActiveXcode else { return }
            let windowElements = xcode.appElement.windows
            let overlap = windowElements.contains {
                if let position = $0.position, let size = $0.size {
                    let rect = CGRect(
                        x: position.x,
                        y: position.y,
                        width: size.width,
                        height: size.height
                    )
                    return rect.intersects(window.frame)
                }
                return false
            }

            window.setFloatOnTop(overlap)
        }
    }
}

// MARK: - NSWindowDelegate

extension WidgetWindowsController: NSWindowDelegate {
    nonisolated
    func windowWillMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard window === windows.chatPanelWindow else { return }
            await Task.yield()
            store.send(.chatPanel(.detachChatPanel))
        }
    }

    nonisolated
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard window === windows.chatPanelWindow else { return }
            await Task.yield()
            await adjustChatPanelWindowLevel()
        }
    }

    nonisolated
    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard window === windows.chatPanelWindow else { return }
            await Task.yield()
            store.send(.chatPanel(.enterFullScreen))
        }
    }

    nonisolated
    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard window === windows.chatPanelWindow else { return }
            await Task.yield()
            store.send(.chatPanel(.exitFullScreen))
        }
    }
}

// MARK: - Windows

public final class WidgetWindows {
    let store: StoreOf<WidgetFeature>
    let chatTabPool: ChatTabPool
    weak var controller: WidgetWindowsController?
    let cursorPositionTracker = CursorPositionTracker()

    // you should make these window `.transient` so they never show up in the mission control.

    @MainActor
    lazy var fullscreenDetector = {
        let it = CanBecomeKeyWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        it.isReleasedWhenClosed = false
        it.isOpaque = false
        it.backgroundColor = .clear
        it.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        it.hasShadow = false
        it.setIsVisible(false)
        it.canBecomeKeyChecker = { false }
        return it
    }()

    @MainActor
    lazy var widgetWindow = {
        let it = CanBecomeKeyWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        it.isReleasedWhenClosed = false
        it.isOpaque = false
        it.backgroundColor = .clear
        it.level = .floating
        it.collectionBehavior = [.fullScreenAuxiliary, .transient, .canJoinAllSpaces]
        it.hasShadow = true
        it.contentView = NSHostingView(
            rootView: WidgetView(
                store: store.scope(
                    state: \._internalCircularWidgetState,
                    action: \.circularWidget
                )
            )
        )
        it.setIsVisible(true)
        it.canBecomeKeyChecker = { false }
        return it
    }()

    @MainActor
    lazy var sharedPanelWindow = {
        let it = CanBecomeKeyWindow(
            contentRect: .init(x: 0, y: 0, width: Style.panelWidth, height: Style.panelHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        it.isReleasedWhenClosed = false
        it.isOpaque = false
        it.backgroundColor = .clear
        it.level = widgetLevel(2)
        it.collectionBehavior = [.fullScreenAuxiliary, .transient, .canJoinAllSpaces]
        it.hasShadow = true
        it.contentView = NSHostingView(
            rootView: SharedPanelView(
                store: store.scope(
                    state: \.panelState,
                    action: \.panel
                ).scope(
                    state: \.sharedPanelState,
                    action: \.sharedPanel
                )
            ).environment(cursorPositionTracker)
        )
        it.setIsVisible(true)
        it.canBecomeKeyChecker = { [store] in
            store.withState { state in
                state.panelState.sharedPanelState.content.promptToCode != nil
            }
        }
        return it
    }()

    @MainActor
    lazy var suggestionPanelWindow = {
        let it = CanBecomeKeyWindow(
            contentRect: .init(x: 0, y: 0, width: Style.panelWidth, height: Style.panelHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        it.isReleasedWhenClosed = false
        it.isOpaque = false
        it.backgroundColor = .clear
        it.level = widgetLevel(2)
        it.collectionBehavior = [.fullScreenAuxiliary, .transient, .canJoinAllSpaces]
        it.hasShadow = false
        it.contentView = NSHostingView(
            rootView: SuggestionPanelView(
                store: store.scope(
                    state: \.panelState,
                    action: \.panel
                ).scope(
                    state: \.suggestionPanelState,
                    action: \.suggestionPanel
                )
            ).environment(cursorPositionTracker)
        )
        it.canBecomeKeyChecker = { false }
        it.setIsVisible(true)
        return it
    }()

    @MainActor
    lazy var chatPanelWindow = {
        let it = ChatPanelWindow(
            store: store.scope(
                state: \.chatPanelState,
                action: \.chatPanel
            ),
            chatTabPool: chatTabPool,
            minimizeWindow: { [weak self] in
                self?.store.send(.chatPanel(.hideButtonClicked))
            }
        )
        it.delegate = controller
        it.isWindowHidden = true
        return it
    }()

    @MainActor
    // The toast window area is now capturing mouse events
    // Even in the transparent parts where there's no visible content.
    lazy var toastWindow = {
        let it = CanBecomeKeyWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        it.isReleasedWhenClosed = false
        it.isOpaque = false
        it.backgroundColor = .clear
        it.level = widgetLevel(2)
        it.collectionBehavior = [.fullScreenAuxiliary, .transient, .canJoinAllSpaces]
        it.hasShadow = false
        it.contentView = NSHostingView(
            rootView: ToastPanelView(store: store.scope(
                state: \.toastPanel,
                action: \.toastPanel
            ))
        )
        it.setIsVisible(true)
        it.canBecomeKeyChecker = { false }
        return it
    }()

    init(
        store: StoreOf<WidgetFeature>,
        chatTabPool: ChatTabPool
    ) {
        self.store = store
        self.chatTabPool = chatTabPool
    }

    @MainActor
    func orderFront() {
        widgetWindow.orderFrontRegardless()
        toastWindow.orderFrontRegardless()
        sharedPanelWindow.orderFrontRegardless()
        suggestionPanelWindow.orderFrontRegardless()
        if chatPanelWindow.level.rawValue > NSWindow.Level.normal.rawValue {
            chatPanelWindow.orderFrontRegardless()
        }
    }
}

// MARK: - Window Subclasses

class CanBecomeKeyWindow: NSWindow {
    var canBecomeKeyChecker: () -> Bool = { true }
    override var canBecomeKey: Bool { canBecomeKeyChecker() }
    override var canBecomeMain: Bool { canBecomeKeyChecker() }
}

func widgetLevel(_ addition: Int) -> NSWindow.Level {
    let minimumWidgetLevel: Int
    minimumWidgetLevel = NSWindow.Level.floating.rawValue
    return .init(minimumWidgetLevel + addition)
}

