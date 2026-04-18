import Foundation

// MARK: - UserDefaults-backed Storage

public final class AIStorageCache {
    private static let lock = NSLock()
    private static var _values: [String: Any] = [:]

    static func get(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return _values[key]
    }

    static func set(_ key: String, _ value: Any) {
        lock.lock()
        defer { lock.unlock() }
        _values[key] = value
    }

    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        _values.removeAll()
    }
}

@propertyWrapper
public struct AIStorage<T: Codable> {
    private let key: String
    private let defaultValue: T

    public init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: T {
        get {
            if let cached = AIStorageCache.get(key) as? T {
                return cached
            }
            guard let data = UserDefaults.standard.data(forKey: key) else {
                return defaultValue
            }
            let value = (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
            AIStorageCache.set(key, value)
            return value
        }
        set {
            AIStorageCache.set(key, newValue)
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}

// MARK: - Settings

public struct AITranslationSettings {
    // Global master toggle
    @AIStorage(key: "ai_translation:enabled", defaultValue: false)
    public static var enabled: Bool

    // Proxy server URL
    @AIStorage(key: "ai_translation:proxy_url", defaultValue: "https://telegramtranslation2.duckdns.org")
    public static var proxyServerURL: String

    // Per-chat enabled chat IDs
    @AIStorage(key: "ai_translation:enabled_chat_ids", defaultValue: [])
    public static var enabledChatIds: [Int64]

    // Directional toggles
    @AIStorage(key: "ai_translation:auto_incoming", defaultValue: true)
    public static var autoTranslateIncoming: Bool

    @AIStorage(key: "ai_translation:auto_outgoing", defaultValue: true)
    public static var autoTranslateOutgoing: Bool

    // Context mode: 1 = single message, 2 = conversation context
    @AIStorage(key: "ai_translation:context_mode", defaultValue: 1)
    public static var contextMode: Int

    // Number of context messages to send (when mode == 2)
    @AIStorage(key: "ai_translation:context_count", defaultValue: 20)
    public static var contextMessageCount: Int

    // Incoming context mode: 1 = single message (no context), 2 = conversation context
    @AIStorage(key: "ai_translation:incoming_context_mode", defaultValue: 1)
    public static var incomingContextMode: Int

    // Number of context messages for incoming translation (when mode == 2)
    @AIStorage(key: "ai_translation:incoming_context_count", defaultValue: 20)
    public static var incomingContextMessageCount: Int

    // Timestamp (Unix) from which translations should start.
    // Reset when URL is saved so old messages are not retroactively translated.
    @AIStorage(key: "ai_translation:start_timestamp", defaultValue: 0)
    public static var translationStartTimestamp: Int32

    // Dev settings
    @AIStorage(key: "ai_translation:show_raw_responses", defaultValue: false)
    public static var showRawAPIResponses: Bool
}
