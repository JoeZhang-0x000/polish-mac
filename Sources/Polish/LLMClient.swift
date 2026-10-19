import Foundation

enum LLMError: LocalizedError {
    case noProvider
    case noModel
    case badURL(String)
    case http(Int, String)
    case badResponse(String)
    case refusal
    case empty

    var errorDescription: String? {
        switch self {
        case .noProvider: return "未选择模型服务，请在设置中添加 Provider"
        case .noModel: return "未选择模型"
        case .badURL(let u): return "Base URL 无效：\(u)"
        case .http(let code, let msg): return "请求失败 (\(code))：\(msg)"
        case .badResponse(let msg): return "无法解析返回结果：\(msg)"
        case .refusal: return "模型拒绝了这次请求"
        case .empty: return "模型返回为空"
        }
    }
}

enum LLMClient {
    /// Models that accept the server-side refusal fallback on the Claude API.
    private static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    static func polish(_ text: String, config: AppConfig) async throws -> String {
        guard let provider = config.activeProvider else { throw LLMError.noProvider }
        let model = config.activeModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw LLMError.noModel }
        let raw = try await complete(provider: provider, model: model,
                                     system: config.systemPrompt(),
                                     user: "<text>\n\(text)\n</text>",
                                     temperature: config.temperature,
                                     timeout: config.requestTimeout)
        let cleaned = clean(raw, original: text)
        guard !cleaned.isEmpty else { throw LLMError.empty }
        return cleaned
    }

    static func complete(provider: Provider, model: String, system: String, user: String,
                         temperature: Double, timeout: Double) async throws -> String {
        switch provider.style {
        case .openai:
            return try await openAI(provider, model, system, user, temperature, timeout)
        case .anthropic:
            return try await anthropic(provider, model, system, user, timeout)
        }
    }

    // MARK: OpenAI-compatible /chat/completions

    private static func openAI(_ p: Provider, _ model: String, _ system: String, _ user: String,
                               _ temperature: Double, _ timeout: Double) async throws -> String {
        let base = p.baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: urlString), url.scheme != nil else { throw LLMError.badURL(p.baseURL) }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(req)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.badResponse(String(describing: json).prefix(300).description)
        }
        if let s = message["content"] as? String { return s }
        // Some gateways return content as an array of parts.
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        throw LLMError.empty
    }

    // MARK: Anthropic /v1/messages

    private static func anthropic(_ p: Provider, _ model: String, _ system: String, _ user: String,
                                  _ timeout: Double) async throws -> String {
        let base = p.baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString: String
        if base.hasSuffix("/v1/messages") { urlString = base }
        else if base.hasSuffix("/v1") { urlString = base + "/messages" }
        else { urlString = base + "/v1/messages" }
        guard let url = URL(string: urlString), url.scheme != nil else { throw LLMError.badURL(p.baseURL) }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        let effort = p.effort.trimmingCharacters(in: .whitespaces)
        if !effort.isEmpty { body["output_config"] = ["effort": effort] }
        // Route refusals to a fallback model automatically (first-party API only).
        if fallbackModels.contains(model), url.host == "api.anthropic.com" {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(req)
        if (json["stop_reason"] as? String) == "refusal" { throw LLMError.refusal }
        guard let content = json["content"] as? [[String: Any]] else {
            throw LLMError.badResponse(String(describing: json).prefix(300).description)
        }
        return content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    // MARK: Model discovery

    /// Fetch the model IDs a provider offers (OpenAI-compatible GET /models, Anthropic GET /v1/models).
    static func listModels(provider p: Provider, timeout: Double = 20) async throws -> [String] {
        var base = p.baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids: [String] = []

        switch p.style {
        case .openai:
            if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
            guard let url = URL(string: base + "/models"), url.scheme != nil else { throw LLMError.badURL(p.baseURL) }
            var req = URLRequest(url: url, timeoutInterval: timeout)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let json = try await send(req)
            // Standard shape is {"data": [{"id": ...}]}; some servers use "models" / "name".
            let list = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
            ids = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }

        case .anthropic:
            if base.hasSuffix("/v1/messages") { base.removeLast("/messages".count) }
            if !base.hasSuffix("/v1") { base += "/v1" }
            var afterID: String?
            repeat {
                var comps = URLComponents(string: base + "/models")
                comps?.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                    + (afterID.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
                guard let url = comps?.url, url.scheme != nil else { throw LLMError.badURL(p.baseURL) }
                var req = URLRequest(url: url, timeoutInterval: timeout)
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                let json = try await send(req)
                let page = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                ids += page
                afterID = (json["has_more"] as? Bool) == true ? (json["last_id"] as? String) : nil
                if page.isEmpty { afterID = nil }
            } while afterID != nil
        }

        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Heuristic for hiding embedding / audio / image models in the picker.
    static func looksLikeChatModel(_ id: String) -> Bool {
        let s = id.lowercased()
        let skip = ["embed", "tts", "whisper", "dall-e", "moderation", "transcribe", "rerank", "image", "audio", "realtime"]
        return !skip.contains { s.contains($0) }
    }

    // MARK: Helpers

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            var msg = String(data: data, encoding: .utf8) ?? ""
            if let err = json?["error"] as? [String: Any], let m = err["message"] as? String { msg = m }
            else if let m = json?["error"] as? String { msg = m }
            throw LLMError.http(status, String(msg.prefix(300)))
        }
        guard let json else { throw LLMError.badResponse(String(data: data, encoding: .utf8)?.prefix(300).description ?? "") }
        return json
    }

    /// Strip wrappers that models sometimes add around the answer.
    static func clean(_ raw: String, original: String) -> String {
        var s = raw
        // Reasoning models (Qwen, DeepSeek-R1 via Ollama) may inline their thinking.
        if let r = s.range(of: "</think>") , s.contains("<think>") { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<text>") { s.removeFirst("<text>".count) }
        if s.hasSuffix("</text>") { s.removeLast("</text>".count) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") && s.hasSuffix("```") && !original.contains("```") {
            var lines = s.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                lines.removeLast()
                s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }
}
