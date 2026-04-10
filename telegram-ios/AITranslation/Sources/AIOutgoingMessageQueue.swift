import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext

/// Per-peer chronological outgoing message queue.
///
/// Translation fires INSTANTLY when a message is enqueued (concurrent).
/// Sending to Telegram follows strict chronological order.
/// On any failure, all subsequent queued messages are cascade-cancelled.
public final class AIOutgoingMessageQueue {
    public static let shared = AIOutgoingMessageQueue()

    // MARK: - Types

    private enum EntryState {
        case translating
        case translated(String)
        case failed
        case sent
        case cancelled
    }

    private final class QueueEntry {
        let id: Int
        let originalText: String
        var state: EntryState
        let translationDisposable: MetaDisposable
        /// Enqueue translated message to Telegram. Returns false if controller is deallocated.
        let sendAction: (String) -> Bool
        /// Restore original text to the input box.
        let restoreAction: (String) -> Void
        /// Show error popup.
        let errorAction: () -> Void

        init(
            id: Int,
            originalText: String,
            sendAction: @escaping (String) -> Bool,
            restoreAction: @escaping (String) -> Void,
            errorAction: @escaping () -> Void
        ) {
            self.id = id
            self.originalText = originalText
            self.state = .translating
            self.translationDisposable = MetaDisposable()
            self.sendAction = sendAction
            self.restoreAction = restoreAction
            self.errorAction = errorAction
        }
    }

    // MARK: - State

    private var peerQueues: [PeerId: [QueueEntry]] = [:]
    private var nextId: Int = 0

    private init() {}

    // MARK: - Public API

    /// Add a message to the outgoing queue. Translation fires immediately.
    /// Messages are sent to Telegram in strict chronological order.
    ///
    /// - Parameters:
    ///   - text: The original English text to translate.
    ///   - peerId: The chat peer ID.
    ///   - context: The account context for translation.
    ///   - sendAction: Closure to enqueue the translated message to Telegram.
    ///                 Must return `true` if the message was actually enqueued,
    ///                 `false` if the controller is gone (weak ref died).
    ///   - restoreAction: Closure to paste the original text back into the input box.
    ///   - errorAction: Closure to show the error popup.
    public func enqueue(
        text: String,
        peerId: PeerId,
        context: AccountContext,
        sendAction: @escaping (String) -> Bool,
        restoreAction: @escaping (String) -> Void,
        errorAction: @escaping () -> Void
    ) {
        let entryId = nextId
        nextId += 1

        let entry = QueueEntry(
            id: entryId,
            originalText: text,
            sendAction: sendAction,
            restoreAction: restoreAction,
            errorAction: errorAction
        )

        if peerQueues[peerId] == nil {
            peerQueues[peerId] = []
        }
        peerQueues[peerId]!.append(entry)
        AILogger.log("QUEUE: enqueued entry \(entryId) peer=\(peerId.id._internalGetInt64Value()) text='\(String(text.prefix(40)))' queueSize=\(peerQueues[peerId]!.count)")

        // Fire translation IMMEDIATELY — zero delay
        let signal = AITranslationService.shared.translateOutgoingStrict(
            text: text,
            chatId: peerId,
            context: context
        )
        |> deliverOnMainQueue

        entry.translationDisposable.set(signal.start(next: { [weak self] result in
            self?.handleTranslationResult(entryId: entryId, peerId: peerId, result: result)
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
    }

    // MARK: - Private

    private func handleTranslationResult(entryId: Int, peerId: PeerId, result: String?) {
        guard let queue = peerQueues[peerId],
              let entry = queue.first(where: { $0.id == entryId }) else {
            AILogger.log("QUEUE: entry \(entryId) not found (queue cleared)")
            return
        }

        guard case .translating = entry.state else {
            AILogger.log("QUEUE: entry \(entryId) not .translating, skip")
            return
        }

        if let translatedText = result, !translatedText.isEmpty {
            entry.state = .translated(translatedText)
            AILogger.log("QUEUE: entry \(entryId) OK (\(translatedText.count) chars)")
        } else {
            entry.state = .failed
            AILogger.log("QUEUE E7: entry \(entryId) FAILED — result=\(result == nil ? "nil" : "empty") text='\(String(entry.originalText.prefix(40)))'")
        }

        drainQueue(peerId: peerId)
    }

    /// Process the queue from front to back, sending translated messages in order.
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

            case .translated(let translatedText):
                // Ready to send — call the closure
                if entry.sendAction(translatedText) {
                    entry.state = .sent
                    AILogger.log("QUEUE: entry \(entry.id) SENT")
                    i += 1
                } else {
                    AILogger.log("QUEUE E5: sendAction=false entry=\(entry.id) text='\(String(entry.originalText.prefix(40)))' — controller deallocated?")
                    entry.restoreAction(entry.originalText)
                    entry.errorAction()
                    for j in (i + 1)..<queue.count {
                        queue[j].translationDisposable.dispose()
                        queue[j].state = .cancelled
                    }
                    peerQueues[peerId] = nil
                    return
                }

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
        failedEntry.errorAction()

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
