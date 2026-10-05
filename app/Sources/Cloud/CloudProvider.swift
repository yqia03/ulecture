import Foundation
import Security
import LocalAuthentication

protocol CloudCredentialStore: AnyObject {
    func save(_ value: String, reference: String) throws
    func read(reference: String) throws -> String?
    func remove(reference: String) throws
    func contains(reference: String) throws -> Bool
}
extension CloudCredentialStore {
    // Test/legacy stores can opt in without accidentally reading a secret just
    // to render settings. Production overrides with a metadata-only query.
    func contains(reference: String) throws -> Bool { false }
}
// Never instantiated by scanning other applications' credentials. Every query is
// scoped to this application's service and an explicit settings action.
final class KeychainCredentialStore: CloudCredentialStore {
    private let service = "local.uway.classroom-learning.cloud"
    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: reference, kSecAttrSynchronizable as String: false]
    }
    func save(_ value: String, reference: String) throws {
        var q = query(reference)
        let data = Data(value.utf8)
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CloudFailure.authentication }
        } else if updated != errSecSuccess { throw CloudFailure.authentication }
    }
    func read(reference: String) throws -> String? {
        var q = query(reference); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw CloudFailure.authentication }
        return text
    }
    func remove(reference: String) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudFailure.authentication }
    }
    func contains(reference: String) throws -> Bool {
        var q = query(reference)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        if status == errSecInteractionNotAllowed { throw CloudFailure.authentication }
        guard status == errSecSuccess else { throw CloudFailure.authentication }
        return true
    }
}

// One process-wide cap covers every open classroom plus summary/token work.
enum CloudRequestPriority: Int { case live, interactive, background }
actor CloudRequestLimiter {
    static let shared = CloudRequestLimiter()
    private var count = 0
    private var waiting: [(String, CloudRequestPriority, CheckedContinuation<Void, Error>)] = []
    private var foregroundBurst = 0
    func acquire(priority: CloudRequestPriority = .interactive) async throws {
        let id = UUID().uuidString
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if count < 3 { count += 1; continuation.resume() }
                else if waiting.count < 4096 { waiting.append((id, priority, continuation)) }
                else { continuation.resume(throwing: CloudFailure.queueFull) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: String) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at: index).2.resume(throwing: CancellationError()) }
    }
    func release() {
        if waiting.isEmpty { count -= 1 }
        else {
            let index: Int
            if foregroundBurst >= 6, let background = waiting.firstIndex(where: { $0.1 == .background }) { index = background }
            else { index = waiting.indices.min(by: { waiting[$0].1.rawValue < waiting[$1].1.rawValue })! }
            let next = waiting.remove(at: index)
            foregroundBurst = next.1 == .background ? 0 : foregroundBurst + 1
            next.2.resume()
        }
    }
}
private final class CloudNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct CloudTextResponse { var text: String; var usage: CloudUsage }
enum CloudResponseFormat { case json, text }
final class CloudHTTPProvider {
    let session: URLSession
    private let tokenBroker = CloudTokenBroker()
    func clearCredentialCache() { Task { await tokenBroker.clear() } }
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpMaximumConnectionsPerHost = 2
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration, delegate: CloudNoRedirectDelegate(), delegateQueue: nil)
        }
    }
    func request(dispatch: CloudDispatch, credential: String, instruction: String, input: String, maxOutputTokens: Int = 4096, format: CloudResponseFormat = .json, streaming: Bool = false) throws -> URLRequest {
        let config = try dispatch.configuration.validated(), model = dispatch.preset.model
        try CloudConfiguration.validateModel(model, provider: config.provider)
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudFailure.missingCredential }
        guard !dispatch.preset.isExpired else { throw CloudFailure.expiredPreset }
        guard input.utf8.count <= 500_000, instruction.utf8.count <= 500_000 else { throw CloudFailure.responseTooLarge }
        let endpoint: String
        switch config.provider {
        case .openAI: endpoint = "https://api.openai.com/v1/responses"
        case .deepSeek: endpoint = "https://api.deepseek.com/chat/completions"
        case .openAICompatible: endpoint = config.resolvedBaseURL + "/chat/completions"
        case .geminiDeveloper: endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        case .googleCloudExpress: endpoint = "https://aiplatform.googleapis.com/v1/publishers/google/models/\(model):generateContent"
        case .googleCloudStandard:
            let valid = "^[a-z][a-z0-9-]{4,61}[a-z0-9]$"
            guard config.projectID.range(of: valid, options: .regularExpression) != nil,
                  config.location.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil else { throw CloudFailure.invalidConfiguration }
            let host = config.location == "global" ? "aiplatform.googleapis.com" : "\(config.location)-aiplatform.googleapis.com"
            endpoint = "https://\(host)/v1/projects/\(config.projectID)/locations/\(config.location)/publishers/google/models/\(model):generateContent"
        }
        let address = streaming && config.provider != .openAI && !config.provider.usesChatCompletions ? endpoint.replacingOccurrences(of: ":generateContent", with: ":streamGenerateContent") + "?alt=sse" : endpoint
        guard let url = URL(string: address) else { throw CloudFailure.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(dispatch.id, forHTTPHeaderField: "X-Client-Request-Id")
        var body: [String: Any]
        if config.provider == .openAI {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "instructions": instruction, "input": input, "store": false,
                    "max_output_tokens": maxOutputTokens]
            if format == .json { body["text"] = ["format": ["type": "json_object"]] }
            if streaming { body["stream"] = true }
        } else if config.provider.usesChatCompletions {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "messages": [["role": "system", "content": instruction], ["role": "user", "content": input]],
                    "max_tokens": maxOutputTokens, "stream": streaming]
            if format == .json { body["response_format"] = ["type": "json_object"] }
            if streaming { body["stream_options"] = ["include_usage": true] }
        } else {
            if config.provider == .googleCloudStandard { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
            else { request.setValue(credential, forHTTPHeaderField: "x-goog-api-key") }
            var generation: [String: Any] = ["maxOutputTokens": maxOutputTokens]
            if format == .json { generation["responseMimeType"] = "application/json" }
            body = ["systemInstruction": ["parts": [["text": instruction]]],
                    "contents": [["role": "user", "parts": [["text": input]]]],
                    "generationConfig": generation]
        }
        if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
    func perform(dispatch: CloudDispatch, credential: String, instruction: String, input: String, maxOutputTokens: Int = 4096, format: CloudResponseFormat = .json, priority: CloudRequestPriority = .interactive) async throws -> CloudTextResponse {
        guard !dispatch.preset.isExpired else { throw CloudFailure.expiredPreset }
        _ = try dispatch.configuration.validated()
        try CloudConfiguration.validateModel(dispatch.preset.model, provider: dispatch.configuration.provider)
        try await CloudRequestLimiter.shared.acquire(priority: priority)
        defer { Task { await CloudRequestLimiter.shared.release() } }
        try Task.checkCancellation()
        let authorizedCredential = dispatch.configuration.provider == .googleCloudStandard ? try await tokenBroker.token(for: credential, session: session) : credential
        let request = try request(dispatch: dispatch, credential: authorizedCredential, instruction: instruction, input: input, maxOutputTokens: maxOutputTokens, format: format)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CloudRequestError(failure: .cancelled) }
            throw CloudRequestError(failure: .network)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudFailure.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Never expose provider body, headers or URL in errors: all may echo secrets/input.
            var failure: CloudFailure
            switch http.statusCode {
            case 401: failure = .authentication
            case 402: failure = .quota
            case 403: failure = .permission
            case 429:
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = (object?["error"] as? [String: Any])?["code"] as? String
                failure = ["insufficient_quota", "credit_balance_exhausted"].contains(code ?? "") ? .quota : .rateLimited
            case 408, 500...599: failure = .unavailable
            default: failure = .invalidConfiguration
            }
            var retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if retryAfter == nil, let value = http.value(forHTTPHeaderField: "Retry-After") {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                retryAfter = formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
            }
            throw CloudRequestError(failure: failure, retryAfter: retryAfter)
        }
        guard data.count <= 2_000_000 else { throw CloudFailure.responseTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else { throw CloudFailure.malformedResponse }
        let text: String
        var inputTokens: Int?, outputTokens: Int?
        if dispatch.configuration.provider == .openAI {
            guard object["status"] as? String == "completed",
                  let output = object["output"] as? [[String: Any]] else { throw CloudFailure.malformedResponse }
            text = output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined()
            let usage = object["usage"] as? [String: Any]
            inputTokens = usage?["input_tokens"] as? Int; outputTokens = usage?["output_tokens"] as? Int
        } else if dispatch.configuration.provider.usesChatCompletions {
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  choice["finish_reason"] as? String == "stop",
                  let message = choice["message"] as? [String: Any],
                  message["refusal"] == nil || message["refusal"] is NSNull,
                  let content = message["content"] as? String else { throw CloudFailure.malformedResponse }
            text = content
            let usage = object["usage"] as? [String: Any]
            inputTokens = usage?["prompt_tokens"] as? Int; outputTokens = usage?["completion_tokens"] as? Int
        } else {
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first,
                  candidate["finishReason"] as? String == "STOP",
                  let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { throw CloudFailure.malformedResponse }
            text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            let usage = object["usageMetadata"] as? [String: Any]
            inputTokens = usage?["promptTokenCount"] as? Int; outputTokens = usage?["candidatesTokenCount"] as? Int
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudFailure.malformedResponse }
        return CloudTextResponse(text: text, usage: CloudUsage(id: dispatch.id, provider: dispatch.configuration.provider, model: (object["modelVersion"] as? String) ?? (object["model"] as? String) ?? dispatch.preset.model, inputTokens: inputTokens, outputTokens: outputTokens, status: inputTokens == nil || outputTokens == nil ? "unknown" : "providerReported", at: Date()))
    }
}
