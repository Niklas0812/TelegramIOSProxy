import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext

/// Per-peer chronological outgoing message queue.
///
/// Every outgoing send path — typed text, text+media captions, media-only,
/// forwards, quick-reply templates, notification-banner replies — routes
/// through this queue so that:
///
/// 1. A user tapping "send" twice on the same message while the first is
///    still translating gets blocked (duplicate-pending detection via
///    `fingerprint`).
/// 2. Messages are DELIVERED to the recipient in the exact order the user
///    hit send, even when a later message doesn't need translation and a
///    prior one is mid-flight (strict per-peer FIFO `drainQueue`).
///
/// Two send kinds:
/// - `.translate(text)` — fire `/translate`, `sendAction` receives translated text.
/// - `.passthrough(text)` — no HTTP, `sendAction` receives text verbatim. Still
///   takes its turn in line so the FIFO guarantee holds across all paths.
public final class AIOutgoingMessageQueue {
    public static let shared = AIOutgoingMessageQueue()

    // MARK: - Public Types

    public enum SendKind {
        case translate(text: String)   // fire /translate, await translation
        case passthrough(text: String) // no HTTP, send text verbatim
    }

    // MARK: - Internal Types

    private enum EntryState {
        case translating          // HTTP translation in flight (only .translate kind)
        case ready(String)        // final text ready, awaiting FIFO turn
        case failed
        case userClaimed
        case sent
        case cancelled
    }

    private final class QueueEntry {
        let id: Int
        let fingerprint: String
        let kind: SendKind
        let originalText: String
        var state: EntryState
        let translationDisposable: MetaDisposable
        /// Enqueue final payload to Telegram. Returns false if controller deallocated.
        let sendAction: (String) -> Bool
        /// Restore original text to the input box.
        let restoreAction: (String) -> Void
        /// Show error popup with a specific message string.
        let errorAction: (String) -> Void

        init(
            id: Int,
            fingerprint: String,
            kind: SendKind,
            originalText: String,
            initialState: EntryState,
            sendAction: @escaping (String) -> Bool,
            restoreAction: @escaping (String) -> Void,
            errorAction: @escaping (String) -> Void
        ) {
            self.id = id
            self.fingerprint = fingerprint
            self.kind = kind
            self.originalText = originalText
            self.state = initialState
            self.translationDisposable = MetaDisposable()
            self.sendAction = sendAction
            self.restoreAction = restoreAction
            self.errorAction = errorAction
        }

        /// True if this entry is blocking further sends (still pending or
        /// ready-but-not-sent). Terminal states (.sent/.failed/.cancelled/
        /// .userClaimed) don't block.
        var isPending: Bool {
            switch state {
            case .translating, .ready:
                return true
            case .sent, .failed, .userClaimed, .cancelled:
                return false
            }
        }
    }

    // MARK: - State

    private var peerQueues: [PeerId: [QueueEntry]] = [:]
    private var nextId: Int = 0

    private init() {}

    // MARK: - Public API

    /// Primary API — add an outgoing message (translated or passthrough) to the
    /// per-peer FIFO queue. Returns `false` if an identical pending message is
    /// already in the queue for this peer (in which case the duplicate-pending
    /// popup is fired via `errorAction` and the caller should NOT proceed).
    ///
    /// - Parameters:
    ///   - peerId: Target chat peer ID.
    ///   - fingerprint: Stable identity string for dedup. Build via
    ///     `SendFingerprint.build(...)` / `.buildBatch(...)`.
    ///   - kind: `.translate(text)` to run text through the HTTP translation
    ///     pipeline; `.passthrough(text)` to skip translation and just FIFO it.
    ///   - context: Account context. REQUIRED when `kind == .translate` (the
    ///     translation signal needs it for context-mode fetches and the claim
    ///     guard's two-sided-history check). Pass `nil` for `.passthrough`
    ///     call sites that only have an `Account` (notification-reply handler).
    ///   - sendAction: Closure that actually calls `enqueueMessages(...)`. For
    ///     `.translate` it receives the translated text; for `.passthrough` it
    ///     receives the text unchanged. Must return `true` on success, `false`
    ///     if the controller has been deallocated.
    ///   - restoreAction: Paste the original text back into the input box (if any).
    ///   - errorAction: Present an error popup with the given message.
    @discardableResult
    public func enqueue(
        peerId: PeerId,
        fingerprint: String,
        kind: SendKind,
        context: AccountContext?,
        sendAction: @escaping (String) -> Bool,
        restoreAction: @escaping (String) -> Void,
        errorAction: @escaping (String) -> Void
    ) -> Bool {
        // Dedup — block a duplicate of an already-pending message on the same peer.
        if let queue = peerQueues[peerId] {
            for existing in queue where existing.isPending && existing.fingerprint == fingerprint {
                AILogger.log("QUEUE DUP: blocked duplicate pending send peer=\(peerId.id._internalGetInt64Value()) fp='\(fingerprint.prefix(60))' existingEntry=\(existing.id)")
                errorAction("Your message is still pending. Wait until it was send.")
                return false
            }
        }

        let entryId = nextId
        nextId += 1

        let originalText: String
        let initialState: EntryState
        switch kind {
        case .translate(let text):
            originalText = text
            initialState = .translating
        case .passthrough(let text):
            originalText = text
            initialState = .ready(text)
        }

        let entry = QueueEntry(
            id: entryId,
            fingerprint: fingerprint,
            kind: kind,
            originalText: originalText,
            initialState: initialState,
            sendAction: sendAction,
            restoreAction: restoreAction,
            errorAction: errorAction
        )

        if peerQueues[peerId] == nil {
            peerQueues[peerId] = []
        }
        peerQueues[peerId]!.append(entry)

        switch kind {
        case .translate(let text):
            AILogger.log("QUEUE: enqueued entry \(entryId) kind=translate peer=\(peerId.id._internalGetInt64Value()) text='\(String(text.prefix(40)))' queueSize=\(peerQueues[peerId]!.count)")

            guard let context = context else {
                AILogger.log("QUEUE E9: .translate enqueued without AccountContext — degrading to passthrough entry=\(entryId)")
                entry.state = .ready(text)
                drainQueue(peerId: peerId)
                return true
            }

            // Fire translation IMMEDIATELY — zero delay
            let signal = AITranslationService.shared.translateOutgoingStrict(
                text: text,
                chatId: peerId,
                context: context
            )
            |> deliverOnMainQueue

            entry.translationDisposable.set(signal.start(next: { [weak self] outcome in
                self?.handleTranslationResult(entryId: entryId, peerId: peerId, outcome: outcome)
            }))

            // Failsafe timeout: if translation doesn't complete, auto-fail.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
                guard let self = self else { return }
                guard let queue = self.peerQueues[peerId],
                      let entry = queue.first(where: { $0.id == entryId }),
                      case .translating = entry.state else { return }
                AILogger.log("QUEUE E8: 60s TIMEOUT entry=\(entryId) text='\(String(text.prefix(40)))'")
                entry.translationDisposable.dispose()
                entry.state = .failed
                self.drainQueue(peerId: peerId)
            }

        case .passthrough(let text):
            AILogger.log("QUEUE: enqueued entry \(entryId) kind=passthrough peer=\(peerId.id._internalGetInt64Value()) text='\(String(text.prefix(40)))' queueSize=\(peerQueues[peerId]!.count)")
            // Already in `.ready` state — trigger drain so we send immediately if we're at the front.
            drainQueue(peerId: peerId)
        }

        return true
    }

    /// Legacy text-only convenience overload. Preserves the old call sites that
    /// don't supply a fingerprint; we compute a conservative one from (peerId,
    /// text) so at least exact-text duplicates still dedup.
    @discardableResult
    public func enqueue(
        text: String,
        peerId: PeerId,
        context: AccountContext,
        sendAction: @escaping (String) -> Bool,
        restoreAction: @escaping (String) -> Void,
        errorAction: @escaping (String) -> Void
    ) -> Bool {
        let fp = "legacy|p=\(peerId.id._internalGetInt64Value())|t=\(text)"
        return enqueue(
            peerId: peerId,
            fingerprint: fp,
            kind: .translate(text: text),
            context: context,
            sendAction: sendAction,
            restoreAction: restoreAction,
            errorAction: errorAction
        )
    }

    // MARK: - Private

    private func handleTranslationResult(entryId: Int, peerId: PeerId, outcome: AITranslationService.OutgoingTranslationResult) {
        guard let queue = peerQueues[peerId],
              let entry = queue.first(where: { $0.id == entryId }) else {
            AILogger.log("QUEUE: entry \(entryId) not found (queue cleared)")
            return
        }

        guard case .translating = entry.state else {
            AILogger.log("QUEUE: entry \(entryId) not .translating, skip")
            return
        }

        switch outcome {
        case .success(let translatedText), .passthrough(let translatedText):
            entry.state = .ready(translatedText)
            AILogger.log("QUEUE: entry \(entryId) OK (\(translatedText.count) chars)")
        case .translationFailed:
            entry.state = .failed
            AILogger.log("QUEUE E7: entry \(entryId) FAILED text='\(String(entry.originalText.prefix(40)))'")
        case .userClaimed:
            entry.state = .userClaimed
            AILogger.log("QUEUE CLAIMED: entry \(entryId) target user claimed by another account")
        }

        drainQueue(peerId: peerId)
    }

    /// Process the queue from front to back, sending ready entries in order.
    private func drainQueue(peerId: PeerId) {
        guard let queue = peerQueues[peerId] else { return }

        var i = 0
        while i < queue.count {
            let entry = queue[i]

            switch entry.state {
            case .sent, .cancelled:
                i += 1
                continue

            case .translating:
                AILogger.log("QUEUE: drainQueue blocked — entry \(entry.id) still .translating, waiting...")
                cleanupSentEntries(peerId: peerId)
                return

            case .ready(let finalText):
                // Ready to send — call the closure
                if entry.sendAction(finalText) {
                    entry.state = .sent
                    AILogger.log("QUEUE: entry \(entry.id) SENT")
                    i += 1
                } else {
                    AILogger.log("QUEUE E5: sendAction=false entry=\(entry.id) text='\(String(entry.originalText.prefix(40)))' — controller deallocated?")
                    entry.restoreAction(entry.originalText)
                    entry.errorAction("Translation failed. Message not sent. Try again.")
                    for j in (i + 1)..<queue.count {
                        queue[j].translationDisposable.dispose()
                        queue[j].state = .cancelled
                    }
                    peerQueues[peerId] = nil
                    return
                }

            case .userClaimed:
                // Target user is claimed by another account — reject immediately
                AILogger.log("QUEUE CLAIM-BLOCK: entry \(entry.id) — rejecting message")
                entry.restoreAction(entry.originalText)
                entry.errorAction("This user was already claimed by someone else!")
                // Cancel all subsequent messages for this peer too
                for j in (i + 1)..<queue.count {
                    queue[j].translationDisposable.dispose()
                    queue[j].state = .cancelled
                }
                peerQueues[peerId] = nil
                return

            case .failed:
                AILogger.log("QUEUE E6: cascade fail entry=\(entry.id) text='\(String(entry.originalText.prefix(40)))'")
                performCascadeFailure(peerId: peerId, failedIndex: i)
                return
            }
        }

        cleanupSentEntries(peerId: peerId)
    }

    /// Cancel all messages from failedIndex onwards, restore failed text, show error.
    private func performCascadeFailure(peerId: PeerId, failedIndex: Int) {
        guard let queue = peerQueues[peerId] else { return }

        let failedEntry = queue[failedIndex]

        // Cancel all entries after the failed one (dispose in-flight translations)
        for i in (failedIndex + 1)..<queue.count {
            let entry = queue[i]
            entry.translationDisposable.dispose()
            entry.state = .cancelled
        }

        // Restore failed message text to input box
        failedEntry.restoreAction(failedEntry.originalText)

        // Show error popup (5 seconds)
        failedEntry.errorAction("Translation failed. Message not sent. Try again.")

        // Clear the entire queue for this peer
        peerQueues[peerId] = nil
    }

    /// Remove fully processed entries from the front of the queue.
    private func cleanupSentEntries(peerId: PeerId) {
        guard let queue = peerQueues[peerId] else { return }
        let remaining = queue.filter { entry in
            switch entry.state {
            case .sent, .cancelled: return false
            default: return true
            }
        }
        if remaining.isEmpty {
            peerQueues[peerId] = nil
        } else {
            peerQueues[peerId] = remaining
        }
    }
}
