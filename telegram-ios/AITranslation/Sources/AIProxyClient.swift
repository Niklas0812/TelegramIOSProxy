import Foundation
import SwiftSignalKit

// MARK: - Models

public struct AITranslateRequest: Codable {
    public let text: String
    public let direction: String
    public let chatId: String
    public let senderAccountId: String
    public let hasTwoSidedHistory: Bool
    public let context: [AIContextMessage]

    enum CodingKeys: String, CodingKey {
        case text
        case direction
        case chatId = "chat_id"
        case senderAccountId = "sender_account_id"
        case hasTwoSidedHistory = "has_two_sided_history"
        case context
    }

    public init(text: String, direction: String, chatId: String, senderAccountId: String = "", hasTwoSidedHistory: Bool = false, context: [AIContextMessage]) {
        self.text = text
        self.direction = direction
        self.chatId = chatId
        self.senderAccountId = senderAccountId
        self.hasTwoSidedHistory = hasTwoSidedHistory
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
    public let userClaimed: Bool
    public let claimedBy: String

    enum CodingKeys: String, CodingKey {
        case translatedText = "translated_text"
        case originalText = "original_text"
        case direction
        case translationFailed = "translation_failed"
        case userClaimed = "user_claimed"
        case claimedBy = "claimed_by"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translatedText = try container.decode(String.self, forKey: .translatedText)
        originalText = try container.decode(String.self, forKey: .originalText)
        direction = try container.decode(String.self, forKey: .direction)
        translationFailed = try container.decodeIfPresent(Bool.self, forKey: .translationFailed) ?? false
        userClaimed = try container.decodeIfPresent(Bool.self, forKey: .userClaimed) ?? false
        claimedBy = try container.decodeIfPresent(String.self, forKey: .claimedBy) ?? ""
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

// MARK: - Claim Guard Models

public struct AIClaimRequest: Codable {
    public let senderAccountId: String
    public let chatId: String
    public let hasTwoSidedHistory: Bool

    enum CodingKeys: String, CodingKey {
        case senderAccountId = "sender_account_id"
        case chatId = "chat_id"
        case hasTwoSidedHistory = "has_two_sided_history"
    }

    public init(senderAccountId: String, chatId: String, hasTwoSidedHistory: Bool) {
        self.senderAccountId = senderAccountId
        self.chatId = chatId
        self.hasTwoSidedHistory = hasTwoSidedHistory
    }
}

public struct AIClaimResponse: Codable {
    public let allowed: Bool
    public let userClaimed: Bool
    public let claimedBy: String

    enum CodingKeys: String, CodingKey {
        case allowed
        case userClaimed = "user_claimed"
        case claimedBy = "claimed_by"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed) ?? true
        userClaimed = try container.decodeIfPresent(Bool.self, forKey: .userClaimed) ?? false
        claimedBy = try container.decodeIfPresent(String.self, forKey: .claimedBy) ?? ""
    }
}

/// Result of a pre-flight claim registration call.
public enum AIClaimGuardResult {
    case allowed            // Sender owns or just acquired the claim; proceed.
    case blocked(String)    // Different account claims this target (claimed_by).
    case networkError       // Backend unreachable — fail-open: allow the local send
                            // so users aren't blocked from sending when the proxy is down.
}

// MARK: - Strict Translation Result

public enum StrictTranslationResult {
    case success(String)       // Translated text
    case backendFailure        // translation_failed=true (backend already retried 3x)
    case iosError              // Network/decode/empty — iOS should retry once
    case userClaimed           // Target user claimed by another account
}

// MARK: - Proxy Client

public final class AIProxyClient {
    private let session: URLSession
    private let outgoingSession: URLSession
    private let batchSession: URLSession
    public let baseURL: String

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
        senderAccountId: Int64 = 0,
        hasTwoSidedHistory: Bool = false,
        context: [AIContextMessage]
    ) -> Signal<StrictTranslationResult, NoError> {
        guard let url = URL(string: "\(baseURL)/translate") else {
            AILogger.log("HTTP E0: invalid URL — baseURL='\(baseURL)'")
            return .single(.iosError)
        }

        let request = AITranslateRequest(
            text: text,
            direction: direction,
            chatId: String(chatId),
            senderAccountId: senderAccountId != 0 ? String(senderAccountId) : "",
            hasTwoSidedHistory: hasTwoSidedHistory,
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

            let textPreview = String(request.text.prefix(40))
            let httpStart = CFAbsoluteTimeGetCurrent()
            AILogger.log("HTTP REQ-START: \(direction) text='\(textPreview)' url=\(url.absoluteString)")
            let task = self.outgoingSession.dataTask(with: urlRequest) { data, response, error in
                let httpMs = Int((CFAbsoluteTimeGetCurrent() - httpStart) * 1000)
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1

                if let error = error {
                    let nsErr = error as NSError
                    AILogger.log("HTTP ERR-NET: \(httpMs)ms status=\(httpStatus) domain=\(nsErr.domain) code=\(nsErr.code) desc=\(nsErr.localizedDescription) text='\(textPreview)'")
                    subscriber.putNext(.iosError)
                    subscriber.putCompletion()
                    return
                }

                guard let data = data else {
                    AILogger.log("HTTP ERR-NODATA: \(httpMs)ms status=\(httpStatus) text='\(textPreview)'")
                    subscriber.putNext(.iosError)
                    subscriber.putCompletion()
                    return
                }

                if httpStatus != 200 {
                    let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
                    AILogger.log("HTTP ERR-STATUS: \(httpMs)ms status=\(httpStatus) body=\(bodyPreview) text='\(textPreview)'")
                }

                do {
                    let resp = try JSONDecoder().decode(AITranslateResponse.self, from: data)
                    if resp.userClaimed {
                        AILogger.log("HTTP USER-CLAIMED: \(httpMs)ms target=\(request.chatId) claimed_by=\(resp.claimedBy) text='\(textPreview)'")
                        subscriber.putNext(.userClaimed)
                    } else if resp.translationFailed {
                        AILogger.log("HTTP BACKEND-FAIL: \(httpMs)ms translation_failed=true text='\(textPreview)'")
                        subscriber.putNext(.backendFailure)
                    } else if resp.translatedText.isEmpty {
                        AILogger.log("HTTP EMPTY-RESULT: \(httpMs)ms translatedText='' text='\(textPreview)'")
                        subscriber.putNext(.iosError)
                    } else {
                        AILogger.log("HTTP OK: \(httpMs)ms status=\(httpStatus) text='\(textPreview)' -> '\(String(resp.translatedText.prefix(40)))'")
                        subscriber.putNext(.success(resp.translatedText))
                    }
                } catch {
                    let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? "(binary \(data.count)b)"
                    AILogger.log("HTTP ERR-DECODE: \(httpMs)ms \(error) status=\(httpStatus) body=\(bodyPreview)")
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

    // MARK: - Claim Guard

    /// POST /claim — pre-flight claim registration for every outgoing send.
    /// Decoupled from /translate so untranslated paths (passthrough, forwards,
    /// media-only templates, toggle-off chats) still register the claim.
    public func registerClaim(
        chatId: Int64,
        senderAccountId: Int64,
        hasTwoSidedHistory: Bool
    ) -> Signal<AIClaimGuardResult, NoError> {
        guard let url = URL(string: "\(baseURL)/claim") else {
            AILogger.log("CLAIM E0: invalid URL — baseURL='\(baseURL)'")
            return .single(.networkError)
        }

        let request = AIClaimRequest(
            senderAccountId: String(senderAccountId),
            chatId: String(chatId),
            hasTwoSidedHistory: hasTwoSidedHistory
        )

        return Signal { subscriber in
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.timeoutInterval = 8.0

            do {
                urlRequest.httpBody = try JSONEncoder().encode(request)
            } catch {
                subscriber.putNext(.networkError)
                subscriber.putCompletion()
                return EmptyDisposable
            }

            let httpStart = CFAbsoluteTimeGetCurrent()
            let task = self.outgoingSession.dataTask(with: urlRequest) { data, response, error in
                let httpMs = Int((CFAbsoluteTimeGetCurrent() - httpStart) * 1000)
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1

                if let error = error {
                    let nsErr = error as NSError
                    AILogger.log("CLAIM ERR-NET: \(httpMs)ms status=\(httpStatus) domain=\(nsErr.domain) code=\(nsErr.code) target=\(request.chatId)")
                    subscriber.putNext(.networkError)
                    subscriber.putCompletion()
                    return
                }

                guard let data = data else {
                    AILogger.log("CLAIM ERR-NODATA: \(httpMs)ms status=\(httpStatus) target=\(request.chatId)")
                    subscriber.putNext(.networkError)
                    subscriber.putCompletion()
                    return
                }

                do {
                    let resp = try JSONDecoder().decode(AIClaimResponse.self, from: data)
                    if resp.allowed {
                        AILogger.log("CLAIM OK: \(httpMs)ms target=\(request.chatId) sender=\(request.senderAccountId)")
                        subscriber.putNext(.allowed)
                    } else {
                        AILogger.log("CLAIM BLOCKED: \(httpMs)ms target=\(request.chatId) sender=\(request.senderAccountId) claimed_by=\(resp.claimedBy)")
                        subscriber.putNext(.blocked(resp.claimedBy))
                    }
                } catch {
                    let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
                    AILogger.log("CLAIM ERR-DECODE: \(httpMs)ms \(error) status=\(httpStatus) body=\(bodyPreview)")
                    subscriber.putNext(.networkError)
                }
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
            // 10s tolerance absorbs backend cold-start windows and brief
            // Caddy-upstream hiccups without flipping the UI to "not connected".
            request.timeoutInterval = 10.0
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
