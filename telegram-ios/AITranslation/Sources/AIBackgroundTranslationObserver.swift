import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext

/// Observes incoming messages at the data layer and pre-translates them
/// so translations are available before the user opens the chat.
///
/// Two mechanisms:
/// 1. Primary: `aiNewIncomingMessagesCallback` from AccountStateManager — fires for ALL new incoming messages
///    (bypasses notification filtering that excludes muted chats).
/// 2. Catch-up: `translateMessages(peerId:context:)` scans recent messages when a chat opens.
///
/// All translation uses individual requests with `translateIncomingStrict()`:
/// - Failure detection via `StrictTranslationResult` (backend flag vs iOS error)
/// - 1 instant retry on iOS-side errors
/// - On final failure: stores nothing — message stays in original language
/// - On next chat open: catch-up picks up untranslated messages automatically
public final class AIBackgroundTranslationObserver {
    private static var shared: AIBackgroundTranslationObserver?
    private static var storedContext: AccountContext?
    /// Use the persisted translationStartTimestamp (set when URL is saved).
    /// Falls back to app launch time if never set (0).
    private static var startTimestamp: Int32 {
        let saved = AITranslationSettings.translationStartTimestamp
        return saved > 0 ? saved : Int32(Date().timeIntervalSince1970)
    }

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
    /// Reads messages from Postbox, filters, and translates individually.
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

            Self.translateIndividuallyWithRetry(
                messages: toTranslate,
                context: context,
                onAllComplete: {}
            )
            return .complete()
        }).start()
    }

    // MARK: - Unified Individual Translation (real-time + catch-up)

    /// Fires N individual /translate requests concurrently. Each uses translateIncomingStrict()
    /// which detects failures and retries once. On final failure, stores nothing — message
    /// stays in original language and will be picked up by catch-up on next chat open.
    ///
    /// Works identically for context ON and OFF, real-time and catch-up.
    private static func translateIndividuallyWithRetry(
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

        let doTranslate = { (msgs: [(MessageId, String, PeerId)], ctxByPeer: [PeerId: [AIContextMessage]]) in
            for (msgId, text, peerId) in msgs {
                let ctxMessages = ctxByPeer[peerId] ?? []
                let _ = (AITranslationService.shared.translateIncomingStrict(
                    text: text, chatId: peerId, context: ctxMessages
                )
                |> mapToSignal { translatedText -> Signal<Void, NoError> in
                    guard let translatedText = translatedText else {
                        // Failed after retry — store nothing, message stays in original language
                        print("[AITranslation] Translation failed for msg \(msgId), leaving untranslated")
                        return .complete()
                    }
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
                doTranslate(messages, contextByPeer)
            })
        } else {
            // No context: fire individual requests directly
            doTranslate(messages, [:])
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
    ///
    /// Messages that failed translation previously have no TranslationMessageAttribute,
    /// so they are automatically picked up here on every chat open.
    public static func translateMessages(peerId: PeerId, context: AccountContext) {
        guard AITranslationSettings.enabled, AITranslationSettings.autoTranslateIncoming else { return }

        // Prevent duplicate catch-up for the same chat
        guard !catchUpInProgress.contains(peerId) else {
            print("[AITranslation] Catch-up already in progress for \(peerId), skipping")
            return
        }
        catchUpInProgress.insert(peerId)

        let _ = (context.account.postbox.transaction { transaction -> [(MessageId, String, Int32)] in
            var toTranslate: [(MessageId, String, Int32)] = []
            transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: 100) { message in
                // Translate ALL visible messages (both incoming and own) — no timestamp filter
                // Catch-up is capped at 100 messages and only fires when user opens a chat
                if !message.text.isEmpty,
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

            print("[AITranslation] Catch-up: translating \(toTranslate.count) messages for \(peerId) (newest first)")

            // Mark all as in-flight
            for (msgId, _, _) in toTranslate {
                Self.inFlightMessageIds.insert(msgId)
            }

            // Fire individual requests concurrently — each stores result immediately
            let messages = toTranslate.map { ($0.0, $0.1, peerId) }
            Self.translateIndividuallyWithRetry(
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

                Self.translateIndividuallyWithRetry(
                    messages: toTranslate,
                    context: context,
                    onAllComplete: {}
                )
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
