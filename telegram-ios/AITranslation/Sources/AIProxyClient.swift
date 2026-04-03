import Foundation
import SwiftSignalKit

// MARK: - Models

public struct AITranslateRequest: Codable {
    public let text: String
    public let direction: String
    public let chatId: String
    public let context: [AIContextMessage]

    enum CodingKeys: String, CodingKey {
        case text
        case direction
        case chatId = "chat_id"
        case context
    }

    public init(text: String, direction: String, chatId: String, context: [AIContextMessage]) {
        self.text = text
        self.direction = direction
        self.chatId = chatId
        self.context = context
    }
}

public struct AIContextMessage: Codable {
    public let role: String  // "me" or "them"
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct AITranslateResponse: Codable {
    public let translatedText: String
    public let originalText: String
    public let direction: String
    public let translationFailed: Bool

    enum CodingKeys: String, CodingKey {
        case translatedText = "translated_text"
        case originalText = "original_text"
        case direction
        case translationFailed = "translation_failed"
    }
}

// MARK: - Batch Models

public struct AIBatchTextItem: Codable {
    public let id: String
    public let text: String
    public let direction: String
    public let chatId: String

    enum CodingKeys: String, CodingKey {
        case id, text, direction
        case chatId = "chat_id"
    }

    public init(id: String, text: String, direction: String, chatId: String = "") {
        self.id = id
        self.text = text
        self.direction = direction
        self.chatId = chatId
    }
}

public struct AIBatchTranslateRequest: Codable {
    public let texts: [AIBatchTextItem]
}

public struct AIBatchResultItem: Codable {
    public let id: String
    public let translatedText: String
    public let originalText: String
    public let translationFailed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case translatedText = "translated_text"
        case originalText = "original_text"
        case translationFailed = "translation_failed"
    }
}

public struct AIBatchTranslateResponse: Codable {
    public let results: [AIBatchResultItem]
}

public struct AIHealthResponse: Codable {
    public let status: String
    public let uptimeSeconds: Double
    public let lastSuccessfulTranslation: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case uptimeSeconds = "uptime_seconds"
        case lastSuccessfulTranslation = "last_successful_translation"
    }
}

public enum AITranslationError: Error {
    case networkError(Error)
    case serverError(Int)
    case decodingError
    case invalidURL
    case timeout
}

// MARK: - Strict Translation Result

public enum StrictTranslationResult {
    case success(String)       // Translated text
    case backendFailure        // translation_failed=true (backend already retried 3x)
    case iosError              // Network/decode/empty — iOS should retry once
}

// MARK: - Proxy Client

public final class AIProxyClient {
    private let session: URLSession
    private let outgoingSession: URLSession
    private let batchSession: URLSession
    private let baseURL: String

    public init(baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 50
        config.httpMaximumConnectionsPerHost = 20
        self.session = URLSession(configuration: config)

        // Dedicated session for outgoing translations — isolated from incoming load
        let outgoingConfig = URLSessionConfiguration.default
        outgoingConfig.timeoutIntervalForRequest = 45
        outgoingConfig.timeoutIntervalForResource = 50
        outgoingConfig.httpMaximumConnectionsPerHost = 5
        self.outgoingSession = URLSession(configuration: outgoingConfig)

        // Batch requests process many items server-side, need longer timeout
        let batchConfig = URLSessionConfiguration.default
        batchConfig.timeoutIntervalForRequest = 120
        batchConfig.timeoutIntervalForResource = 180
        batchConfig.httpMaximumConnectionsPerHost = 20
        self.batchSession = URLSession(configuration: batchConfig)
    }

    // MARK: - Translate

    public func translate(
        text: String,
        direction: String,
        chatId: Int64,
        context: [AIContextMessage]
    ) -> Signal<String, NoError> {
        guard let url = URL(string: "\(baseURL)/translate") else {
            return .single(text)
        }

        let request = AITranslateRequest(
            text: text,
            direction: direction,
            chatId: String(chatId),
            context: context
        )

        return Signal { subscriber in
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                urlRequest.httpBody = try JSONEncoder().encode(request)
            } catch {
                subscriber.putNext(text)
                subscriber.putCompletion()
                return EmptyDisposable
            }

            let task = self.session.dataTask(with: urlRequest) { data, response, error in
                if let error = error {

                    subscriber.putNext(text)
                    subscriber.putCompletion()
                    return
                }

                guard let data = data else {

                    subscriber.putNext(text)
                    subscriber.putCompletion()
                    return
                }



                do {
                    let response = try JSONDecoder().decode(AITranslateResponse.self, from: data)
                    if response.translationFailed {
                        subscriber.putNext(text)
                    } else {
                        subscriber.putNext(response.translatedText)
                    }
                } catch {
                    subscriber.putNext(text)
                }
                subscriber.putCompletion()
            }

            task.resume()

            return ActionDisposable {
                task.cancel()
            }
        }
    }

    // MARK: - Translate Strict (for outgoing — nil on ANY failure)

    /// Same as translate() but returns nil on any error instead of falling back
    /// to original text. Used for outgoing messages where sending untranslated
    /// text must be prevented.
    public func translateStrict(
        text: String,
        direction: String,
        chatId: Int64,
        context: [AIContextMessage]
    ) -> Signal<String?, NoError> {
        guard let url = URL(string: "\(baseURL)/translate") else {
            return .single(nil)
        }

        let request = AITranslateRequest(
            text: text,
            direction: direction,
            chatId: String(chatId),
            context: context
        )

        return Signal { subscriber in
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                urlRequest.httpBody = try JSONEncoder().encode(request)
            } catch {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }

            let task = self.outgoingSession.dataTask(with: urlRequest) { data, response, error in
                if let error = error {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }

                guard let data = data else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }

                do {
                    let response = try JSONDecoder().decode(AITranslateResponse.self, from: data)
                    if response.translationFailed || response.translatedText.isEmpty {
                        subscriber.putNext(nil)
                    } else {
                        subscriber.putNext(response.translatedText)
                    }
                } catch {
                    subscriber.putNext(nil)
                }
                subscriber.putCompletion()
            }

            task.resume()

            return ActionDisposable {
                task.cancel()
            }
        }
    }

    // MARK: - Translate Strict Detailed (for iOS retry logic)

    /// Same as translateStrict() but returns a detailed result enum so the caller
    /// can distinguish between backend-explicit-failure (no retry) and iOS-side
    /// errors (network/decode/empty — should retry once).
    public func translateStrictDetailed(
        text: String,
        direction: String,
        chatId: Int64,
        context: [AIContextMessage]
    ) -> Signal<StrictTranslationResult, NoError> {
        guard let url = URL(string: "\(baseURL)/translate") else {
            return .single(.iosError)
        }

        let request = AITranslateRequest(
            text: text,
            direction: direction,
            chatId: String(chatId),
            context: context
        )

        return Signal { subscriber in
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                urlRequest.httpBody = try JSONEncoder().encode(request)
            } catch {
                subscriber.putNext(.iosError)
                subscriber.putCompletion()
                return EmptyDisposable
            }

            let task = self.outgoingSession.dataTask(with: urlRequest) { data, response, error in
                if let error = error {
                    subscriber.putNext(.iosError)
                    subscriber.putCompletion()
                    return
                }

                guard let data = data else {
                    subscriber.putNext(.iosError)
                    subscriber.putCompletion()
                    return
                }

                do {
                    let response = try JSONDecoder().decode(AITranslateResponse.self, from: data)
                    if response.translationFailed {
                        subscriber.putNext(.backendFailure)
                    } else if response.translatedText.isEmpty {
                        subscriber.putNext(.iosError)
                    } else {
                        subscriber.putNext(.success(response.translatedText))
                    }
                } catch {
                    subscriber.putNext(.iosError)
                }
                subscriber.putCompletion()
            }

            task.resume()

            return ActionDisposable {
                task.cancel()
            }
        }
    }

    // MARK: - Batch Translate

    public func translateBatch(
        items: [AIBatchTextItem]
    ) -> Signal<[AIBatchResultItem], NoError> {
        guard let url = URL(string: "\(baseURL)/translate/batch") else {
            return .single([])
        }

        let request = AIBatchTranslateRequest(texts: items)

        return Signal { subscriber in
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                urlRequest.httpBody = try JSONEncoder().encode(request)
            } catch {
                subscriber.putNext([])
                subscriber.putCompletion()
                return EmptyDisposable
            }

            let task = self.batchSession.dataTask(with: urlRequest) { data, response, error in
                if let error = error {
                    subscriber.putNext([])
                    subscriber.putCompletion()
                    return
                }

                guard let data = data else {
                    subscriber.putNext([])
                    subscriber.putCompletion()
                    return
                }



                do {
                    let response = try JSONDecoder().decode(AIBatchTranslateResponse.self, from: data)
                    subscriber.putNext(response.results)
                } catch {
                    subscriber.putNext([])
                }
                subscriber.putCompletion()
            }

            task.resume()

            return ActionDisposable {
                task.cancel()
            }
        }
    }

    // MARK: - System Prompt

    public func getPrompt(direction: String) -> Signal<String, NoError> {
        guard let url = URL(string: "\(baseURL)/prompt/\(direction)") else {
            return .single("")
        }

        return Signal { subscriber in
            let task = self.session.dataTask(with: url) { data, _, error in
                if let _ = error {
                    subscriber.putNext("")
                    subscriber.putCompletion()
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let prompt = json["prompt"] as? String else {
                    subscriber.putNext("")
                    subscriber.putCompletion()
                    return
                }
                subscriber.putNext(prompt)
                subscriber.putCompletion()
            }
            task.resume()
            return ActionDisposable { task.cancel() }
        }
    }

    public func setPrompt(_ prompt: String, direction: String) -> Signal<Bool, NoError> {
        guard let url = URL(string: "\(baseURL)/prompt/\(direction)") else {
            return .single(false)
        }

        return Signal { subscriber in
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = ["prompt": prompt]
            guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
                subscriber.putNext(false)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            urlRequest.httpBody = httpBody

            let task = self.session.dataTask(with: urlRequest) { data, response, error in
                if let _ = error {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }
                subscriber.putNext(httpResponse.statusCode == 200)
                subscriber.putCompletion()
            }
            task.resume()
            return ActionDisposable { task.cancel() }
        }
    }

    // MARK: - Health Check

    public func healthCheck() -> Signal<Bool, NoError> {
        guard let url = URL(string: "\(baseURL)/health") else {
            return .single(false)
        }

        return Signal { subscriber in
            var request = URLRequest(url: url)
            request.timeoutInterval = 4.0
            let task = self.session.dataTask(with: request) { data, response, error in
                if let _ = error {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }

                subscriber.putNext(httpResponse.statusCode == 200)
                subscriber.putCompletion()
            }
            task.resume()

            return ActionDisposable {
                task.cancel()
            }
        }
    }
}
