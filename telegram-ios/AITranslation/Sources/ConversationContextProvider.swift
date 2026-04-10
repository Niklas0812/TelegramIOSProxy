import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext

public final class ConversationContextProvider {
    /// Fetches the last N messages from a chat for conversation context.
    /// Returns messages in chronological order with role labels.
    public static func getContext(
        chatId: PeerId,
        context: AccountContext,
        limit: Int? = nil,
        direction: String = "outgoing"
    ) -> Signal<[AIContextMessage], NoError> {
        let contextMode: Int
        let defaultCount: Int

        if direction == "incoming" {
            contextMode = AITranslationSettings.incomingContextMode
            defaultCount = AITranslationSettings.incomingContextMessageCount
        } else {
            contextMode = AITranslationSettings.contextMode
            defaultCount = AITranslationSettings.contextMessageCount
        }

        let messageCount = limit ?? defaultCount

        // If context mode is single message, return empty context
        if contextMode == 1 {
            return .single([])
        }

        AILogger.log("CTX: Postbox transaction START chat=\(chatId.id._internalGetInt64Value()) limit=\(messageCount)")
        let startTime = CFAbsoluteTimeGetCurrent()
        return context.account.postbox.transaction { transaction -> [AIContextMessage] in
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let accountPeerId = context.account.peerId

            // Read recent messages from the chat using scanTopMessages
            var messages: [Message] = []
            transaction.scanTopMessages(peerId: chatId, namespace: Namespaces.Message.Cloud, limit: messageCount) { message in
                messages.append(message)
                return true
            }

            // Sort chronologically (scanTopMessages returns newest first)
            messages.sort { $0.timestamp < $1.timestamp }

            // Convert to context messages
            var contextMessages: [AIContextMessage] = []
            for message in messages {
                let text = message.text
                guard !text.isEmpty else { continue }

                let role: String
                if message.author?.id == accountPeerId {
                    role = "me"
                } else {
                    role = "them"
                }

                contextMessages.append(AIContextMessage(role: role, text: text))
            }

            AILogger.log("CTX: Postbox transaction DONE chat=\(chatId.id._internalGetInt64Value()) msgs=\(contextMessages.count) waitMs=\(elapsed)")
            return contextMessages
        }
    }
}
