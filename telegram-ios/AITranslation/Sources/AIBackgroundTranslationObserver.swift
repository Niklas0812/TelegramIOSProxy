import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext

/// Observes incoming messages at the data layer and pre-translates them
/// so translations are available before the user opens the chat.
///
/// Three mechanisms:
/// 1. Primary: `aiNewIncomingMessagesCallback` from AccountStateManager — fires for ALL new incoming messages
///    (bypasses notification filtering that excludes muted chats).
/// 2. Secondary: `notificationMessages` subscription — catches notification-worthy messages.
/// 3. Catch-up: `translateMessages(peerId:context:)` scans recent messages when a chat opens.
public final class AIBackgroundTranslationObserver {
    private static var shared: AIBackgroundTranslationObserver?
    private static var storedContext: AccountContext?
    /// Use the persisted translationStartTimestamp (set when URL is saved).
    /// Falls back to app launch time if never set (0).
    private static var startTimestamp: Int32 {
        let saved = AITranslationSettings.translationStartTimestamp
        return saved > 0 ? saved : Int32(Date().timeIntervalSince1970)
    }

    /// Retry delays in seconds for failed translations
    private static let retryDelays: [Double] = [2.0, 5.0, 10.0]

    /// Track message IDs currently being translated to prevent duplicate requests
    private static var inFlightMessageIds = Set<MessageId>()
    /// Track per-peer catch-up to prevent duplicate translateMessages calls
    private static var catchUpInProgress = Set<PeerId>()

    /// Call once when an authorized account is available.
    public static func startIfNeeded(context: AccountContext) {
        guard shared == nil else { return }
        storedContext = context
        shared = AIBackgroundTranslationObserver(context: context)

        // Register the callback from AccountStateManager for ALL incoming messages.
        // This bypasses notificationMessages filtering (muted chats, etc.).
        aiNewIncomingMessagesCallback = { messageIds in
            Self.translateMessageIds(messageIds)
        }
    }

    // MARK: - Primary: Translate by Message IDs (from AccountStateManager callback)

    /// Called by `aiNewIncomingMessagesCallback` for every new real-time incoming message.
    /// Reads messages from Postbox, filters, batch translates, and stores results.
    private static func translateMessageIds(_ ids: [MessageId]) {
        guard AITranslationSettings.enabled, AITranslationSettings.autoTranslateIncoming else { return }
        guard let context = storedContext else { return }
        guard !ids.isEmpty else { return }

        // Skip IDs already in-flight
        let newIds = ids.filter { !inFlightMessageIds.contains($0) }
        guard !newIds.isEmpty else { return }

        let accountPeerId = context.account.peerId
        let startTs = startTimestamp

        let _ = (context.account.postbox.transaction { transaction -> [(MessageId, String, PeerId)] in
            var toTranslate: [(MessageId, String, PeerId)] = []
            for id in newIds {
                guard let message = transaction.getMessage(id) else { continue }
                // Only translate: incoming, after URL was configured, non-empty, not already translated
                if message.author?.id != accountPeerId,
                   message.timestamp >= startTs,
                   !message.text.isEmpty,
                   !message.attributes.contains(where: { $0 is TranslationMessageAttribute }) {
                    toTranslate.append((message.id, message.text, message.id.peerId))
                }
            }
            return toTranslate
        }
        |> deliverOnMainQueue
        |> mapToSignal { toTranslate -> Signal<Void, NoError> in
            guard !toTranslate.isEmpty else { return .complete() }

            // Mark as in-flight
            for (msgId, _, _) in toTranslate {
                Self.inFlightMessageIds.insert(msgId)
            }

            if AITranslationSettings.incomingContextMode == 2 {
                return Self.translateWithContext(messages: toTranslate, context: context)
            } else {
                return Self.translateBatchMessages(messages: toTranslate, context: context)
            }
        }).start()
    }

    // MARK: - Batch Translation (no context)

    private static func translateBatchMessages(messages: [(MessageId, String, PeerId)], context: AccountContext) -> Signal<Void, NoError> {
        var textDict: [AnyHashable: String] = [:]
        var idMap: [String: MessageId] = [:]
        for (i, (msgId, text, _)) in messages.enumerated() {
            let key = "\(i)"
            textDict[key as AnyHashable] = text
            idMap[key] = msgId
        }

        return AITranslationService.shared.translateTexts(texts: textDict, fromLang: "de", toLang: "en")
        |> mapToSignal { results -> Signal<Void, NoError> in
            // Clear in-flight tracking
            DispatchQueue.main.async {
                for (msgId, _, _) in messages {
                    Self.inFlightMessageIds.remove(msgId)
                }
            }

            guard let results = results else {
                // All failed (network error / timeout), schedule retry
                print("[AITranslation] Batch translation returned nil, scheduling retry for \(messages.count) messages")
                Self.scheduleRetry(ids: messages.map { $0.0 }, attempt: 0, context: context)
                return .complete()
            }
            return context.account.postbox.transaction { transaction in
                var failedIds: [MessageId] = []
                for (key, msgId) in idMap {
                    if let translatedText = results[key as AnyHashable] {
                        // Store translation even if identical to original (message was already
                        // in target language). This prevents infinite re-translation loops.
                        Self.storeTranslation(transaction: transaction, msgId: msgId, translatedText: translatedText)
                    } else {
                        failedIds.append(msgId)
                    }
                }
                if !failedIds.isEmpty {
                    print("[AITranslation] \(failedIds.count) translations failed, scheduling retry")
                    DispatchQueue.main.async {
                        Self.scheduleRetry(ids: failedIds, attempt: 0, context: context)
                    }
                }
            } |> map { _ in }
        }
    }

    // MARK: - Context-Aware Translation (individual requests with conversation context)

    private static func translateWithContext(messages: [(MessageId, String, PeerId)], context: AccountContext) -> Signal<Void, NoError> {
        // Group by peerId (chat)
        var chatGroups: [PeerId: [(MessageId, String)]] = [:]
        for (msgId, text, peerId) in messages {
            chatGroups[peerId, default: []].append((msgId, text))
        }

        var signals: [Signal<Void, NoError>] = []

        for (peerId, chatMessages) in chatGroups {
            let chatSignal = ConversationContextProvider.getContext(
                chatId: peerId,
                context: context,
                direction: "incoming"
            )
            |> mapToSignal { contextMessages -> Signal<Void, NoError> in
                // Translate each message individually with context
                let translateSignals: [Signal<(MessageId, String)?, NoError>] = chatMessages.map { (msgId, text) in
                    return AITranslationService.shared.translateIncomingWithContext(
                        text: text,
                        chatId: peerId,
                        context: contextMessages
                    )
                    |> map { translatedText -> (MessageId, String)? in
                        // Always return result, even if identical — store to prevent re-translation
                        return (msgId, translatedText)
                    }
                }

                return combineLatest(translateSignals)
                |> mapToSignal { results -> Signal<Void, NoError> in
                    let succeeded = results.compactMap { $0 }

                    let storeSignal: Signal<Void, NoError> = succeeded.isEmpty ? .complete() :
                        context.account.postbox.transaction { transaction in
                            for (msgId, translatedText) in succeeded {
                                Self.storeTranslation(transaction: transaction, msgId: msgId, translatedText: translatedText)
                            }
                        } |> map { _ in }

                    return storeSignal
                }
            }
            signals.append(chatSignal)
        }

        return combineLatest(signals) |> map { _ in }
    }

    // MARK: - Retry Mechanism

    private static func scheduleRetry(ids: [MessageId], attempt: Int, context: AccountContext) {
        guard attempt < retryDelays.count else {
            print("[AITranslation] All \(retryDelays.count) retries exhausted for \(ids.count) messages")
            return
        }
        let delay = retryDelays[attempt]
        print("[AITranslation] Scheduling retry \(attempt + 1)/\(retryDelays.count) for \(ids.count) messages in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let _ = (context.account.postbox.transaction { transaction -> [(MessageId, String, PeerId)] in
                var toRetry: [(MessageId, String, PeerId)] = []
                for id in ids {
                    guard let message = transaction.getMessage(id) else { continue }
                    if !message.text.isEmpty,
                       !message.attributes.contains(where: { $0 is TranslationMessageAttribute }) {
                        toRetry.append((id, message.text, id.peerId))
                    }
                }
                return toRetry
            }
            |> deliverOnMainQueue
            |> mapToSignal { toRetry -> Signal<Void, NoError> in
                guard !toRetry.isEmpty else {
                    print("[AITranslation] Retry \(attempt + 1): all messages already translated")
                    return .complete()
                }
                print("[AITranslation] Retry \(attempt + 1): retrying \(toRetry.count) messages")

                if AITranslationSettings.incomingContextMode == 2 {
                    return Self.translateWithContextRetry(messages: toRetry, attempt: attempt, context: context)
                } else {
                    return Self.translateBatchRetry(messages: toRetry, attempt: attempt, context: context)
                }
            }).start()
        }
    }

    private static func translateBatchRetry(messages: [(MessageId, String, PeerId)], attempt: Int, context: AccountContext) -> Signal<Void, NoError> {
        var textDict: [AnyHashable: String] = [:]
        var idMap: [String: MessageId] = [:]
        for (i, (msgId, text, _)) in messages.enumerated() {
            let key = "\(i)"
            textDict[key as AnyHashable] = text
            idMap[key] = msgId
        }

        return AITranslationService.shared.translateTexts(texts: textDict, fromLang: "de", toLang: "en")
        |> mapToSignal { results -> Signal<Void, NoError> in
            guard let results = results else {
                Self.scheduleRetry(ids: messages.map { $0.0 }, attempt: attempt + 1, context: context)
                return .complete()
            }
            return context.account.postbox.transaction { transaction in
                var stillFailed: [MessageId] = []
                for (key, msgId) in idMap {
                    if let translatedText = results[key as AnyHashable] {
                        // Store even if identical to original — prevents re-translation loops
                        Self.storeTranslation(transaction: transaction, msgId: msgId, translatedText: translatedText)
                    } else {
                        stillFailed.append(msgId)
                    }
                }
                if !stillFailed.isEmpty {
                    DispatchQueue.main.async {
                        Self.scheduleRetry(ids: stillFailed, attempt: attempt + 1, context: context)
                    }
                }
            } |> map { _ in }
        }
    }

    private static func translateWithContextRetry(messages: [(MessageId, String, PeerId)], attempt: Int, context: AccountContext) -> Signal<Void, NoError> {
        var chatGroups: [PeerId: [(MessageId, String)]] = [:]
        for (msgId, text, peerId) in messages {
            chatGroups[peerId, default: []].append((msgId, text))
        }

        var signals: [Signal<Void, NoError>] = []

        for (peerId, chatMessages) in chatGroups {
            let chatSignal = ConversationContextProvider.getContext(
                chatId: peerId,
                context: context,
                direction: "incoming"
            )
            |> mapToSignal { contextMessages -> Signal<Void, NoError> in
                let translateSignals: [Signal<(MessageId, String)?, NoError>] = chatMessages.map { (msgId, text) in
                    return AITranslationService.shared.translateIncomingWithContext(
                        text: text,
                        chatId: peerId,
                        context: contextMessages
                    )
                    |> map { translatedText -> (MessageId, String)? in
                        return (msgId, translatedText)
                    }
                }

                return combineLatest(translateSignals)
                |> mapToSignal { results -> Signal<Void, NoError> in
                    let succeeded = results.compactMap { $0 }

                    let storeSignal: Signal<Void, NoError> = succeeded.isEmpty ? .complete() :
                        context.account.postbox.transaction { transaction in
                            for (msgId, translatedText) in succeeded {
                                Self.storeTranslation(transaction: transaction, msgId: msgId, translatedText: translatedText)
                            }
                        } |> map { _ in }

                    return storeSignal
                }
            }
            signals.append(chatSignal)
        }

        return combineLatest(signals) |> map { _ in }
    }

    // MARK: - Streaming Individual Translation (for catch-up)

    /// Fires N individual /translate requests concurrently. Each result is stored
    /// in Postbox immediately upon completion — translations appear one-by-one
    /// in the chat as they arrive, rather than all at once after a long wait.
    private static func translateIndividuallyStreaming(
        messages: [(MessageId, String, PeerId)],
        context: AccountContext,
        onAllComplete: @escaping () -> Void
    ) {
        guard !messages.isEmpty else {
            onAllComplete()
            return
        }

        let total = messages.count
        var completedCount = 0

        let useContext = AITranslationSettings.incomingContextMode == 2

        if useContext {
            // Fetch context once per peer, then fire individual requests
            let peerIds = Set(messages.map { $0.2 })
            let contextSignals: [Signal<(PeerId, [AIContextMessage]), NoError>] = peerIds.map { peerId in
                ConversationContextProvider.getContext(
                    chatId: peerId,
                    context: context,
                    direction: "incoming"
                ) |> map { ctx in (peerId, ctx) }
            }

            let _ = (combineLatest(contextSignals)
            |> map { pairs in Dictionary(uniqueKeysWithValues: pairs) }
            |> deliverOnMainQueue).start(next: { contextByPeer in
                for (msgId, text, peerId) in messages {
                    let ctxMessages = contextByPeer[peerId] ?? []
                    let _ = (AITranslationService.shared.translateIncomingWithContext(
                        text: text, chatId: peerId, context: ctxMessages
                    )
                    |> mapToSignal { translatedText -> Signal<Void, NoError> in
                        return context.account.postbox.transaction { transaction in
                            Self.storeTranslation(transaction: transaction, msgId: msgId, translatedText: translatedText)
                        } |> map { _ in }
                    }
                    |> deliverOnMainQueue).start(completed: {
                        Self.inFlightMessageIds.remove(msgId)
                        completedCount += 1
                        if completedCount == total {
                            onAllComplete()
                        }
                    })
                }
            })
        } else {
            // No context: fire individual requests directly
            for (msgId, text, peerId) in messages {
                let _ = (AITranslationService.shared.translateIncomingWithContext(
                    text: text, chatId: peerId, context: []
                )
                |> mapToSignal { translatedText -> Signal<Void, NoError> in
                    return context.account.postbox.transaction { transaction in
                        Self.storeTranslation(transaction: transaction, msgId: msgId, translatedText: translatedText)
                    } |> map { _ in }
                }
                |> deliverOnMainQueue).start(completed: {
                    Self.inFlightMessageIds.remove(msgId)
                    completedCount += 1
                    if completedCount == total {
                        onAllComplete()
                    }
                })
            }
        }
    }

    // MARK: - Catch-Up Translation

    /// Scan recent messages in a chat and translate ALL messages (both incoming
    /// and the user's own outgoing) that don't have a TranslationMessageAttribute yet.
    /// All messages use the Incoming System Prompt (DE → EN) since own messages are
    /// already stored in German on the server after outgoing translation.
    ///
    /// Translations stream back one-by-one (each displayed immediately) rather than
    /// waiting for the entire batch. Messages are processed newest-first so the
    /// bottom of the chat (what the user sees) translates first.
    public static func translateMessages(peerId: PeerId, context: AccountContext) {
        guard AITranslationSettings.enabled, AITranslationSettings.autoTranslateIncoming else { return }

        // Prevent duplicate catch-up for the same chat
        guard !catchUpInProgress.contains(peerId) else {
            print("[AITranslation] Catch-up already in progress for \(peerId), skipping")
            return
        }
        catchUpInProgress.insert(peerId)

        let minTs = startTimestamp

        let _ = (context.account.postbox.transaction { transaction -> [(MessageId, String, Int32)] in
            var toTranslate: [(MessageId, String, Int32)] = []
            transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: 100) { message in
                // Translate ALL messages (both incoming and own) after URL was configured
                if message.timestamp >= minTs,
                   !message.text.isEmpty,
                   !Self.inFlightMessageIds.contains(message.id) {
                    let existingAttr = message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute
                    // Translate if: no attribute, OR attribute text matches original (poisoned by empty pipeline)
                    if existingAttr == nil || existingAttr?.text == message.text {
                        toTranslate.append((message.id, message.text, message.timestamp))
                    }
                }
                return true
            }
            // Sort newest first — most recent messages get dispatched first
            toTranslate.sort { $0.2 > $1.2 }
            return toTranslate
        }
        |> deliverOnMainQueue).start(next: { toTranslate in
            guard !toTranslate.isEmpty else {
                Self.catchUpInProgress.remove(peerId)
                return
            }

            print("[AITranslation] Catch-up: streaming \(toTranslate.count) messages for \(peerId) (newest first)")

            // Mark all as in-flight
            for (msgId, _, _) in toTranslate {
                Self.inFlightMessageIds.insert(msgId)
            }

            // Fire individual requests concurrently — each stores result immediately
            let messages = toTranslate.map { ($0.0, $0.1, peerId) }
            Self.translateIndividuallyStreaming(
                messages: messages,
                context: context,
                onAllComplete: {
                    Self.catchUpInProgress.remove(peerId)
                    print("[AITranslation] Catch-up completed: \(toTranslate.count) messages for \(peerId)")
                }
            )
        })
    }

    // MARK: - Secondary: notificationMessages Observer

    private let disposable = MetaDisposable()

    private init(context: AccountContext) {
        let accountPeerId = context.account.peerId

        disposable.set((context.account.stateManager.notificationMessages
        |> deliverOn(Queue.mainQueue())).start(next: { messageList in
            guard AITranslationSettings.enabled, AITranslationSettings.autoTranslateIncoming else { return }
            let minTs = Self.startTimestamp

            for (messages, _, _, _) in messageList {
                var toTranslate: [(MessageId, String, PeerId)] = []
                for message in messages {
                    guard message.author?.id != accountPeerId,
                          message.timestamp >= minTs,
                          !message.text.isEmpty,
                          !message.attributes.contains(where: { $0 is TranslationMessageAttribute }),
                          !Self.inFlightMessageIds.contains(message.id)
                    else { continue }
                    Self.inFlightMessageIds.insert(message.id)
                    toTranslate.append((message.id, message.text, message.id.peerId))
                }
                guard !toTranslate.isEmpty else { continue }

                if AITranslationSettings.incomingContextMode == 2 {
                    let _ = Self.translateWithContext(messages: toTranslate, context: context).start()
                } else {
                    let _ = Self.translateBatchMessages(messages: toTranslate, context: context).start()
                }
            }
        }))
    }

    deinit {
        disposable.dispose()
    }

    // MARK: - Shared Storage Logic

    private static func storeTranslation(transaction: Transaction, msgId: MessageId, translatedText: String) {
        transaction.updateMessage(msgId, update: { currentMessage in
            var attributes = currentMessage.attributes
            // Remove any existing TranslationMessageAttribute (may be poisoned by empty pipeline
            // which stored original text as "translation") — always overwrite with real translation
            attributes.removeAll(where: { $0 is TranslationMessageAttribute })
            attributes.append(TranslationMessageAttribute(text: translatedText, entities: [], toLang: "en"))

            var storeForwardInfo: StoreMessageForwardInfo?
            if let info = currentMessage.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(
                    authorId: info.author?.id,
                    sourceId: info.source?.id,
                    sourceMessageId: info.sourceMessageId,
                    date: info.date,
                    authorSignature: info.authorSignature,
                    psaType: info.psaType,
                    flags: info.flags
                )
            }

            return .update(StoreMessage(
                id: currentMessage.id,
                globallyUniqueId: currentMessage.globallyUniqueId,
                groupingKey: currentMessage.groupingKey,
                threadId: currentMessage.threadId,
                timestamp: currentMessage.timestamp,
                flags: StoreMessageFlags(currentMessage.flags),
                tags: currentMessage.tags,
                globalTags: currentMessage.globalTags,
                localTags: currentMessage.localTags,
                forwardInfo: storeForwardInfo,
                authorId: currentMessage.author?.id,
                text: currentMessage.text,
                attributes: attributes,
                media: currentMessage.media
            ))
        })
    }
}
