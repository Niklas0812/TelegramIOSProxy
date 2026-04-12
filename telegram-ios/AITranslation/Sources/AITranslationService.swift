import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext

public final class AITranslationService {
    public static let shared = AITranslationService()

    private let cache = TranslationCache()
    private var proxyClient: AIProxyClient?

    // MARK: - Global Connection Status

    /// Observable current connection status. UI subscribes to this for live updates.
    /// The value is kept fresh by `startConnectionMonitor()` which runs a 5-second
    /// health check loop independently of any UI controller.
    public let isConnectedPromise = ValuePromise<Bool>(false, ignoreRepeated: true)

    private let connectionMonitorDisposable = MetaDisposable()
    private let connectionCheckDisposable = MetaDisposable()
    private var connectionMonitorStarted = false

    private init() {
        // Trigger AILogger lifecycle observer setup
        _ = AILogger.shared
        AILogger.log("AITranslationService INIT — url='\(AITranslationSettings.proxyServerURL)' enabled=\(AITranslationSettings.enabled) outgoing=\(AITranslationSettings.autoTranslateOutgoing) contextMode=\(AITranslationSettings.contextMode)")
        updateProxyClient()
    }

    /// Recreate the proxy client when the URL changes.
    public func updateProxyClient() {
        let url = AITranslationSettings.proxyServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            proxyClient = nil
            return
        }
        proxyClient = AIProxyClient(baseURL: url)
    }

    // MARK: - Connection Monitor

    /// Start the global 5-second health check loop. Safe to call multiple times —
    /// only the first call has effect. Idempotent.
    ///
    /// Runs at the singleton level so the connection status is always current,
    /// regardless of which Telegram tab is active. UI controllers subscribe to
    /// `isConnectedPromise` to display the result.
    public func startConnectionMonitor() {
        guard !connectionMonitorStarted else { return }
        connectionMonitorStarted = true

        AILogger.log("CONN-MONITOR: starting global 5s health check loop")

        let performCheck: () -> Void = { [weak self] in
            guard let self = self else { return }
            // MetaDisposable.set() cancels any previous in-flight check automatically.
            // If the server is hanging, the old request is cancelled and a fresh one starts.
            self.connectionCheckDisposable.set((self.testConnection()
            |> deliverOnMainQueue).start(next: { connected in
                self.isConnectedPromise.set(connected)
            }))
        }

        // Initial check immediately
        performCheck()

        // Repeating timer every 5 seconds
        connectionMonitorDisposable.set((Signal<Void, NoError>.single(Void())
        |> delay(5.0, queue: Queue.mainQueue())
        |> restart).start(next: { _ in
            performCheck()
        }))
    }

    /// Force an immediate connection check. Used after the user saves a new proxy URL
    /// so the status updates instantly instead of waiting up to 5 seconds for the next tick.
    public func refreshConnectionStatus() {
        guard connectionMonitorStarted else {
            startConnectionMonitor()
            return
        }
        connectionCheckDisposable.set((self.testConnection()
        |> deliverOnMainQueue).start(next: { [weak self] connected in
            self?.isConnectedPromise.set(connected)
        }))
    }

    // MARK: - Outgoing Translation (EN → DE)

    /// Translates outgoing message text before it is sent.
    /// Returns the translated text, or the original text on any failure.
    public func translateOutgoing(
        text: String,
        chatId: PeerId,
        context: AccountContext
    ) -> Signal<String, NoError> {
        guard shouldTranslateOutgoing(chatId: chatId) else {
            return .single(text)
        }
        if proxyClient == nil { updateProxyClient() }
        guard let client = proxyClient else {
            return .single(text)
        }

        let contextSignal: Signal<[AIContextMessage], NoError>
        if AITranslationSettings.contextMode == 2 {
            contextSignal = ConversationContextProvider.getContext(
                chatId: chatId,
                context: context
            )
        } else {
            contextSignal = .single([])
        }

        return contextSignal
        |> mapToSignal { contextMessages -> Signal<String, NoError> in
            return client.translate(
                text: text,
                direction: "outgoing",
                chatId: chatId.id._internalGetInt64Value(),
                context: contextMessages
            )
        }
    }

    /// Strict outgoing translation — returns nil on ANY failure.
    // MARK: - Outgoing Translation Result

    public enum OutgoingTranslationResult {
        case success(String)         // Translated text — send it
        case passthrough(String)     // shouldTranslateOutgoing=false — send original
        case translationFailed       // Generic failure — show "Translation failed" popup
        case userClaimed             // Target user claimed by another account
    }

    /// Used by the outgoing queue to hard-block untranslated messages.
    ///
    /// Two-layer retry:
    /// 1. Backend retries 3x on its side (all error types).
    /// 2. If backend returns explicit failure flag → nil immediately (no iOS retry).
    /// 3. If iOS-side error (network/decode/empty) → iOS retries ONCE more.
    /// 4. If backend returns user_claimed=true → immediate .userClaimed (no retry).
    public func translateOutgoingStrict(
        text: String,
        chatId: PeerId,
        context: AccountContext
    ) -> Signal<OutgoingTranslationResult, NoError> {
        let chatIdInt = chatId.id._internalGetInt64Value()
        let senderAccountId = context.account.peerId.id._internalGetInt64Value()
        let textPreview = String(text.prefix(40))

        guard shouldTranslateOutgoing(chatId: chatId) else {
            AILogger.log("OUT SKIP: shouldTranslate=false chat=\(chatIdInt) — returning original")
            return .single(.passthrough(text))
        }
        if proxyClient == nil {
            AILogger.log("OUT: proxyClient nil, calling updateProxyClient()")
            updateProxyClient()
        }
        guard let client = proxyClient else {
            AILogger.log("OUT E1: proxyClient STILL nil — url='\(AITranslationSettings.proxyServerURL)'")
            return .single(.translationFailed)
        }

        let contextSignal: Signal<[AIContextMessage], NoError>
        if AITranslationSettings.contextMode == 2 {
            AILogger.log("OUT: fetching context (mode=2) chat=\(chatIdInt)")
            contextSignal = ConversationContextProvider.getContext(
                chatId: chatId,
                context: context
            )
        } else {
            contextSignal = .single([])
        }

        AILogger.log("OUT START: chat=\(chatIdInt) sender=\(senderAccountId) text='\(textPreview)'")

        return contextSignal
        |> mapToSignal { contextMessages -> Signal<OutgoingTranslationResult, NoError> in
            AILogger.log("OUT: context ready (\(contextMessages.count) msgs), firing HTTP...")
            return client.translateStrictDetailed(
                text: text,
                direction: "outgoing",
                chatId: chatIdInt,
                senderAccountId: senderAccountId,
                context: contextMessages
            )
            |> mapToSignal { result -> Signal<OutgoingTranslationResult, NoError> in
                switch result {
                case .success(let translatedText):
                    AILogger.log("OUT OK: '\(textPreview)' -> '\(String(translatedText.prefix(40)))'")
                    return .single(.success(translatedText))
                case .userClaimed:
                    AILogger.log("OUT CLAIMED: target=\(chatIdInt) sender=\(senderAccountId)")
                    return .single(.userClaimed)
                case .backendFailure:
                    AILogger.log("OUT E2: backendFailure text='\(textPreview)'")
                    return .single(.translationFailed)
                case .iosError:
                    AILogger.log("OUT: iosError on 1st attempt, retrying with fresh client...")
                    self.updateProxyClient()
                    guard let freshClient = self.proxyClient else {
                        AILogger.log("OUT E3: freshClient nil after update")
                        return .single(.translationFailed)
                    }
                    return freshClient.translateStrictDetailed(
                        text: text,
                        direction: "outgoing",
                        chatId: chatIdInt,
                        senderAccountId: senderAccountId,
                        context: contextMessages
                    )
                    |> map { retryResult -> OutgoingTranslationResult in
                        switch retryResult {
                        case .success(let retryText):
                            AILogger.log("OUT OK(retry): '\(textPreview)' -> '\(String(retryText.prefix(40)))'")
                            return .success(retryText)
                        case .userClaimed:
                            AILogger.log("OUT CLAIMED(retry): target=\(chatIdInt)")
                            return .userClaimed
                        default:
                            AILogger.log("OUT E4: retry failed text='\(textPreview)'")
                            return .translationFailed
                        }
                    }
                }
            }
        }
    }

    // MARK: - Incoming Translation (DE → EN)

    /// Translates incoming message text for display.
    /// Returns the translated text, or the original text on any failure.
    /// Results are cached by MessageId.
    public func translateIncoming(
        text: String,
        messageId: MessageId,
        chatId: PeerId,
        context: AccountContext
    ) -> Signal<String, NoError> {
        // Check cache first
        if let cached = cache.get(messageId) {
            return .single(cached)
        }

        guard shouldTranslateIncoming(chatId: chatId) else {
            return .single(text)
        }
        if proxyClient == nil { updateProxyClient() }
        guard let client = proxyClient else {
            return .single(text)
        }

        let contextSignal: Signal<[AIContextMessage], NoError>
        if AITranslationSettings.incomingContextMode == 2 {
            contextSignal = ConversationContextProvider.getContext(
                chatId: chatId,
                context: context,
                direction: "incoming"
            )
        } else {
            contextSignal = .single([])
        }

        return contextSignal
        |> mapToSignal { contextMessages -> Signal<String, NoError> in
            return client.translate(
                text: text,
                direction: "incoming",
                chatId: chatId.id._internalGetInt64Value(),
                context: contextMessages
            )
        }
        |> map { [weak self] translatedText -> String in
            self?.cache.set(messageId, translation: translatedText)
            return translatedText
        }
    }

    /// Translates a single incoming message with conversation context (used by background observer).
    public func translateIncomingWithContext(
        text: String,
        chatId: PeerId,
        context: [AIContextMessage]
    ) -> Signal<String, NoError> {
        guard let client = proxyClient else {
            return .single(text)
        }
        return client.translate(
            text: text,
            direction: "incoming",
            chatId: chatId.id._internalGetInt64Value(),
            context: context
        )
    }

    /// Strict incoming translation — returns nil on ANY failure.
    /// Used by the background observer for both real-time and catch-up.
    ///
    /// On iOS-side error (network/decode/empty): retries ONCE instantly.
    /// On backend failure flag: nil immediately (backend already retried 3x).
    /// Returns nil = don't store anything, message stays in original language.
    public func translateIncomingStrict(
        text: String,
        chatId: PeerId,
        context: [AIContextMessage]
    ) -> Signal<String?, NoError> {
        guard let client = proxyClient else {
            return .single(nil)
        }
        let chatIdInt = chatId.id._internalGetInt64Value()
        return client.translateStrictDetailed(
            text: text,
            direction: "incoming",
            chatId: chatIdInt,
            context: context
        )
        |> mapToSignal { result -> Signal<String?, NoError> in
            switch result {
            case .success(let translatedText):
                return .single(translatedText)
            case .backendFailure:
                // Backend already retried 3x and gave up — no iOS retry
                return .single(nil)
            case .iosError:
                // iOS-side error — recreate client with fresh URLSession then retry once
                self.updateProxyClient()
                guard let freshClient = self.proxyClient else { return .single(nil) }
                return freshClient.translateStrictDetailed(
                    text: text,
                    direction: "incoming",
                    chatId: chatIdInt,
                    context: context
                )
                |> map { retryResult -> String? in
                    if case .success(let retryText) = retryResult {
                        return retryText
                    }
                    return nil
                }
            }
        }
    }

    // MARK: - Batch Translation for ExperimentalInternalTranslationService

    /// Translates a batch of texts for the built-in translation system.
    /// Uses the /translate/batch endpoint for a single HTTP request.
    public func translateTexts(
        texts: [AnyHashable: String],
        fromLang: String,
        toLang: String
    ) -> Signal<[AnyHashable: String]?, NoError> {
        guard AITranslationSettings.enabled,
              let client = proxyClient else {
            return .single(texts)
        }

        let direction: String
        if toLang.hasPrefix("en") {
            direction = "incoming"
        } else {
            direction = "outgoing"
        }

        // Build batch items with string IDs for round-tripping
        var keyMap: [String: AnyHashable] = [:]
        var batchItems: [AIBatchTextItem] = []
        for (index, (key, text)) in texts.enumerated() {
            let id = "\(index)"
            keyMap[id] = key
            batchItems.append(AIBatchTextItem(id: id, text: text, direction: direction))
        }

        return client.translateBatch(items: batchItems)
        |> map { results -> [AnyHashable: String]? in
            if results.isEmpty && !texts.isEmpty {
                // Batch endpoint failed entirely, return nil to signal failure
                return nil
            }
            var dict: [AnyHashable: String] = [:]
            for result in results {
                if let key = keyMap[result.id], !result.translationFailed {
                    dict[key] = result.translatedText
                }
            }
            // Return whatever succeeded; missing keys = failed translations
            // Return nil if nothing succeeded so callers know it all failed
            return dict.isEmpty ? nil : dict
        }
    }

    // MARK: - Per-Chat Toggle

    public func isEnabledForChat(_ peerId: PeerId) -> Bool {
        let chatId = peerId.id._internalGetInt64Value()
        return AITranslationSettings.enabledChatIds.contains(chatId)
    }

    public func toggleChat(_ peerId: PeerId) {
        let chatId = peerId.id._internalGetInt64Value()
        var ids = AITranslationSettings.enabledChatIds
        if let index = ids.firstIndex(of: chatId) {
            ids.remove(at: index)
        } else {
            ids.append(chatId)
        }
        AITranslationSettings.enabledChatIds = ids
    }

    // MARK: - Cache Management

    public func clearCache() {
        cache.clear()
        AIStorageCache.clear()
        updateProxyClient()
    }

    // MARK: - System Prompt

    public func getPrompt(direction: String) -> Signal<String, NoError> {
        guard let client = proxyClient else {
            return .single("")
        }
        return client.getPrompt(direction: direction)
    }

    public func setPrompt(_ prompt: String, direction: String) -> Signal<Bool, NoError> {
        guard let client = proxyClient else {
            return .single(false)
        }
        return client.setPrompt(prompt, direction: direction)
    }

    // MARK: - Connection Test

    public func testConnection() -> Signal<Bool, NoError> {
        if proxyClient == nil { updateProxyClient() }
        guard let client = proxyClient else {
            return .single(false)
        }
        return client.healthCheck()
    }

    // MARK: - Private

    private func shouldTranslateOutgoing(chatId: PeerId) -> Bool {
        guard AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing else {
            return false
        }
        // If per-chat list is empty, translate all chats (default behavior)
        // If per-chat list has entries, only translate those specific chats
        let perChatIds = AITranslationSettings.enabledChatIds
        if perChatIds.isEmpty {
            return true
        }
        return perChatIds.contains(chatId.id._internalGetInt64Value())
    }

    private func shouldTranslateIncoming(chatId: PeerId) -> Bool {
        guard AITranslationSettings.enabled && AITranslationSettings.autoTranslateIncoming else {
            return false
        }
        let perChatIds = AITranslationSettings.enabledChatIds
        if perChatIds.isEmpty {
            return true
        }
        return perChatIds.contains(chatId.id._internalGetInt64Value())
    }
}
