import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// D-03/D-13 (09.18c-03): the strict AI carb-estimate contract. The AI provider is untrusted — its JSON
/// crosses into a carb number here — so the parse is tolerant (reads a structured carb field OR a plain
/// number in prose), validated (finite, non-negative), and clamped to a sane ceiling; a garbage /
/// refusal / negative / non-numeric response becomes a manual-entry fallback (never a fabricated
/// number). A rejected key (401/403) surfaces a DISTINCT error mapped to the documented copy, never a
/// carb value. The BYO key round-trips through the reused Keychain accessor (DEBUG in-memory seam) and
/// rides a `SecretsBackup.items` assembly.
struct FoodFinderAIParseTests {

    // MARK: - FoodFinderAICarbParse: validate / clamp / fallback

    @Test func parsesStructuredCarbJSON() {
        #expect(FoodFinderAICarbParse.parse(#"{"carbs_g": 45}"#) == .grams(45))
        #expect(FoodFinderAICarbParse.parse(#"{"carbohydrates": 30.4}"#) == .grams(30))
        // Numeric arriving as a string is tolerated.
        #expect(FoodFinderAICarbParse.parse(#"{"carbs": "52"}"#) == .grams(52))
    }

    @Test func parsesCarbNumberFromProse() {
        #expect(FoodFinderAICarbParse.parse("This looks like about 60 g of carbs.") == .grams(60))
        #expect(FoodFinderAICarbParse.parse("≈ 12g") == .grams(12))
    }

    @Test func clampsToSaneCeiling() {
        // A runaway positive value is clamped to the shared OFF-path ceiling, never surfaced raw.
        #expect(FoodFinderAICarbParse.parse(#"{"carbs_g": 99999}"#)
                == .grams(FoodFinderCarbEstimate.maxCarbGrams))
    }

    @Test func roundsToNonNegativeInt() {
        #expect(FoodFinderAICarbParse.parse(#"{"carbs_g": 0}"#) == .grams(0))
        #expect(FoodFinderAICarbParse.parse(#"{"carbs_g": 44.6}"#) == .grams(45))
    }

    @Test func fallsBackOnNoNumber() {
        #expect(FoodFinderAICarbParse.parse("I can't tell what this is.") == .manualEntryFallback)
        #expect(FoodFinderAICarbParse.parse("") == .manualEntryFallback)
    }

    @Test func fallsBackOnNegativeValue() {
        #expect(FoodFinderAICarbParse.parse(#"{"carbs_g": -5}"#) == .manualEntryFallback)
        #expect(FoodFinderAICarbParse.parse("negative -3 grams") == .manualEntryFallback)
    }

    // MARK: - FoodFinderAIServiceAdapter: HTTP-status → error mapping

    @Test func mapsSuccessStatusToNoError() {
        #expect(FoodFinderAIServiceAdapter.error(forStatus: 200) == nil)
        #expect(FoodFinderAIServiceAdapter.error(forStatus: 201) == nil)
    }

    @Test func mapsRejectedKeyStatusToDistinctError() {
        #expect(FoodFinderAIServiceAdapter.error(forStatus: 401) == .keyRejected)
        #expect(FoodFinderAIServiceAdapter.error(forStatus: 403) == .keyRejected)
        // The rejected-key error carries the documented copy (never a carb number).
        #expect(FoodFinderAIError.keyRejected.errorDescription
                == "That key was rejected by the provider. Check the key and try again.")
    }

    @Test func mapsOtherNonSuccessStatuses() {
        #expect(FoodFinderAIServiceAdapter.error(forStatus: 429) == .rateLimited)
        #expect(FoodFinderAIServiceAdapter.error(forStatus: 500) == .providerError(500))
    }

    // MARK: - FoodFinderAIServiceAdapter: responseKeyPath extraction (no network)

    @Test func extractsAnthropicResponseText() throws {
        let json = #"{"content":[{"type":"text","text":"{\"carbs_g\": 40}"}]}"#
        let text = try FoodFinderAIServiceAdapter.extractText(from: Data(json.utf8),
                                                              keyPath: "content.0.text")
        #expect(FoodFinderAICarbParse.parse(text) == .grams(40))
    }

    @Test func extractsOpenAIResponseText() throws {
        let json = #"{"choices":[{"message":{"content":"about 25 g"}}]}"#
        let text = try FoodFinderAIServiceAdapter.extractText(from: Data(json.utf8),
                                                              keyPath: "choices.0.message.content")
        #expect(text == "about 25 g")
    }

    @Test func extractsGoogleResponseText() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"70"}]}}]}"#
        let text = try FoodFinderAIServiceAdapter.extractText(
            from: Data(json.utf8), keyPath: "candidates.0.content.parts.0.text")
        #expect(text == "70")
    }

    @Test func missingKeyPathThrowsEmptyResponse() {
        let json = #"{"choices":[]}"#
        #expect(throws: FoodFinderAIError.emptyResponse) {
            _ = try FoodFinderAIServiceAdapter.extractText(from: Data(json.utf8),
                                                           keyPath: "choices.0.message.content")
        }
    }

    // MARK: - Request building per provider (no network)

    @Test func buildsAnthropicRequestWithKeyHeaders() throws {
        var config = AIProviderConfiguration.Provider.anthropic.configuration
        config.apiKey = "sk-test"
        let request = try FoodFinderAIServiceAdapter.buildRequest(prompt: "hi", imageBase64: nil, config: config)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func buildsGoogleRequestWithModelInPath() throws {
        var config = AIProviderConfiguration.Provider.google.configuration
        config.apiKey = "goog-test"
        let request = try FoodFinderAIServiceAdapter.buildRequest(prompt: "hi", imageBase64: nil, config: config)
        #expect(request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "goog-test")
    }

    @Test func buildsOpenAIRequestWithBearerPrefix() throws {
        var config = AIProviderConfiguration.Provider.openAI.configuration
        config.apiKey = "sk-oai"
        let request = try FoodFinderAIServiceAdapter.buildRequest(prompt: "hi", imageBase64: nil, config: config)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-oai")
    }

    @Test func onlyTheThreeAllowedProvidersExist() {
        // Spoonacular is OUT (A7): exactly Anthropic / OpenAI / Google.
        #expect(Set(AIProviderConfiguration.Provider.allCases.map(\.displayName))
                == ["Anthropic", "OpenAI", "Google"])
    }
}

/// The Keychain round-trip touches a process-global DEBUG seam, so these run serialized to avoid racing
/// each other (no other suite touches `FoodFinderAIKeyStore`).
@Suite(.serialized)
struct FoodFinderAIKeyStoreTests {

    private func withInMemoryStore(_ body: () -> Void) {
        #if DEBUG
        FoodFinderAIKeyStore.useInMemoryBackingForTests = true
        FoodFinderAIKeyStore.removeKey()
        defer {
            FoodFinderAIKeyStore.removeKey()
            FoodFinderAIKeyStore.useInMemoryBackingForTests = false
        }
        body()
        #endif
    }

    @Test func saveKeyRemoveRoundTrips() {
        withInMemoryStore {
            #expect(FoodFinderAIKeyStore.key() == nil)
            #expect(FoodFinderAIKeyStore.hasKey == false)
            #expect(FoodFinderAIKeyStore.save(key: "sk-abc123") == true)
            #expect(FoodFinderAIKeyStore.key() == "sk-abc123")
            #expect(FoodFinderAIKeyStore.hasKey == true)
            FoodFinderAIKeyStore.removeKey()
            #expect(FoodFinderAIKeyStore.key() == nil)
        }
    }

    @Test func rejectsBlankKey() {
        withInMemoryStore {
            #expect(FoodFinderAIKeyStore.save(key: "   ") == false)
            #expect(FoodFinderAIKeyStore.key() == nil)
        }
    }

    @Test func savedKeyRidesSecretsBackupAssembly() {
        withInMemoryStore {
            _ = FoodFinderAIKeyStore.save(key: "sk-backup-me")
            let items = FoodFinderAIKeyStore.backupItems()
            #expect(items[FoodFinderAIKeyStore.backupKey] == "sk-backup-me")
            // The assembled items are exactly what a SecretsBackup carries.
            let secrets = SecretsBackup(items: items)
            #expect(secrets.items["foodfinder.aiKey"] == "sk-backup-me")
            // Round-trip back through applyBackup after clearing.
            FoodFinderAIKeyStore.removeKey()
            #expect(FoodFinderAIKeyStore.key() == nil)
            FoodFinderAIKeyStore.applyBackup(secrets.items)
            #expect(FoodFinderAIKeyStore.key() == "sk-backup-me")
        }
    }

    @Test func noBackupItemsWhenNoKey() {
        withInMemoryStore {
            #expect(FoodFinderAIKeyStore.backupItems().isEmpty)
        }
    }
}
