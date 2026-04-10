import Foundation
import UIKit

/// Thread-safe in-memory ring buffer logger with backend upload.
/// Stores the last 500 log entries. Call `AILogger.send()` to POST
/// them to the proxy server's /logs endpoint.
public final class AILogger {
    public static let shared = AILogger()

    private let lock = NSLock()
    private var entries: [(timestamp: String, message: String)] = []
    private let maxEntries = 5000
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // Log app lifecycle events
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            AILogger.log("APP: didEnterBackground")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            AILogger.log("APP: willEnterForeground")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            AILogger.log("APP: willTerminate")
        }
    }

    // MARK: - Logging

    public static func log(_ message: String) {
        shared._log(message)
    }

    private func _log(_ message: String) {
        let ts = dateFormatter.string(from: Date())
        lock.lock()
        entries.append((timestamp: ts, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
        #if DEBUG
        print("[\(ts)] \(message)")
        #endif
    }

    // MARK: - Retrieve

    public static func getEntries() -> [(timestamp: String, message: String)] {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.entries
    }

    public static func clear() {
        shared.lock.lock()
        shared.entries.removeAll()
        shared.lock.unlock()
    }

    // MARK: - Send to Backend

    /// POST all buffered log entries to the proxy server's /logs endpoint.
    /// Returns true on success via the completion handler.
    public static func sendToBackend(completion: @escaping (Bool) -> Void) {
        let url: String
        let trimmed = AITranslationSettings.proxyServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completion(false)
            return
        }
        url = trimmed.hasSuffix("/") ? "\(trimmed)logs" : "\(trimmed)/logs"

        guard let endpoint = URL(string: url) else {
            completion(false)
            return
        }

        let entries = getEntries()
        if entries.isEmpty {
            completion(true)
            return
        }

        let payload: [[String: String]] = entries.map { ["ts": $0.timestamp, "msg": $0.message] }
        guard let body = try? JSONSerialization.data(withJSONObject: ["entries": payload, "device": UIDevice.current.name, "sent_at": ISO8601DateFormatter().string(from: Date())]) else {
            completion(false)
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                log("LOG-SEND failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = status == 200
            if ok {
                clear()
            }
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }
}
