import Foundation

extension CloudHTTPProvider {
    /// All streaming endpoints use SSE. A socket closing after partial text
    /// is not completion: the provider's terminal event must be present.
    func stream(dispatch: CloudDispatch, credential: String, instruction: String, input: String, maxOutputTokens: Int = 8192, onDelta: @escaping @MainActor (String) throws -> Void) async throws -> CloudTextResponse {
        guard dispatch.configuration.provider.isSelectable else { throw CloudFailure.invalidConfiguration }
        try await CloudRequestLimiter.shared.acquire()
        defer { Task { await CloudRequestLimiter.shared.release() } }
        try Task.checkCancellation()
        let request = try request(dispatch: dispatch, credential: credential, instruction: instruction, input: input, maxOutputTokens: maxOutputTokens, format: .text, streaming: true)
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { throw CloudRequestError(failure: cloudFailure(error)) }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CloudFailure.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count >= 65_536 { break } }
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            let failure: CloudFailure
            switch http.statusCode {
            case 401: failure = .authentication
            case 402: failure = .quota
            case 403: failure = .permission
            case 429: failure = ["insufficient_quota", "credit_balance_exhausted"].contains(code ?? "") ? .quota : .rateLimited
            case 408, 500...599: failure = .unavailable
            default: failure = .invalidConfiguration
            }
            throw CloudRequestError(failure: failure, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        var line = Data(), payload = "", text = ""
        var received = 0, completed = false, chatStopped = false
        var inputTokens: Int?, outputTokens: Int?, actualModel: String?
        func consume(_ data: String) async throws {
            guard !data.isEmpty else { return }
            if data == "[DONE]" {
                if dispatch.configuration.provider.usesChatCompletions {
                    guard chatStopped else { throw CloudFailure.malformedResponse }
                    completed = true
                }
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any], object["error"] == nil else { throw CloudFailure.malformedResponse }
            var delta = ""
            let alreadyCompleted = completed
            if dispatch.configuration.provider == .openAI {
                switch object["type"] as? String {
                case "response.output_text.delta": delta = object["delta"] as? String ?? ""
                case "response.completed":
                    guard let result = object["response"] as? [String: Any], result["status"] as? String == "completed" else { throw CloudFailure.malformedResponse }
                    let usage = result["usage"] as? [String: Any]
                    inputTokens = usage?["input_tokens"] as? Int; outputTokens = usage?["output_tokens"] as? Int
                    actualModel = result["model"] as? String; completed = true
                case "error", "response.failed", "response.incomplete", "response.refusal.delta": throw CloudFailure.malformedResponse
                default: break
                }
            } else if dispatch.configuration.provider.usesChatCompletions {
                if let choice = (object["choices"] as? [[String: Any]])?.first {
                    let part = choice["delta"] as? [String: Any] ?? [:]
                    if let refusal = part["refusal"] as? String, !refusal.isEmpty { throw CloudFailure.malformedResponse }
                    delta = part["content"] as? String ?? ""
                    if chatStopped && !delta.isEmpty { throw CloudFailure.malformedResponse }
                    if let reason = choice["finish_reason"] as? String {
                        guard reason == "stop" else { throw CloudFailure.malformedResponse }
                        chatStopped = true
                    }
                }
                if let usage = object["usage"] as? [String: Any] {
                    inputTokens = usage["prompt_tokens"] as? Int ?? inputTokens
                    outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
                }
                actualModel = object["model"] as? String ?? actualModel
            } else {
                if object["error"] != nil || (object["promptFeedback"] as? [String: Any])?["blockReason"] != nil { throw CloudFailure.malformedResponse }
                if let candidate = (object["candidates"] as? [[String: Any]])?.first {
                    let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    delta = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
                    if let reason = candidate["finishReason"] as? String {
                        guard reason == "STOP" else { throw CloudFailure.malformedResponse }
                        completed = true
                    }
                }
                if let usage = object["usageMetadata"] as? [String: Any] {
                    inputTokens = usage["promptTokenCount"] as? Int; outputTokens = usage["candidatesTokenCount"] as? Int
                }
                actualModel = object["modelVersion"] as? String ?? actualModel
            }
            if !delta.isEmpty {
                guard !alreadyCompleted else { throw CloudFailure.malformedResponse }
                text += delta
                guard text.utf8.count <= 2_000_000 else { throw CloudFailure.responseTooLarge }
                try Task.checkCancellation(); try await onDelta(delta)
            }
        }
        for try await byte in bytes {
            try Task.checkCancellation(); received += 1
            guard received <= 4_000_000 else { throw CloudFailure.responseTooLarge }
            if byte != 10 {
                line.append(byte)
                guard line.count <= 1_000_000 else { throw CloudFailure.responseTooLarge }
                continue
            }
            if line.last == 13 { line.removeLast() }
            guard let value = String(data: line, encoding: .utf8) else { throw CloudFailure.malformedResponse }
            line.removeAll(keepingCapacity: true)
            if value.isEmpty {
                try await consume(payload); payload = ""
            } else if value.hasPrefix("data:") {
                if !payload.isEmpty { payload += "\n" }
                let content = value.dropFirst(5)
                payload += content.first == " " ? String(content.dropFirst()) : String(content)
            }
        }
        // An unterminated line/event is not a complete SSE frame, even when it
        // happens to contain syntactically valid JSON from a broken transport.
        guard line.isEmpty, payload.isEmpty else { throw CloudFailure.malformedResponse }
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudFailure.malformedResponse }
        return CloudTextResponse(text: text, usage: CloudUsage(id: dispatch.id, provider: dispatch.configuration.provider, model: actualModel ?? dispatch.preset.model, inputTokens: inputTokens, outputTokens: outputTokens, status: inputTokens == nil || outputTokens == nil ? "unknown" : "providerReported", at: Date()))
    }
}
