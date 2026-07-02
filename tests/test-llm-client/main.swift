import Foundation
import SharedModels

// Exercises LLMClient against any OpenAI-compatible server.
//   swift run TestLLMClient [baseURL] [model] [apiKey]
// Defaults: baseURL http://localhost:11434, model = first entry from /v1/models.
// The API key may also be supplied via the LLM_SERVER_API_KEY environment variable.
@main
struct TestLLMClient {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let baseURL = args.first ?? "http://localhost:11434"
        let requestedModel = (args.count > 1 && !args[1].isEmpty) ? args[1] : nil
        let apiKey = (args.count > 2 ? args[2] : nil)
            ?? ProcessInfo.processInfo.environment["LLM_SERVER_API_KEY"]

        print("🧪 Testing LLMClient (OpenAI-compatible)")
        print("Server: \(baseURL)")
        print("Auth: \(apiKey?.isEmpty == false ? "Bearer token provided" : "none")\n")

        // Make streamChat (which reads config from UserDefaults) use the same key.
        if let apiKey, !apiKey.isEmpty {
            UserDefaults.standard.set(apiKey, forKey: "readAloud.llmServerAPIKey")
        }

        // 1. List models (surfaces auth / connection errors)
        print("→ GET \(baseURL)/v1/models")
        let models: [String]
        do {
            models = try await LLMClient.fetchModels(baseURL: baseURL, apiKey: apiKey)
        } catch let error as LLMClientError {
            if case .authenticationFailed(let code) = error {
                print("🔒 Authentication required/failed (HTTP \(code)). Provide a key via the third arg or LLM_SERVER_API_KEY.")
                exit(2)
            }
            print("❌ \(error.localizedDescription)")
            exit(1)
        } catch {
            print("❌ \(error.localizedDescription)")
            exit(1)
        }

        if models.isEmpty {
            print("❌ No models returned. Is a server running at \(baseURL)?")
            exit(1)
        }
        print("Available models (\(models.count)):")
        for m in models { print("  • \(m)") }

        // 2. Resolve model to use
        guard let model = requestedModel ?? models.first else {
            print("❌ No model available to test with.")
            exit(1)
        }
        print("\nUsing model: \(model)")
        UserDefaults.standard.set(baseURL, forKey: "readAloud.ollamaURL")
        UserDefaults.standard.set(model, forKey: "readAloud.ollamaModel")

        // 3. Stream a short completion
        print("\n→ POST \(baseURL)/v1/chat/completions (stream)")
        print("Prompt: \"Say hello in exactly five words.\"\n")
        print("Response: ", terminator: "")

        let client = LLMClient()
        var tokenCount = 0
        do {
            for try await token in client.streamChat(
                system: "You are a terse assistant. Answer in one short sentence.",
                user: "Say hello in exactly five words."
            ) {
                print(token, terminator: "")
                fflush(stdout)
                tokenCount += 1
            }
            print("\n\n✅ Streamed \(tokenCount) tokens.")
        } catch let error as LLMClientError {
            if case .authenticationFailed(let code) = error {
                print("\n\n🔒 Authentication required/failed (HTTP \(code)).")
                exit(2)
            }
            print("\n\n❌ Stream failed: \(error.localizedDescription)")
            exit(1)
        } catch {
            print("\n\n❌ Stream failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
