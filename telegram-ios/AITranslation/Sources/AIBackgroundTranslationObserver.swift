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

    /// Cache of known bot chat peer IDs — checked by display-layer patches to skip animation/translation
    public static var botChatIds = Set<Int64>()

    /// Pending caption originals: "chatId_germanText" → originalEnglish
    /// Used as safety net to prevent redundant API calls when TranslationMessageAttribute
    /// gets stripped during the media send pipeline.
    public static var pendingCaptionOriginals: [String: String] = [:]

    /// Cache of translated quick reply template messages.
    /// Key: template MessageId (from Postbox).
    /// Value: English translation of the German template text.
    ///
    /// Populated in the background by `translateQuickReplyTemplates()` and read by:
    /// - `patch_chat_list_strings.py` (to display English in the "/" dropdown preview rows,
    ///    which use ChatListItem → ChatListItemStrings)
    /// - `patch_quick_reply.py` (to attach TranslationMessageAttribute to the outgoing message
    ///    so the sent message bubble renders in English locally)
    ///
    /// We use a separate dict instead of attaching TranslationMessageAttribute directly to
    /// the template messages in Postbox, because shortcut sync from the server may wipe
    /// locally-attached attributes.
    public static var quickReplyTranslations: [MessageId: String] = [:]

    /// Set of shortcut IDs whose messages are currently being translated, to prevent
    /// duplicate work when the scanner runs again while a previous scan is still in flight.
    private static var quickReplyInFlight = Set<Int32>()

    /// Call when an authorized account is available. Handles account switches
    /// by tearing down the old observer and creating a new one for the new account.
    public static func startIfNeeded(context: AccountContext) {
        // Same account — nothing to do
        if let existing = storedContext, existing.account.peerId == context.account.peerId {
            return
        }

        // Tear down old observer (disposes notificationMessages subscription)
        if shared != nil {
            shared?.disposable.dispose()
            shared = nil
            inFlightMessageIds.removeAll()
            catchUpInProgress.removeAll()
        }

        // Create new observer for new account
        storedContext = context
        shared = AIBackgroundTranslationObserver(context: context)

        // Register the callback from AccountStateManager for ALL incoming messages.
        // This bypasses notificationMessages filtering (muted chats, etc.).
        aiNewIncomingMessagesCallback = { messageIds in
            Self.translateMessageIds(messageIds)
        }

        // Catch-up: translate recent messages across top chats on the new account.
        // Handles messages that arrived while the user was on a different account.
        Self.catchUpAllUnreadChats(context: context)

        // Pre-translate quick reply templates (stored in German) so the "/" dropdown
        // preview and sent-message display show English locally.
        Self.translateQuickReplyTemplates(context: context)
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
                // Skip bot chats and Telegram Service Notifications (peer 777000)
                if let chatPeer = transaction.getPeer(id.peerId) as? TelegramUser,
                   chatPeer.botInfo != nil || id.peerId.id._internalGetInt64Value() == 777000 {
                    if chatPeer.botInfo != nil {
                        Self.botChatIds.insert(id.peerId.id._internalGetInt64Value())
                    }
                    continue
                }
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
            return
        }
        catchUpInProgress.insert(peerId)

        let _ = (context.account.postbox.transaction { transaction -> [(MessageId, String, Int32)] in
            var toTranslate: [(MessageId, String, Int32)] = []
            // Skip bot chats and Telegram Service Notifications (peer 777000)
            if let chatPeer = transaction.getPeer(peerId) as? TelegramUser,
               chatPeer.botInfo != nil || peerId.id._internalGetInt64Value() == 777000 {
                if chatPeer.botInfo != nil {
                    Self.botChatIds.insert(peerId.id._internalGetInt64Value())
                }
                return toTranslate
            }
            let peerIdInt = peerId.id._internalGetInt64Value()
            transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: 30) { message in
                guard !Self.inFlightMessageIds.contains(message.id) else { return true }
                let hasTranslation = message.attributes.contains(where: { $0 is TranslationMessageAttribute })

                // Translate visible messages (both incoming and own) — no timestamp filter
                // Capped at 30 messages (covers visible screen area) to limit API cost
                if !message.text.isEmpty {
                    let existingAttr = message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute
                    // Translate if: no attribute, OR attribute text matches original (poisoned by empty pipeline)
                    if existingAttr == nil || existingAttr?.text == message.text {
                        // Check pending captions cache — use cached English instead of API call
                        let cacheKey = "\(peerIdInt)_\(message.text)"
                        if let cachedOriginal = Self.pendingCaptionOriginals[cacheKey] {
                            Self.pendingCaptionOriginals.removeValue(forKey: cacheKey)
                            Self.storeTranslation(transaction: transaction, msgId: message.id, translatedText: cachedOriginal)
                        } else {
                            toTranslate.append((message.id, message.text, message.timestamp))
                        }
                    }
                }

                // Also translate audio transcriptions (AudioTranscriptionMessageAttribute)
                if !hasTranslation,
                   let transcriptionAttr = message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute,
                   !transcriptionAttr.text.isEmpty,
                   !transcriptionAttr.isPending {
                    toTranslate.append((message.id, transcriptionAttr.text, message.timestamp))
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
                }
            )
        })
    }

    // MARK: - Quick Reply Template Translation

    /// Scan all of the user's quick reply shortcut templates (stored in German on the account)
    /// and translate each template message DE → EN. Results are stored in
    /// `quickReplyTranslations[msgId]` for use by the "/" preview UI and the send interceptor.
    ///
    /// Safe to call repeatedly — already-translated messages and in-flight shortcuts are skipped.
    /// Designed to be cheap on subsequent calls.
    public static func translateQuickReplyTemplates(context: AccountContext) {
        guard AITranslationSettings.enabled else { return }
        guard let _ = storedContext else { return }

        AILogger.log("QR-SCAN: starting quick reply template translation scan")

        let _ = (context.engine.accountData.shortcutMessageList(onlyRemote: false)
        |> take(1)
        |> deliverOnMainQueue).start(next: { list in
            guard !list.items.isEmpty else {
                AILogger.log("QR-SCAN: no shortcuts found")
                return
            }
            AILogger.log("QR-SCAN: found \(list.items.count) shortcut(s)")

            for item in list.items {
                guard let shortcutId = item.id else { continue }
                // Skip if already scanning this shortcut
                if Self.quickReplyInFlight.contains(shortcutId) { continue }
                Self.quickReplyInFlight.insert(shortcutId)

                let _ = (context.account.viewTracker.quickReplyMessagesViewForLocation(quickReplyId: shortcutId)
                |> take(1)
                |> deliverOnMainQueue).start(next: { view, _, _ in
                    Self.processQuickReplyMessages(view: view, shortcutId: shortcutId, context: context)
                }, completed: {
                    // Safety: clear in-flight flag even if no value was emitted
                    Self.quickReplyInFlight.remove(shortcutId)
                })
            }
        })
    }

    /// Translate every text-bearing message in a shortcut view that isn't already cached.
    private static func processQuickReplyMessages(
        view: MessageHistoryView,
        shortcutId: Int32,
        context: AccountContext
    ) {
        var toTranslate: [(MessageId, String)] = []
        for entry in view.entries {
            let msg = entry.message
            guard !msg.text.isEmpty else { continue }
            // Skip already-cached and already-in-flight messages
            if Self.quickReplyTranslations[msg.id] != nil { continue }
            if Self.inFlightMessageIds.contains(msg.id) { continue }
            Self.inFlightMessageIds.insert(msg.id)
            toTranslate.append((msg.id, msg.text))
        }

        guard !toTranslate.isEmpty else {
            AILogger.log("QR-SCAN: shortcut \(shortcutId) — all \(view.entries.count) messages already cached/in-flight")
            return
        }

        AILogger.log("QR-SCAN: shortcut \(shortcutId) — translating \(toTranslate.count) template(s)")

        for (msgId, text) in toTranslate {
            let textPreview = String(text.prefix(40))
            let _ = (AITranslationService.shared.translateIncomingStrict(
                text: text,
                chatId: msgId.peerId,
                context: []
            )
            |> deliverOnMainQueue).start(next: { translatedText in
                if let translatedText = translatedText, !translatedText.isEmpty {
                    Self.quickReplyTranslations[msgId] = translatedText
                    AILogger.log("QR-SCAN OK: shortcut \(shortcutId) msg=\(msgId.id) '\(textPreview)' -> '\(String(translatedText.prefix(40)))'")
                } else {
                    AILogger.log("QR-SCAN FAIL: shortcut \(shortcutId) msg=\(msgId.id) text='\(textPreview)'")
                }
            }, completed: {
                Self.inFlightMessageIds.remove(msgId)
            })
        }
    }

    // MARK: - Account Switch Catch-Up

    /// On account switch, query the top 10 most recent chats and trigger
    /// catch-up translation for each. translateMessages handles scanning,
    /// deduplication (catchUpInProgress), and per-message translation internally.
    /// Limited to 10 chats to avoid token explosion (10 chats × 30 msgs = 300 max requests).
    private static func catchUpAllUnreadChats(context: AccountContext) {
        guard AITranslationSettings.enabled, AITranslationSettings.autoTranslateIncoming else { return }

        let _ = (context.account.viewTracker.tailChatListView(
            groupId: .root,
            filterPredicate: nil,
            count: 10
        )
        |> take(1)
        |> deliverOnMainQueue).start(next: { view, _ in
            for entry in view.entries {
                if case let .MessageEntry(entryData) = entry {
                    let peerId = entryData.index.messageIndex.id.peerId
                    Self.translateMessages(peerId: peerId, context: context)
                }
            }
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
                    // Skip messages from bots (covers 1-on-1 bot chats where bot is the sender)
                    if let user = message.author as? TelegramUser, user.botInfo != nil {
                        Self.botChatIds.insert(message.id.peerId.id._internalGetInt64Value())
                        continue
                    }
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

    // MARK: - Transcription Translation

    /// Translate an audio transcription and store the result as TranslationMessageAttribute.
    /// Called from ChatMessageInteractiveFileNode when a transcription is displayed without translation.
    /// Deduplication via inFlightMessageIds prevents duplicate calls on re-render.
    public static func translateTranscription(messageId: MessageId, text: String, peerId: PeerId, context: AccountContext) {
        guard AITranslationSettings.enabled, AITranslationSettings.autoTranslateIncoming else { return }
        guard !inFlightMessageIds.contains(messageId) else { return }
        guard !botChatIds.contains(peerId.id._internalGetInt64Value()) else { return }

        inFlightMessageIds.insert(messageId)

        let _ = (AITranslationService.shared.translateIncomingStrict(
            text: text, chatId: peerId, context: []
        )
        |> mapToSignal { translatedText -> Signal<Void, NoError> in
            guard let translatedText = translatedText else {
                return .complete()
            }
            return context.account.postbox.transaction { transaction in
                Self.storeTranslation(transaction: transaction, msgId: messageId, translatedText: translatedText)
            } |> map { _ in }
        }
        |> deliverOnMainQueue).start(completed: {
            Self.inFlightMessageIds.remove(messageId)
        })
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
