import BentoCore
import Foundation
import Synchronization

/// Errors thrown by opt-in exact token-counting API clients (`PLAN.md` §6.3, §7).
public enum TokenCountAPIError: Error, Sendable, Equatable {
    case notEnabled(TokenCountAPIProviderID)
    case missingAPIKey(TokenCountAPIProviderID)
    case invalidEndpointURL
    case httpStatus(code: Int, message: String)
    case malformedResponse
    case transportError(String)
}

/// Common interface for opt-in API-backed exact token counters (`AnthropicCountTokens`, `GeminiCountTokens`).
public protocol ExactAPITokenCounting: TokenCounter, Sendable {
    var providerID: TokenCountAPIProviderID { get }
    var isEnabled: Bool { get }
    func buildRequest(text: String, model: String?) throws -> URLRequest
    func countTokens(text: String, contentHash: String?, model: String?) async throws -> TokenCountEstimate
    func countExactSync(text: String, contentHash: String?, model: String?) throws -> TokenCountEstimate
}

/// Opt-in Anthropic `POST /v1/messages/count_tokens` client with Keychain API key lookup and
/// content-hash caching (`PLAN.md` §6.3, §7).
public final class AnthropicCountTokens: ExactAPITokenCounting, Sendable {
    public static let defaultModel = "claude-sonnet-4-5"
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!
    private static let anthropicVersion = "2023-06-01"

    public let providerID: TokenCountAPIProviderID = .anthropic
    public let isEnabled: Bool
    public let defaultModelName: String
    public let endpoint: URL
    public let timeoutSeconds: TimeInterval

    private let keyProvider: any APIKeyProviding
    private let session: URLSession
    private let cache = Mutex<[String: Int]>([:])

    public var id: String {
        "anthropic-count-tokens-api"
    }

    public init(
        isEnabled: Bool,
        keyProvider: any APIKeyProviding,
        defaultModelName: String = AnthropicCountTokens.defaultModel,
        endpoint: URL = AnthropicCountTokens.defaultEndpoint,
        session: URLSession? = nil,
        timeoutSeconds: TimeInterval = 15.0
    ) {
        self.isEnabled = isEnabled
        self.keyProvider = keyProvider
        self.defaultModelName = defaultModelName
        self.endpoint = endpoint
        self.timeoutSeconds = max(1.0, timeoutSeconds)
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = max(1.0, timeoutSeconds)
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func buildRequest(text: String, model: String? = nil) throws -> URLRequest {
        guard isEnabled else {
            throw TokenCountAPIError.notEnabled(.anthropic)
        }
        guard let apiKey = try keyProvider.apiKey(for: .anthropic), !apiKey.isEmpty else {
            throw TokenCountAPIError.missingAPIKey(.anthropic)
        }
        let targetModel = Self.resolveModel(model, fallback: defaultModelName)
        let bodyObj: [String: Any] = [
            "model": targetModel,
            "messages": [
                [
                    "role": "user",
                    "content": text
                ]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData
        return request
    }

    public func countTokens(
        text: String,
        contentHash: String? = nil,
        model: String? = nil
    ) async throws -> TokenCountEstimate {
        guard isEnabled else {
            throw TokenCountAPIError.notEnabled(.anthropic)
        }
        if text.isEmpty {
            return Self.makeEstimate(tokens: 0, model: Self.resolveModel(model, fallback: defaultModelName), id: id)
        }
        let resolvedModel = Self.resolveModel(model, fallback: defaultModelName)
        let cacheKey = Self.cacheKey(model: resolvedModel, text: text, contentHash: contentHash)
        if let cached = cache.withLock({ $0[cacheKey] }) {
            return Self.makeEstimate(tokens: cached, model: resolvedModel, id: id)
        }

        let request = try buildRequest(text: text, model: resolvedModel)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TokenCountAPIError.transportError(error.localizedDescription)
        }
        let tokens = try Self.parseResponse(data: data, response: response)
        cache.withLock { $0[cacheKey] = tokens }
        return Self.makeEstimate(tokens: tokens, model: resolvedModel, id: id)
    }

    public func countExactSync(
        text: String,
        contentHash: String? = nil,
        model: String? = nil
    ) throws -> TokenCountEstimate {
        guard isEnabled else {
            throw TokenCountAPIError.notEnabled(.anthropic)
        }
        if text.isEmpty {
            return Self.makeEstimate(tokens: 0, model: Self.resolveModel(model, fallback: defaultModelName), id: id)
        }
        let resolvedModel = Self.resolveModel(model, fallback: defaultModelName)
        let cacheKey = Self.cacheKey(model: resolvedModel, text: text, contentHash: contentHash)
        if let cached = cache.withLock({ $0[cacheKey] }) {
            return Self.makeEstimate(tokens: cached, model: resolvedModel, id: id)
        }

        let request = try buildRequest(text: text, model: resolvedModel)
        let (data, response) = try Self.performSync(request: request, session: session, timeout: timeoutSeconds)
        let tokens = try Self.parseResponse(data: data, response: response)
        cache.withLock { $0[cacheKey] = tokens }
        return Self.makeEstimate(tokens: tokens, model: resolvedModel, id: id)
    }

    public func count(_ text: String) -> Int {
        (try? countExactSync(text: text, contentHash: nil, model: nil).tokens) ?? 0
    }

    fileprivate static func resolveModel(_ explicit: String?, fallback: String) -> String {
        let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "*" ? fallback : trimmed
    }

    fileprivate static func cacheKey(model: String, text: String, contentHash: String?) -> String {
        let digest = contentHash ?? ContentHasher.sha256Hex(Data(text.utf8))
        return "\(model.lowercased())|\(digest)"
    }

    private static func parseResponse(data: Data, response: URLResponse) throws -> Int {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(decoding: data.prefix(256), as: UTF8.self)
            throw TokenCountAPIError.httpStatus(code: http.statusCode, message: snippet)
        }
        guard
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tokens = (obj["input_tokens"] as? Int) ?? (obj["input_tokens"] as? NSNumber)?.intValue,
            tokens >= 0
        else {
            throw TokenCountAPIError.malformedResponse
        }
        return tokens
    }

    private static func makeEstimate(tokens: Int, model: String, id: String) -> TokenCountEstimate {
        TokenCountEstimate(
            tokens: tokens,
            range: nil,
            confidence: .exact,
            method: "Anthropic count_tokens API (\(model))",
            counterID: id
        )
    }

    fileprivate static func performSync(
        request: URLRequest,
        session: URLSession,
        timeout: TimeInterval
    ) throws -> (Data, URLResponse) {
        let resultBox = Mutex<Result<(Data, URLResponse), TokenCountAPIError>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                resultBox.withLock { $0 = .failure(.transportError(error.localizedDescription)) }
            } else if let data, let response {
                resultBox.withLock { $0 = .success((data, response)) }
            } else {
                resultBox.withLock { $0 = .failure(.malformedResponse) }
            }
            semaphore.signal()
        }
        task.resume()

        let waitOutcome = semaphore.wait(timeout: .now() + timeout)
        if waitOutcome == .timedOut {
            task.cancel()
            throw TokenCountAPIError.transportError("Timed out after \(Int(timeout))s")
        }

        guard let outcome = resultBox.withLock({ $0 }) else {
            throw TokenCountAPIError.malformedResponse
        }
        return try outcome.get()
    }
}

/// Opt-in Google Gemini `POST /v1beta/models/{model}:countTokens` client with Keychain API key lookup
/// and content-hash caching (`PLAN.md` §6.3, §7).
public final class GeminiCountTokens: ExactAPITokenCounting, Sendable {
    public static let defaultModel = "gemini-2.5-pro"
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    public let providerID: TokenCountAPIProviderID = .gemini
    public let isEnabled: Bool
    public let defaultModelName: String
    public let baseURL: URL
    public let timeoutSeconds: TimeInterval

    private let keyProvider: any APIKeyProviding
    private let session: URLSession
    private let cache = Mutex<[String: Int]>([:])

    public var id: String {
        "gemini-count-tokens-api"
    }

    public init(
        isEnabled: Bool,
        keyProvider: any APIKeyProviding,
        defaultModelName: String = GeminiCountTokens.defaultModel,
        baseURL: URL = GeminiCountTokens.defaultBaseURL,
        session: URLSession? = nil,
        timeoutSeconds: TimeInterval = 15.0
    ) {
        self.isEnabled = isEnabled
        self.keyProvider = keyProvider
        self.defaultModelName = defaultModelName
        self.baseURL = baseURL
        self.timeoutSeconds = max(1.0, timeoutSeconds)
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = max(1.0, timeoutSeconds)
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func buildRequest(text: String, model: String? = nil) throws -> URLRequest {
        guard isEnabled else {
            throw TokenCountAPIError.notEnabled(.gemini)
        }
        guard let apiKey = try keyProvider.apiKey(for: .gemini), !apiKey.isEmpty else {
            throw TokenCountAPIError.missingAPIKey(.gemini)
        }
        var targetModel = AnthropicCountTokens.resolveModel(model, fallback: defaultModelName)
        if targetModel.hasPrefix("models/") {
            targetModel = String(targetModel.dropFirst("models/".count))
        }
        let baseStr = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard
            let encodedModel = targetModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "\(baseStr)/\(encodedModel):countTokens")
        else {
            throw TokenCountAPIError.invalidEndpointURL
        }

        let bodyObj: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": text]
                    ]
                ]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData
        return request
    }

    public func countTokens(
        text: String,
        contentHash: String? = nil,
        model: String? = nil
    ) async throws -> TokenCountEstimate {
        guard isEnabled else {
            throw TokenCountAPIError.notEnabled(.gemini)
        }
        let resolvedModel = AnthropicCountTokens.resolveModel(model, fallback: defaultModelName)
        if text.isEmpty {
            return Self.makeEstimate(tokens: 0, model: resolvedModel, id: id)
        }
        let cacheKey = AnthropicCountTokens.cacheKey(model: resolvedModel, text: text, contentHash: contentHash)
        if let cached = cache.withLock({ $0[cacheKey] }) {
            return Self.makeEstimate(tokens: cached, model: resolvedModel, id: id)
        }

        let request = try buildRequest(text: text, model: resolvedModel)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TokenCountAPIError.transportError(error.localizedDescription)
        }
        let tokens = try Self.parseResponse(data: data, response: response)
        cache.withLock { $0[cacheKey] = tokens }
        return Self.makeEstimate(tokens: tokens, model: resolvedModel, id: id)
    }

    public func countExactSync(
        text: String,
        contentHash: String? = nil,
        model: String? = nil
    ) throws -> TokenCountEstimate {
        guard isEnabled else {
            throw TokenCountAPIError.notEnabled(.gemini)
        }
        let resolvedModel = AnthropicCountTokens.resolveModel(model, fallback: defaultModelName)
        if text.isEmpty {
            return Self.makeEstimate(tokens: 0, model: resolvedModel, id: id)
        }
        let cacheKey = AnthropicCountTokens.cacheKey(model: resolvedModel, text: text, contentHash: contentHash)
        if let cached = cache.withLock({ $0[cacheKey] }) {
            return Self.makeEstimate(tokens: cached, model: resolvedModel, id: id)
        }

        let request = try buildRequest(text: text, model: resolvedModel)
        let (data, response) = try AnthropicCountTokens.performSync(
            request: request,
            session: session,
            timeout: timeoutSeconds
        )
        let tokens = try Self.parseResponse(data: data, response: response)
        cache.withLock { $0[cacheKey] = tokens }
        return Self.makeEstimate(tokens: tokens, model: resolvedModel, id: id)
    }

    public func count(_ text: String) -> Int {
        (try? countExactSync(text: text, contentHash: nil, model: nil).tokens) ?? 0
    }

    private static func parseResponse(data: Data, response: URLResponse) throws -> Int {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(decoding: data.prefix(256), as: UTF8.self)
            throw TokenCountAPIError.httpStatus(code: http.statusCode, message: snippet)
        }
        guard
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tokens = (obj["totalTokens"] as? Int) ?? (obj["totalTokens"] as? NSNumber)?.intValue,
            tokens >= 0
        else {
            throw TokenCountAPIError.malformedResponse
        }
        return tokens
    }

    private static func makeEstimate(tokens: Int, model: String, id: String) -> TokenCountEstimate {
        TokenCountEstimate(
            tokens: tokens,
            range: nil,
            confidence: .exact,
            method: "Gemini countTokens API (\(model))",
            counterID: id
        )
    }
}
