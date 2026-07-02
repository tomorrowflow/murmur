import Foundation

// MARK: - OpenAI-Compatible LLM Chat Client

/// Chat client speaking the OpenAI protocol (`/v1/chat/completions`, `/v1/models`).
/// Works with any OpenAI-compatible server — Ollama, oMLX, LM Studio, llama.cpp, …
public class LLMClient {
    private let urlSession: URLSession

    private var baseURL: String {
        UserDefaults.standard.string(forKey: "readAloud.ollamaURL") ?? "http://localhost:11434"
    }

    private var model: String {
        UserDefaults.standard.string(forKey: "readAloud.ollamaModel") ?? ""
    }

    private var webSearchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "readAloud.webSearchEnabled")
    }

    private var ollamaAPIKey: String? {
        if let key = UserDefaults.standard.string(forKey: "readAloud.ollamaAPIKey"), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["OLLAMA_API_KEY"]
    }

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        urlSession = URLSession(configuration: config)
    }

    // MARK: - Streaming Chat

    /// Stream a chat completion from the LLM server. Yields content tokens.
    public func streamChat(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !model.isEmpty else {
                        continuation.finish(throwing: LLMClientError.noModel)
                        return
                    }

                    let url = URL(string: "\(baseURL)/v1/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let payload: [String: Any] = [
                        "model": model,
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user]
                        ],
                        "stream": true,
                        "temperature": 0.7,
                        "max_tokens": 2048
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await urlSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMClientError.connectionFailed)
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: LLMClientError.httpError(httpResponse.statusCode))
                        return
                    }

                    var fullContent = ""
                    // OpenAI streaming is Server-Sent Events: each chunk arrives as a
                    // `data: {json}` line, terminated by a `data: [DONE]` sentinel.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payloadString = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payloadString == "[DONE]" { break }

                        guard let data = payloadString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }
                        fullContent += content

                        // Strip <think>...</think> blocks incrementally
                        let filtered = Self.stripThinkBlocks(fullContent)
                        // Only yield new content after stripping
                        if !filtered.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
                    continuation.finish(throwing: LLMClientError.connectionFailed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Non-streaming chat for simple queries (e.g. affirmative check).
    public func chat(system: String, user: String) async throws -> String {
        var result = ""
        for try await token in streamChat(system: system, user: user) {
            result += token
        }
        return Self.stripThinkBlocks(result)
    }

    // MARK: - Model Listing

    /// Fetch available models from the LLM server.
    public static func listModels(baseURL: String = "") async -> [String] {
        let url = (baseURL.isEmpty ? "http://localhost:11434" : baseURL) + "/v1/models"
        guard let requestURL = URL(string: url) else { return [] }

        do {
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["id"] as? String }.sorted()
        } catch {
            NSLog("LLMClient: failed to list models: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Web Search

    /// Search the web via Ollama's external search endpoint (ollama.com cloud API,
    /// independent of the configured LLM server).
    public func webSearch(query: String) async -> [WebSearchResult] {
        guard webSearchEnabled, let apiKey = ollamaAPIKey, !apiKey.isEmpty else {
            return []
        }

        do {
            var request = URLRequest(url: URL(string: "https://ollama.com/api/web_search")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let payload: [String: Any] = [
                "query": query,
                "max_results": 3
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, _) = try await urlSession.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            return results.compactMap { dict in
                guard let title = dict["title"] as? String,
                      let url = dict["url"] as? String,
                      let content = dict["content"] as? String else { return nil }
                return WebSearchResult(title: title, url: url, content: content)
            }
        } catch {
            NSLog("ReadAloud: web search failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Format search results as context for the LLM.
    public static func formatSearchResults(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "" }
        var lines = ["## Web Search Results\n"]
        for r in results {
            lines.append("**\(r.title)** (\(r.url))\n\(r.content)\n")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Think Block Stripping

    public static func stripThinkBlocks(_ text: String) -> String {
        // Remove <think>...</think> blocks (reasoning models)
        guard let regex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models

public struct WebSearchResult {
    let title: String
    let url: String
    let content: String
}

public enum LLMClientError: LocalizedError {
    case connectionFailed
    case httpError(Int)
    case noModel

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Cannot connect to LLM server. Make sure it's running."
        case .httpError(let code):
            return "LLM server returned HTTP \(code)"
        case .noModel:
            return "No model configured. Set one in Settings > Read Aloud."
        }
    }
}
