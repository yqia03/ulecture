import Foundation

@main struct CloudProviderConfigurationChecks {
    @MainActor static func main() async throws {
        var checks: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw NSError(domain: "CloudProviderConfigurationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FeatureNetwork.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = CloudHTTPProvider(session: session)
        let secret = "fixture-only-no-real-key"
        func dispatch(_ configuration: CloudConfiguration) -> CloudDispatch {
            CloudDispatch(version: 1, configuration: configuration, preset: .current(for: configuration), sentAt: Date())
        }
        func body(_ request: URLRequest) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        }
        func wire(_ value: [String: Any]) throws -> String {
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n\n"
        }
        try check(CloudConfiguration().provider == .geminiDeveloper && CloudProvider.selectable == [.geminiDeveloper, .deepSeek, .openAICompatible, .openAI], "AI Studio is default; Google Cloud legacy products are not selectable")
        let legacy = try JSONDecoder().decode(CloudConfiguration.self, from: Data(#"{"provider":"googleCloudExpress","projectID":"","location":"global","version":1}"#.utf8))
        try check(legacy.provider == .googleCloudExpress && legacy.model == nil && legacy.credentialReference == "classroom.googleCloudExpress", "legacy Google Cloud checkpoints retain product identity and key reference")
        var textConfig = CloudConfiguration(provider: .geminiDeveloper, model: "gemini-custom", credentialScope: "textTranslation")
        var documentConfig = textConfig; documentConfig.credentialScope = "documentTranslation"
        try check(textConfig.credentialReference != documentConfig.credentialReference && textConfig.credentialReference != CloudConfiguration().credentialReference, "AI, text and document credentials are isolated even on the same provider")
        let encoded = try JSONEncoder().encode(documentConfig)
        let decoded = try JSONDecoder().decode(CloudConfiguration.self, from: encoded)
        try check(decoded == documentConfig && CloudModelPreset.current(for: decoded).model == "gemini-custom", "configured model and credential scope survive persistence")
        var compatible = CloudConfiguration(provider: .openAICompatible, model: "organisation/model-v2", baseURL: "https://Example.com:443/vendor/v1/", credentialScope: "textTranslation")
        let normalized = try compatible.validated()
        try check(normalized.resolvedBaseURL == "https://example.com/vendor/v1" && normalized.credentialReference == compatible.credentialReference, "compatible URL normalization preserves key reference")
        compatible.baseURL = "https://other.example/v1"
        try check(compatible.credentialReference != normalized.credentialReference, "changing compatible endpoint requires its own saved key")
        for bad in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?api_key=secret", "https://example.com/v1#fragment", "file:///tmp/model", "https://exa mple.com/v1", "https://example.com:99999/v1"] {
            compatible.baseURL = bad
            FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
            do { _ = try await provider.perform(dispatch: dispatch(compatible), credential: secret, instruction: "JSON", input: "test"); throw CloudFailure.malformedResponse }
            catch CloudFailure.invalidConfiguration { }
            try check(FeatureNetwork.count == 0, "invalid endpoint rejected before request: " + bad)
        }
        for loopback in ["http://localhost:8080/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1"] {
            compatible.baseURL = loopback
            _ = try compatible.validated()
        }
        try check(true, "local compatible servers allow explicit loopback HTTP")
        for badModel in ["../other", "model:generateContent?key=x", "models/gemini", "bad model", "bad\nmodel"] {
            textConfig.model = badModel
            do { _ = try provider.request(dispatch: dispatch(textConfig), credential: secret, instruction: "JSON", input: "test"); throw CloudFailure.malformedResponse }
            catch CloudFailure.invalidConfiguration { }
        }
        try check(true, "Google model cannot inject path segments or query parameters")
        let configurations = [CloudConfiguration(provider: .geminiDeveloper, model: "gemini-chosen"), CloudConfiguration(provider: .deepSeek, model: "deepseek-chosen"), normalized, CloudConfiguration(provider: .openAI, model: "gpt-chosen")]
        for configuration in configurations {
            let current = dispatch(configuration)
            let request = try provider.request(dispatch: current, credential: secret, instruction: "Return JSON", input: "hello")
            let json = try body(request)
            try check(request.url?.query == nil && !String(decoding: request.httpBody!, as: UTF8.self).contains(secret), "\(configuration.provider) key never enters URL or body")
            switch configuration.provider {
            case .geminiDeveloper:
                try check(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-chosen:generateContent" && request.value(forHTTPHeaderField: "x-goog-api-key") == secret, "AI Studio uses Developer endpoint and x-goog-api-key")
            case .deepSeek, .openAICompatible:
                let endpoint = configuration.provider == .deepSeek ? "https://api.deepseek.com/chat/completions" : "https://example.com/vendor/v1/chat/completions"
                try check(request.url?.absoluteString == endpoint && request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret && json["model"] as? String == configuration.resolvedModel, "\(configuration.provider) uses selected Chat Completions endpoint/model/auth")
                try check((json["messages"] as? [[String: String]]) == [["role": "system", "content": "Return JSON"], ["role": "user", "content": "hello"]] && (json["response_format"] as? [String: String])?["type"] == "json_object", "\(configuration.provider) sends translation instructions, source and JSON format")
            case .openAI:
                try check(request.url?.absoluteString == "https://api.openai.com/v1/responses" && json["model"] as? String == "gpt-chosen" && json["store"] as? Bool == false, "OpenAI Responses keeps custom model and no-store behavior")
            default: throw CloudFailure.invalidConfiguration
            }
            let response: [String: Any]
            if configuration.provider.usesChatCompletions {
                response = ["choices": [["finish_reason": "stop", "message": ["content": "翻译完成", "reasoning_content": "hidden reasoning"]]], "model": "reported-model", "usage": ["prompt_tokens": 17, "completion_tokens": 9]]
            } else if configuration.provider == .openAI {
                response = ["status": "completed", "output": [["content": [["type": "output_text", "text": "翻译完成"]]]], "model": "reported-model", "usage": ["input_tokens": 17, "output_tokens": 9]]
            } else {
                response = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "hidden reasoning", "thought": true], ["text": "翻译完成"]]]]], "modelVersion": "reported-model", "usageMetadata": ["promptTokenCount": 17, "candidatesTokenCount": 9]]
            }
            FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: try JSONSerialization.data(withJSONObject: response)) }
            let result = try await provider.perform(dispatch: current, credential: secret, instruction: "Translate", input: "source", format: .text)
            try check(result.text == "翻译完成" && result.usage.model == "reported-model" && result.usage.inputTokens == 17 && result.usage.outputTokens == 9, "\(configuration.provider) nonstream response ignores reasoning and reports provider usage")
            let first: String, finish: String
            if configuration.provider.usesChatCompletions {
                first = try wire(["choices": [["delta": ["reasoning_content": "hidden"]]]]) + wire(["choices": [["delta": ["content": "你好🌍"]]]])
                finish = try wire(["choices": [["delta": [:], "finish_reason": "stop"]]]) + wire(["choices": [], "usage": ["prompt_tokens": 17, "completion_tokens": 9], "model": "stream-model"]) + "data: [DONE]\n\n"
            } else if configuration.provider == .openAI {
                first = try wire(["type": "response.output_text.delta", "delta": "你好🌍"])
                finish = try wire(["type": "response.completed", "response": ["status": "completed", "model": "stream-model", "usage": ["input_tokens": 17, "output_tokens": 9]]])
            } else {
                first = try wire(["candidates": [["content": ["parts": [["text": "hidden", "thought": true], ["text": "你好🌍"]]]]]])
                finish = try wire(["candidates": [["finishReason": "STOP"]], "modelVersion": "stream-model", "usageMetadata": ["promptTokenCount": 17, "candidatesTokenCount": 9]])
            }
            FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: Data((first + finish).utf8), contentType: "text/event-stream") }
            var deltas = ""
            let stream = try await provider.stream(dispatch: current, credential: secret, instruction: "Answer", input: "hello") { deltas += $0 }
            try check(stream.text == "你好🌍" && deltas == stream.text && stream.usage.model == "stream-model" && stream.usage.inputTokens == 17 && stream.usage.outputTokens == 9, "\(configuration.provider) SSE preserves Unicode and final usage")
            let streamRequest = FeatureNetwork.requests[0], streamBody = try body(streamRequest)
            if configuration.provider.usesChatCompletions {
                try check(streamBody["stream"] as? Bool == true && (streamBody["stream_options"] as? [String: Bool])?["include_usage"] == true && streamBody["response_format"] == nil, "\(configuration.provider) stream requests usage without JSON constraint")
            } else if configuration.provider == .geminiDeveloper {
                try check(streamRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-chosen:streamGenerateContent?alt=sse", "AI Studio stream uses Developer streamGenerateContent")
            }
            FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: Data(first.utf8), contentType: "text/event-stream") }
            do { _ = try await provider.stream(dispatch: current, credential: secret, instruction: "Answer", input: "hello") { _ in }; throw CloudFailure.invalidConfiguration }
            catch CloudFailure.malformedResponse { }
            try check(true, "\(configuration.provider) socket close before terminal event fails")
            if configuration.provider.usesChatCompletions {
                for reason in ["length", "content_filter", "tool_calls"] {
                    FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason, "message": ["content": "partial"]]]])) }
                    do { _ = try await provider.perform(dispatch: current, credential: secret, instruction: "Translate", input: "test"); throw CloudFailure.invalidConfiguration }
                    catch CloudFailure.malformedResponse { }
                    let bad = try wire(["choices": [["delta": [:], "finish_reason": reason]]])
                    FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: Data((first + bad + "data: [DONE]\n\n").utf8), contentType: "text/event-stream") }
                    do { _ = try await provider.stream(dispatch: current, credential: secret, instruction: "Translate", input: "test") { _ in }; throw CloudFailure.invalidConfiguration }
                    catch CloudFailure.malformedResponse { }
                }
                try check(true, "\(configuration.provider) rejects truncated filtered or tool-call completions in both modes")
                let stopWithoutDone = try wire(["choices": [["delta": [:], "finish_reason": "stop"]]])
                for broken in [first + stopWithoutDone, first + "data: [DONE]\n\n", first + String(finish.dropLast(2))] {
                    FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: Data(broken.utf8), contentType: "text/event-stream") }
                    do { _ = try await provider.stream(dispatch: current, credential: secret, instruction: "Translate", input: "test") { _ in }; throw CloudFailure.invalidConfiguration }
                    catch CloudFailure.malformedResponse { }
                }
                try check(true, "\(configuration.provider) requires stop plus complete DONE event")
            }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "realProviderRequests": 0], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
