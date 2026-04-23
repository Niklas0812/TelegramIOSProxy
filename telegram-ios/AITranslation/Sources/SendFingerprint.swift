import Foundation
import TelegramCore
import Postbox

/// Builds stable string fingerprints for outgoing messages so that
/// `AIOutgoingMessageQueue` can detect "user tapped send twice on the same
/// message while the first is still pending" and block the duplicate.
///
/// Fingerprint design goals:
/// - Two identical tap-twice sends → same fingerprint → blocked.
/// - Same text sent intentionally AFTER the first succeeds → first is in .sent
///   state, dedup scan skips it → allowed (no false positive).
/// - Same text sent to different peers → different peerId → distinct fingerprint.
/// - Same text as different replies (different parent) → different
///   `replyToMessageId` → distinct fingerprint.
/// - Album: each item has its own media key + shared `localGroupingKey`, so
///   album re-taps dedup item-by-item, but two distinct albums never collide.
public enum SendFingerprint {

    // MARK: - Build helpers

    /// Single-item fingerprint. Pass the fields directly from the patch site.
    public static func build(
        peerId: PeerId,
        text: String,
        media: Media?,
        replyToMessageId: EngineMessageReplySubject?,
        replyToStoryId: StoryId?,
        localGroupingKey: Int64?
    ) -> String {
        var parts: [String] = []
        parts.append("p=\(peerId.id._internalGetInt64Value())")
        if !text.isEmpty {
            parts.append("t=\(text)")
        }
        if let media = media {
            parts.append("m=\(mediaKey(media))")
        }
        if let reply = replyToMessageId {
            parts.append("r=\(messageIdKey(reply.messageId))")
        }
        if let story = replyToStoryId {
            parts.append("s=\(story.peerId.id._internalGetInt64Value()):\(story.id)")
        }
        if let lgk = localGroupingKey {
            parts.append("g=\(lgk)")
        }
        return parts.joined(separator: "|")
    }

    /// Batch fingerprint — combines per-item fingerprints of every message in
    /// the batch. Used when a patch enqueues multiple `EnqueueMessage` entries
    /// as one atomic queue entry (album groups, multi-forward batches, mixed
    /// passthrough batches).
    public static func buildBatch(
        peerId: PeerId,
        messages: [EnqueueMessage]
    ) -> String {
        let peerPart = "p=\(peerId.id._internalGetInt64Value())"
        let itemParts = messages.enumerated().map { idx, msg in
            "[\(idx)]\(enqueueMessageKey(msg))"
        }
        return ([peerPart] + itemParts).joined(separator: "||")
    }

    // MARK: - EnqueueMessage introspection

    /// Extracts the identifying fields from an `EnqueueMessage` and formats
    /// them as a stable string. Handles both `.message(...)` and `.forward`.
    private static func enqueueMessageKey(_ msg: EnqueueMessage) -> String {
        if case let .message(text, _, _, mediaRef, _, replyToMessageId, replyToStoryId, localGroupingKey, _, _) = msg {
            var parts: [String] = ["k=M"]
            if !text.isEmpty { parts.append("t=\(text)") }
            if let media = mediaRef?.media {
                parts.append("m=\(mediaKey(media))")
            }
            if let reply = replyToMessageId {
                parts.append("r=\(messageIdKey(reply.messageId))")
            }
            if let story = replyToStoryId {
                parts.append("s=\(story.peerId.id._internalGetInt64Value()):\(story.id)")
            }
            if let lgk = localGroupingKey {
                parts.append("g=\(lgk)")
            }
            return parts.joined(separator: "|")
        }
        // `.forward` case — its private fields aren't stably known here. The
        // same forward-tap produces structurally identical String(describing:)
        // output, which is what we need for dup detection within the short
        // translation window.
        return "k=F|d=\(String(describing: msg))"
    }

    // MARK: - Media & MessageId keys

    /// Stable identifier for a Media object. Prefers the server-assigned
    /// `MediaId` when available (cloud-stored media always has it). Falls back
    /// to the Swift object identity for local, not-yet-uploaded media —
    /// which is sufficient because the same Telegram `Media` instance is
    /// reused for both tap attempts during the dedup window.
    private static func mediaKey(_ media: Media) -> String {
        if let mediaId = media.id {
            return "mid:\(mediaId.namespace):\(mediaId.id)"
        }
        return "ref:\(ObjectIdentifier(media as AnyObject).hashValue)"
    }

    private static func messageIdKey(_ id: MessageId) -> String {
        return "\(id.peerId.id._internalGetInt64Value()):\(id.namespace):\(id.id)"
    }
}
