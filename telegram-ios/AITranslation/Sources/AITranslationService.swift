import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext

public final class AITranslationService {
    public static let shared = AITranslationService()

    private let cache = TranslationCache()
    private var proxyClient: AIProxyClient?

    private init() {
        updateProxyClient()
    }

    /// Recreate the proxy client when the URL changes.
    public func updateProxyClient() {
        let url = AITranslationSettings.proxyServerURL
        guard !url.isEmpty else {
            proxyClient = nil
            return
        }
        proxyClient = AIProxyClient(baseURL: url)
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
    /// Used by the outgoing queue to hard-block untranslated messages.
    ///
    /// Two-layer retry:
    /// 1. Backend retries 3x on its side (all error types).
    /// 2. If backend returns explicit failure flag → nil immediately (no iOS retry).
    /// 3. If iOS-side error (network/decode/empty) → iOS retries ONCE more.
    public func translateOutgoingStrict(
        text: String,
        chatId: PeerId,
        context: AccountContext
    ) -> Signal<String?, NoError> {
        guard shouldTranslateOutgoing(chatId: chatId) else {
            return .single(nil)
        }
        if proxyClient == nil {
            updateProxyClient()
        }
        guard let client = proxyClient else {
            return .single(nil)
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

        let chatIdInt = chatId.id._internalGetInt64Value()

        return contextSignal
        |> mapToSignal { contextMessages -> Signal<String?, NoError> in
            return client.translateStrictDetailed(
                text: text,
                direction: "outgoing",
                chatId: chatIdInt,
                context: contextMessages
            )
            |> mapToSignal { result -> Signal<String?, NoError> in
                switch result {
                case .success(let translatedText):
                    return .single(translatedText)
                case .backendFailure:
                    // Backend already retried 3x and gave up — no iOS retry
                    return .single(nil)
                case .iosError:
                    // iOS-side error (network/decode/empty) — retry once
                    return client.translateStrictDetailed(
                        text: text,
                        direction: "outgoing",
                        chatId: chatIdInt,
                        context: contextMessages
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
                // iOS-side error — retry once instantly
                return client.translateStrictDetailed(
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
