import Foundation

// MARK: - Ollama Chat Client

class OllamaClient {
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

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        urlSession = URLSession(configuration: config)
    }

    // MARK: - Streaming Chat

    /// Stream a chat completion from Ollama. Yields content tokens.
    func streamChat(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !model.isEmpty else {
                        continuation.finish(throwing: OllamaError.noModel)
                        return
                    }

                    let url = URL(string: "\(baseURL)/api/chat")!
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
                        "options": [
                            "temperature": 0.7,
                            "num_predict": 2048
                        ]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await urlSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: OllamaError.connectionFailed)
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: OllamaError.httpError(httpResponse.statusCode))
                        return
                    }

                    var fullContent = ""
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let message = json["message"] as? [String: Any],
                              let content = message["content"] as? String else {
                            continue
                        }
                        fullContent += content

                        // Strip <think>...</think> blocks incrementally
                        let filtered = Self.stripThinkBlocks(fullContent)
                        // Only yield new content after stripping
                        if !filtered.isEmpty {
                            continuation.yield(content)
                        }

                        if json["done"] as? Bool == true {
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
                    continuation.finish(throwing: OllamaError.connectionFailed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Non-streaming chat for simple queries (e.g. affirmative check).
    func chat(system: String, user: String) async throws -> String {
        var result = ""
        for try await token in streamChat(system: system, user: user) {
            result += token
        }
        return Self.stripThinkBlocks(result)
    }

    // MARK: - Model Listing

    /// Fetch installed models from Ollama.
    static func listModels(baseURL: String = "") async -> [String] {
        let url = (baseURL.isEmpty ? "http://localhost:11434" : baseURL) + "/api/tags"
        guard let requestURL = URL(string: url) else { return [] }

        do {
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }.sorted()
        } catch {
            NSLog("OllamaClient: failed to list models: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Web Search

    /// Search the web via Ollama's external search endpoint.
    func webSearch(query: String) async -> [WebSearchResult] {
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
    static func formatSearchResults(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "" }
        var lines = ["## Web Search Results\n"]
        for r in results {
            lines.append("**\(r.title)** (\(r.url))\n\(r.content)\n")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Think Block Stripping

    static func stripThinkBlocks(_ text: String) -> String {
        // Remove <think>...</think> blocks (reasoning models)
        guard let regex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models

struct WebSearchResult {
    let title: String
    let url: String
    let content: String
}

enum OllamaError: LocalizedError {
    case connectionFailed
    case httpError(Int)
    case noModel

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Cannot connect to Ollama. Make sure it's running."
        case .httpError(let code):
            return "Ollama returned HTTP \(code)"
        case .noModel:
            return "No Ollama model configured. Set one in Settings > Read Aloud."
        }
    }
}
