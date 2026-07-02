import Foundation
import SharedModels

// Exercises LLMClient against any OpenAI-compatible server.
//   swift run TestLLMClient [baseURL] [model]
// Defaults: baseURL http://localhost:11434, model = first entry from /v1/models.
@main
struct TestLLMClient {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let baseURL = args.first ?? "http://localhost:11434"
        let requestedModel = args.count > 1 ? args[1] : nil

        print("🧪 Testing LLMClient (OpenAI-compatible)")
        print("Server: \(baseURL)\n")

        // 1. List models
        print("→ GET \(baseURL)/v1/models")
        let models = await LLMClient.listModels(baseURL: baseURL)
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

        // LLMClient reads its config from UserDefaults (same keys the app uses).
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
        } catch {
            print("\n\n❌ Stream failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
