import Foundation

/// OpenAI-compatible chat client (OpenRouter by default). Used for the free coding model.
/// The agent keeps its history in Anthropic block format; this client converts it on the fly.
struct OpenAICompatClient {
    let apiKey: String
    var baseURL = "https://openrouter.ai/api/v1"

    static let defaultModel = "qwen/qwen3-coder:free"

    func complete(
        model: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        maxTokens: Int = 8192
    ) async throws -> ClaudeClient.Reply {
        var request = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("azawy coder", forHTTPHeaderField: "X-Title")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": Self.convert(system: system, messages: messages)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool["name"] ?? "",
                        "description": tool["description"] ?? "",
                        "parameters": tool["input_schema"] ?? [:]
                    ]
                ]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var data = Data()
        var status = -1
        for attempt in 0..<4 {
            let (d, response) = try await URLSession.shared.data(for: request)
            data = d
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Temporary overload / rate limit: wait and retry automatically.
            if [429, 500, 502, 503, 504].contains(status), attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 5_000_000_000)
                continue
            }
            break
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard status == 200, let json, let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            let errorInfo = json?["error"] as? [String: Any]
            var text = (errorInfo?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "فشل الطلب"
            if status == 401 { text += "\nتحقق من المفتاح في الإعدادات." }
            if status == 429 { text += "\nوصلت للحد المجاني. انتظر قليلاً ثم أعد المحاولة." }
            if status == 400 || status == 403 { text += "\nتحقق من المفتاح ومن معرّف النموذج في الإعدادات." }
            if status == 404 { text += "\nالنموذج غير متاح. غيّر معرّف النموذج من الإعدادات (مثلاً gemini-3.8-flash لـ Gemini)." }
            throw NSError(domain: "FreeAI", code: status, userInfo: [NSLocalizedDescriptionKey: "الذكاء المجاني (\(status)): \(text)"])
        }

        var content: [[String: Any]] = []
        if let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(["type": "text", "text": text])
        }
        let calls = message["tool_calls"] as? [[String: Any]] ?? []
        for call in calls {
            let function = call["function"] as? [String: Any] ?? [:]
            let arguments = function["arguments"] as? String ?? "{}"
            let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
            content.append([
                "type": "tool_use",
                "id": (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                "name": function["name"] as? String ?? "",
                "input": input
            ])
        }

        let finish = choice["finish_reason"] as? String ?? "stop"
        let stop = !calls.isEmpty ? "tool_use" : (finish == "length" ? "max_tokens" : "end_turn")
        return ClaudeClient.Reply(content: content, stopReason: stop)
    }

    /// Lists model ids available to this key (OpenAI-compatible /models endpoint).
    func listModels() async throws -> [String] {
        var request = URLRequest(url: URL(string: baseURL + "/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw NSError(domain: "FreeAI", code: status, userInfo: [NSLocalizedDescriptionKey: "تعذر جلب قائمة النماذج (\(status))."])
        }
        return list.compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .sorted()
    }

    // MARK: Anthropic blocks -> OpenAI messages

    static func convert(system: String, messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            let role = message["role"] as? String ?? "user"
            let blocks = message["content"] as? [[String: Any]] ?? []

            if role == "assistant" {
                let text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                let calls: [[String: Any]] = blocks.filter { $0["type"] as? String == "tool_use" }.map { block in
                    let input = block["input"] as? [String: Any] ?? [:]
                    let args = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return [
                        "id": block["id"] as? String ?? "",
                        "type": "function",
                        "function": ["name": block["name"] as? String ?? "", "arguments": args]
                    ]
                }
                var entry: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { entry["tool_calls"] = calls }
                out.append(entry)
            } else {
                var texts: [String] = []
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_result":
                        out.append([
                            "role": "tool",
                            "tool_call_id": block["tool_use_id"] as? String ?? "",
                            "content": block["content"] as? String ?? ""
                        ])
                    case "text":
                        texts.append(block["text"] as? String ?? "")
                    case "image":
                        texts.append("[صورة مرفقة — هذا النموذج لا يدعم الصور]")
                    default: break
                    }
                }
                if !texts.isEmpty { out.append(["role": "user", "content": texts.joined(separator: "\n")]) }
            }
        }
        return out
    }
}
