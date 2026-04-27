import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

// MARK: - Entry IDs

private enum AISettingsSection: Int32 {
    case connection = 0
    case translation = 1
    case devSettings = 2
    case cache = 3
    case prompt = 4
    case version = 5
}

private enum AISettingsEntry: ItemListNodeEntry {
    case versionInfo(String)

    case connectionHeader(String)
    case proxyURL(String, String)
    case testConnection(String)
    case connectionStatus(String, Bool)

    case translationHeader(String)
    case globalToggle(String, Bool)
    case incomingToggle(String, Bool)
    case outgoingToggle(String, Bool)

    case devHeader(String)
    case contextMode(String, Int)
    case contextCount(String, Int)
    case incomingContextMode(String, Int)
    case incomingContextCount(String, Int)
    case showRawResponses(String, Bool)

    case cacheHeader(String)
    case clearCache(String)
    case sendLogs(String)

    case promptHeader(String)
    case outgoingPromptButton(String)
    case incomingPromptButton(String)

    var section: ItemListSectionId {
        switch self {
        case .versionInfo:
            return AISettingsSection.version.rawValue
        case .connectionHeader, .proxyURL, .testConnection, .connectionStatus:
            return AISettingsSection.connection.rawValue
        case .translationHeader, .globalToggle, .incomingToggle, .outgoingToggle:
            return AISettingsSection.translation.rawValue
        case .devHeader, .contextMode, .contextCount, .incomingContextMode, .incomingContextCount, .showRawResponses:
            return AISettingsSection.devSettings.rawValue
        case .cacheHeader, .clearCache, .sendLogs:
            return AISettingsSection.cache.rawValue
        case .promptHeader, .outgoingPromptButton, .incomingPromptButton:
            return AISettingsSection.prompt.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .versionInfo: return 50
        case .connectionHeader: return 0
        case .proxyURL: return 1
        case .testConnection: return 2
        case .connectionStatus: return 3
        case .translationHeader: return 10
        case .globalToggle: return 11
        case .incomingToggle: return 12
        case .outgoingToggle: return 13
        case .devHeader: return 20
        case .contextMode: return 21
        case .contextCount: return 22
        case .incomingContextMode: return 24
        case .incomingContextCount: return 25
        case .showRawResponses: return 26
        case .cacheHeader: return 30
        case .clearCache: return 31
        case .sendLogs: return 32
        case .promptHeader: return 40
        case .outgoingPromptButton: return 41
        case .incomingPromptButton: return 42
        }
    }

    static func < (lhs: AISettingsEntry, rhs: AISettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: AISettingsEntry, rhs: AISettingsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.versionInfo(a), .versionInfo(b)):
            return a == b
        case let (.connectionHeader(a), .connectionHeader(b)):
            return a == b
        case let (.proxyURL(a1, a2), .proxyURL(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.testConnection(a), .testConnection(b)):
            return a == b
        case let (.connectionStatus(a1, a2), .connectionStatus(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.translationHeader(a), .translationHeader(b)):
            return a == b
        case let (.globalToggle(a1, a2), .globalToggle(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.incomingToggle(a1, a2), .incomingToggle(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.outgoingToggle(a1, a2), .outgoingToggle(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.devHeader(a), .devHeader(b)):
            return a == b
        case let (.contextMode(a1, a2), .contextMode(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.contextCount(a1, a2), .contextCount(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.incomingContextMode(a1, a2), .incomingContextMode(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.incomingContextCount(a1, a2), .incomingContextCount(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.showRawResponses(a1, a2), .showRawResponses(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.cacheHeader(a), .cacheHeader(b)):
            return a == b
        case let (.clearCache(a), .clearCache(b)):
            return a == b
        case let (.sendLogs(a), .sendLogs(b)):
            return a == b
        case let (.promptHeader(a), .promptHeader(b)):
            return a == b
        case let (.outgoingPromptButton(a), .outgoingPromptButton(b)):
            return a == b
        case let (.incomingPromptButton(a), .incomingPromptButton(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        guard let arguments = arguments as? AISettingsArguments else {
            fatalError()
        }

        switch self {
        case let .versionInfo(text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )

        case let .connectionHeader(text):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                sectionId: self.section
            )

        case let .proxyURL(title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: value.isEmpty ? "Not set" : value,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.editProxyURL() }
            )

        case let .testConnection(title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.testConnection() }
            )

        case let .connectionStatus(_, connected):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(connected ? "\u{1F7E2} Connected" : "\u{1F534} Not Connected"),
                sectionId: self.section
            )

        case let .translationHeader(text):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                sectionId: self.section
            )

        case let .globalToggle(title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in arguments.toggleGlobal(value) }
            )

        case let .incomingToggle(title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in arguments.toggleIncoming(value) }
            )

        case let .outgoingToggle(title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in arguments.toggleOutgoing(value) }
            )

        case let .devHeader(text):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                sectionId: self.section
            )

        case let .contextMode(title, mode):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: mode == 1 ? "Single Message" : "Conversation Context",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.toggleContextMode() }
            )

        case let .contextCount(title, count):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: "\(count) messages",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.editContextCount() }
            )

        case let .incomingContextMode(title, mode):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: mode == 1 ? "Single Message" : "Conversation Context",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.toggleIncomingContextMode() }
            )

        case let .incomingContextCount(title, count):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: "\(count) messages",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.editIncomingContextCount() }
            )

        case let .showRawResponses(title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in arguments.toggleShowRaw(value) }
            )

        case let .cacheHeader(text):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                sectionId: self.section
            )

        case let .clearCache(title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .destructive,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.clearCache() }
            )

        case let .sendLogs(title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.sendLogs() }
            )

        case let .promptHeader(text):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                sectionId: self.section
            )

        case let .outgoingPromptButton(title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.openPromptEditor("outgoing") }
            )

        case let .incomingPromptButton(title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.openPromptEditor("incoming") }
            )
        }
    }
}

// MARK: - Arguments

private final class AISettingsArguments {
    let editProxyURL: () -> Void
    let testConnection: () -> Void
    let toggleGlobal: (Bool) -> Void
    let toggleIncoming: (Bool) -> Void
    let toggleOutgoing: (Bool) -> Void
    let toggleContextMode: () -> Void
    let editContextCount: () -> Void
    let toggleIncomingContextMode: () -> Void
    let editIncomingContextCount: () -> Void
    let toggleShowRaw: (Bool) -> Void
    let clearCache: () -> Void
    let sendLogs: () -> Void
    let openPromptEditor: (String) -> Void

    init(
        editProxyURL: @escaping () -> Void,
        testConnection: @escaping () -> Void,
        toggleGlobal: @escaping (Bool) -> Void,
        toggleIncoming: @escaping (Bool) -> Void,
        toggleOutgoing: @escaping (Bool) -> Void,
        toggleContextMode: @escaping () -> Void,
        editContextCount: @escaping () -> Void,
        toggleIncomingContextMode: @escaping () -> Void,
        editIncomingContextCount: @escaping () -> Void,
        toggleShowRaw: @escaping (Bool) -> Void,
        clearCache: @escaping () -> Void,
        sendLogs: @escaping () -> Void,
        openPromptEditor: @escaping (String) -> Void
    ) {
        self.editProxyURL = editProxyURL
        self.testConnection = testConnection
        self.toggleGlobal = toggleGlobal
        self.toggleIncoming = toggleIncoming
        self.toggleOutgoing = toggleOutgoing
        self.toggleContextMode = toggleContextMode
        self.editContextCount = editContextCount
        self.toggleIncomingContextMode = toggleIncomingContextMode
        self.editIncomingContextCount = editIncomingContextCount
        self.toggleShowRaw = toggleShowRaw
        self.clearCache = clearCache
        self.sendLogs = sendLogs
        self.openPromptEditor = openPromptEditor
    }
}

// MARK: - State

private struct AISettingsState: Equatable {
    var isConnected: Bool = false
    var isTesting: Bool = false
}

// MARK: - Entries generation

private func aiSettingsEntries(state: AISettingsState) -> [AISettingsEntry] {
    var entries: [AISettingsEntry] = []

    let isEnabled = AITranslationSettings.enabled

    entries.append(.connectionHeader("CONNECTION"))
    entries.append(.proxyURL("Server URL", AITranslationSettings.proxyServerURL))
    entries.append(.connectionStatus("Status", state.isConnected))

    entries.append(.translationHeader("TRANSLATION"))
    entries.append(.globalToggle("Enable AI Translation", isEnabled))

    if isEnabled {
        entries.append(.incomingToggle("Translate Incoming (DE > EN)", AITranslationSettings.autoTranslateIncoming))
        entries.append(.outgoingToggle("Translate Outgoing (EN > DE)", AITranslationSettings.autoTranslateOutgoing))
    }

    entries.append(.devHeader("DEVELOPER SETTINGS"))
    entries.append(.contextMode("Outgoing Context", AITranslationSettings.contextMode))
    if AITranslationSettings.contextMode == 2 {
        entries.append(.contextCount("Outgoing Context Messages", AITranslationSettings.contextMessageCount))
    }
    entries.append(.incomingContextMode("Incoming Context", AITranslationSettings.incomingContextMode))
    if AITranslationSettings.incomingContextMode == 2 {
        entries.append(.incomingContextCount("Incoming Context Messages", AITranslationSettings.incomingContextMessageCount))
    }
    entries.append(.showRawResponses("Show Raw API Responses", AITranslationSettings.showRawAPIResponses))

    entries.append(.cacheHeader("CACHE & LOGS"))
    entries.append(.clearCache("Clear Translation Cache"))
    entries.append(.sendLogs("Send Debug Logs"))

    entries.append(.promptHeader("SYSTEM PROMPTS"))
    entries.append(.outgoingPromptButton("Outgoing Prompt (EN > DE)"))
    entries.append(.incomingPromptButton("Incoming Prompt (DE > EN)"))

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    entries.append(.versionInfo("TranslateGram v\(version) (build \(build))"))

    return entries
}

// MARK: - Controller

public func aiSettingsController(context: AccountContext) -> ViewController {
    // Pre-seed the initial state with the current global connection status so the
    // green/red dot is correct on first paint (no flash of "Not Connected").
    // ValuePromise.get() |> take(1) emits the current value synchronously.
    var initialState = AISettingsState()
    let _ = (AITranslationService.shared.isConnectedPromise.get()
    |> take(1)).start(next: { connected in
        initialState.isConnected = connected
    })
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)

    let settingsRevision = ValuePromise<Int>(0, ignoreRepeated: false)
    let settingsRevisionValue = Atomic<Int>(value: 0)

    let bumpRevision: () -> Void = {
        let _ = settingsRevisionValue.modify { $0 + 1 }
        settingsRevision.set(settingsRevisionValue.with { $0 })
    }

    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = AISettingsArguments(
        editProxyURL: {
            let currentURL = AITranslationSettings.proxyServerURL
            let alert = UIAlertController(
                title: "Proxy Server URL",
                message: "Enter your translation proxy URL (e.g. cloudflared tunnel URL)",
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.text = currentURL
                textField.placeholder = "https://api.telegramtranslate.de"
                textField.keyboardType = .URL
                textField.autocapitalizationType = .none
                textField.autocorrectionType = .no
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
                if let newURL = alert.textFields?.first?.text, !newURL.isEmpty {
                    AITranslationSettings.proxyServerURL = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Reset start timestamp so only messages from NOW get translated
                    AITranslationSettings.translationStartTimestamp = Int32(Date().timeIntervalSince1970)
                    AITranslationService.shared.updateProxyClient()
                    // Force an immediate connection check so the user sees the new status
                    // instantly instead of waiting up to 5s for the next scheduled tick.
                    AITranslationService.shared.refreshConnectionStatus()
                    bumpRevision()
                }
            })
            context.sharedContext.mainWindow?.presentNative(alert)
        },
        testConnection: {
            let _ = stateValue.modify { state in
                var state = state
                state.isTesting = true
                return state
            }
            statePromise.set(stateValue.with { $0 })

            let _ = (AITranslationService.shared.testConnection()
            |> deliverOnMainQueue).start(next: { connected in
                let _ = stateValue.modify { state in
                    var state = state
                    state.isConnected = connected
                    state.isTesting = false
                    return state
                }
                statePromise.set(stateValue.with { $0 })
            })
        },
        toggleGlobal: { value in
            AITranslationSettings.enabled = value
            updateAITranslationServiceRegistration()
            bumpRevision()
        },
        toggleIncoming: { value in
            AITranslationSettings.autoTranslateIncoming = value
            bumpRevision()
        },
        toggleOutgoing: { value in
            AITranslationSettings.autoTranslateOutgoing = value
            bumpRevision()
        },
        toggleContextMode: {
            let newMode = AITranslationSettings.contextMode == 1 ? 2 : 1
            AITranslationSettings.contextMode = newMode
            bumpRevision()
        },
        editContextCount: {
            let current = AITranslationSettings.contextMessageCount
            let alert = UIAlertController(
                title: "Context Messages",
                message: "Enter the number of recent messages to include as context",
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.text = "\(current)"
                textField.keyboardType = .numberPad
                textField.placeholder = "e.g. 20"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
                guard let text = alert.textFields?.first?.text,
                      let value = Int(text),
                      value > 0 else {
                    let errorAlert = UIAlertController(
                        title: "Invalid Input",
                        message: "Please enter a positive number",
                        preferredStyle: .alert
                    )
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    context.sharedContext.mainWindow?.presentNative(errorAlert)
                    return
                }
                AITranslationSettings.contextMessageCount = value
                bumpRevision()
            })
            context.sharedContext.mainWindow?.presentNative(alert)
        },
        toggleIncomingContextMode: {
            let newMode = AITranslationSettings.incomingContextMode == 1 ? 2 : 1
            AITranslationSettings.incomingContextMode = newMode
            bumpRevision()
        },
        editIncomingContextCount: {
            let current = AITranslationSettings.incomingContextMessageCount
            let alert = UIAlertController(
                title: "Incoming Context Messages",
                message: "Enter the number of recent messages to include as context for incoming translations",
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.text = "\(current)"
                textField.keyboardType = .numberPad
                textField.placeholder = "e.g. 20"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
                guard let text = alert.textFields?.first?.text,
                      let value = Int(text),
                      value > 0 else {
                    let errorAlert = UIAlertController(
                        title: "Invalid Input",
                        message: "Please enter a positive number",
                        preferredStyle: .alert
                    )
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    context.sharedContext.mainWindow?.presentNative(errorAlert)
                    return
                }
                AITranslationSettings.incomingContextMessageCount = value
                bumpRevision()
            })
            context.sharedContext.mainWindow?.presentNative(alert)
        },
        toggleShowRaw: { value in
            AITranslationSettings.showRawAPIResponses = value
            bumpRevision()
        },
        clearCache: {
            AITranslationService.shared.clearCache()
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let undoController = UndoOverlayController(
                presentationData: presentationData,
                content: .info(
                    title: nil,
                    text: "Translation cache cleared",
                    timeout: nil,
                    customUndoText: nil
                ),
                elevatedLayout: false,
                action: { _ in return false }
            )
            context.sharedContext.mainWindow?.present(undoController, on: .root)
        },
        sendLogs: {
            let entryCount = AILogger.getEntries().count
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            if entryCount == 0 {
                let undo = UndoOverlayController(
                    presentationData: presentationData,
                    content: .info(title: nil, text: "No logs to send", timeout: nil, customUndoText: nil),
                    elevatedLayout: false,
                    action: { _ in return false }
                )
                context.sharedContext.mainWindow?.present(undo, on: .root)
                return
            }
            AILogger.sendToBackend { success in
                let text = success ? "Sent \(entryCount) log entries" : "Failed to send logs"
                let undo = UndoOverlayController(
                    presentationData: presentationData,
                    content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
                    elevatedLayout: false,
                    action: { _ in return false }
                )
                context.sharedContext.mainWindow?.present(undo, on: .root)
            }
        },
        openPromptEditor: { direction in
            let alert = UIAlertController(
                title: "Enter Password",
                message: "Enter the 4-digit PIN to access prompt settings",
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.isSecureTextEntry = true
                textField.keyboardType = .numberPad
                textField.placeholder = "PIN"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                guard let pin = alert.textFields?.first?.text, pin == "4960" else {
                    let errorAlert = UIAlertController(
                        title: "Incorrect PIN",
                        message: nil,
                        preferredStyle: .alert
                    )
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    context.sharedContext.mainWindow?.presentNative(errorAlert)
                    return
                }
                let promptController = aiPromptEditorController(context: context, direction: direction)
                pushControllerImpl?(promptController)
            })
            context.sharedContext.mainWindow?.presentNative(alert)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get(),
        settingsRevision.get()
    )
    |> map { presentationData, state, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = aiSettingsEntries(state: state)
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Translation Proxy"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries.map { $0 },
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)

    // Subscribe to the global connection status — runs independently of this controller
    // (in AITranslationService.shared.startConnectionMonitor) so the status is always
    // up-to-date the moment the tab opens. No more 1-2s flash of "Not Connected".
    let connectionSubDisposable = (AITranslationService.shared.isConnectedPromise.get()
    |> deliverOnMainQueue).start(next: { connected in
        let _ = stateValue.modify { state in
            var state = state
            state.isConnected = connected
            return state
        }
        statePromise.set(stateValue.with { $0 })
    })

    // Ensure the monitor is running (idempotent — no-op if already started at app launch)
    AITranslationService.shared.startConnectionMonitor()

    // Dispose only the local subscription when the controller is popped.
    // DO NOT dispose the global monitor — it must keep running across tab switches.
    controller.didDisappear = { [weak controller] animated in
        if controller?.navigationController == nil {
            connectionSubDisposable.dispose()
        }
    }

    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }

    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }

    return controller
}
