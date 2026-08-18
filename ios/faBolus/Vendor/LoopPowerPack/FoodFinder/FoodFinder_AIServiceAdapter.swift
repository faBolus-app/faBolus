// Ported from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  FoodFinder_AIServiceAdapter.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — adapter that sends a food-analysis prompt (+ optional image) to the user's BYO AI
//  provider and returns ONLY the raw text content. Ported from the upstream adapter and REWRITTEN to be
//  self-contained (the upstream file bridged to `AIServiceManager` / `AIFoodAnalysisService`, which are
//  NOT vendored — they carried the excluded Pre-Meal Advisor + history-store + UIKit surface, D-13/D-14).
//  This adapter does the HTTP itself over an injectable `URLSession`, so no real network / AI call is
//  needed under test. Response-text extraction, HTTP-status → error mapping, and request building are
//  pure static helpers so they are unit-testable without a live provider.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//
//  faBolus adapter deltas (09.18c-03, D-13):
//    • self-contained URLSession HTTP (upstream `AIServiceManager`/`AIFoodAnalysisService` NOT vendored)
//    • Foundation/os.log only (no UIKit `UIImage` — the image crosses as base64 `Data`)
//    • a rejected key (401/403) maps to a distinct error → the documented "That key was rejected…" copy
//    • a strict response-body byte cap (DoS guard) before any JSON parse
//  Carries NO carb store, carb entry, bolus-calculator, or delivery symbol — a parsed carb number leaves
//  FoodFinder ONLY as the reviewed estimate the user confirms into BolusEntryView.carbsText (D-12); the
//  D-18.1 source-scan guard asserts these symbols are absent from this file.

import Foundation
import os.log

/// A failure on the BYO AI carb-estimate path. `keyRejected` is surfaced with the documented
/// "That key was rejected by the provider…" copy; every other case falls back to manual entry.
enum FoodFinderAIError: Error, LocalizedError, Equatable {
    /// No provider / no key configured — the caller should prompt for a key first.
    case notConfigured
    /// 401 / 403 — the provider rejected the API key.
    case keyRejected
    /// 429 — rate limited by the provider.
    case rateLimited
    /// Any other non-2xx HTTP status.
    case providerError(Int)
    /// A 2xx body with no text at the configured `responseKeyPath` (or an oversized body).
    case emptyResponse
    /// A URL / transport failure (no HTTP response).
    case network

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Connect an AI provider and paste your API key first."
        case .keyRejected:
            // UI-SPEC Copywriting Contract — "FoodFinder — AI key invalid error" (verbatim).
            return "That key was rejected by the provider. Check the key and try again."
        case .rateLimited:
            return "The AI provider is rate-limiting requests right now. Try again in a moment, or enter carbs yourself."
        case .providerError:
            return "The AI provider couldn't complete the request. Try again, or enter carbs yourself."
        case .emptyResponse:
            return "The AI provider didn't return a usable answer. Enter carbs yourself."
        case .network:
            return "Couldn't reach the AI provider. Check your connection and try again, or enter carbs yourself."
        }
    }
}

/// Sends a carb-estimate prompt to the user's configured AI provider. Immutable + `Sendable` so it is
/// safe from a detached `Task`; the `URLSession` is injectable so the decode / error paths are testable.
final class FoodFinderAIServiceAdapter: Sendable {

    /// Hard cap on a decoded response body — an oversized body is rejected, never parsed (DoS guard).
    static let maxResponseBytes = 2_000_000 // 2 MB

    private let session: URLSession
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fabolus.app",
                             category: "FoodFinderAIServiceAdapter")

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 45.0
            config.timeoutIntervalForResource = 90.0
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    /// Send a food description (+ optional base64 image) to the provider and return the raw text answer
    /// (the caller runs `FoodFinderAICarbParse` over it). Throws `FoodFinderAIError` on any failure — a
    /// rejected key surfaces as `.keyRejected`, never as a fabricated number.
    func analyze(prompt: String, imageBase64: String?, config: AIProviderConfiguration) async throws -> String {
        let resolved = config.apiKey.isEmpty ? config.withStoredAPIKey() : config
        guard !resolved.apiKey.isEmpty else { throw FoodFinderAIError.notConfigured }

        let request = try Self.buildRequest(prompt: prompt, imageBase64: imageBase64, config: resolved)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("AI provider network error: \(error.localizedDescription, privacy: .public)")
            throw FoodFinderAIError.network
        }

        guard let http = response as? HTTPURLResponse else { throw FoodFinderAIError.network }
        if let error = Self.error(forStatus: http.statusCode) {
            log.error("AI provider HTTP \(http.statusCode, privacy: .public)")
            throw error
        }
        guard data.count <= Self.maxResponseBytes else { throw FoodFinderAIError.emptyResponse }
        return try Self.extractText(from: data, keyPath: resolved.responseKeyPath)
    }

    // MARK: - Pure, testable helpers (no network)

    /// Map an HTTP status to a `FoodFinderAIError`, or `nil` for a 2xx success. 401/403 → `.keyRejected`
    /// (the documented rejected-key copy), 429 → `.rateLimited`, any other non-2xx → `.providerError`.
    static func error(forStatus code: Int) -> FoodFinderAIError? {
        switch code {
        case 200...299: return nil
        case 401, 403: return .keyRejected
        case 429: return .rateLimited
        default: return .providerError(code)
        }
    }

    /// Extract the text content at a dot-separated `keyPath` (numeric components index into arrays) from
    /// a JSON body. Throws `.emptyResponse` if the path is absent or the leaf is not a non-empty string.
    static func extractText(from data: Data, keyPath: String) throws -> String {
        guard data.count <= maxResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw FoodFinderAIError.emptyResponse
        }
        var current: Any? = root
        for component in keyPath.split(separator: ".") {
            if let index = Int(component) {
                guard let array = current as? [Any], index >= 0, index < array.count else {
                    throw FoodFinderAIError.emptyResponse
                }
                current = array[index]
            } else {
                guard let dict = current as? [String: Any], let value = dict[String(component)] else {
                    throw FoodFinderAIError.emptyResponse
                }
                current = value
            }
        }
        guard let text = current as? String, !text.isEmpty else { throw FoodFinderAIError.emptyResponse }
        return text
    }

    /// Build the provider-specific POST request. Pure (no network) so a test can assert the URL, method,
    /// auth header, and body shape per `RequestFormat`.
    static func buildRequest(prompt: String, imageBase64: String?, config: AIProviderConfiguration) throws -> URLRequest {
        // Google encodes the model in the path; everyone else uses a fixed endpoint.
        let path = config.endpointPath.replacingOccurrences(of: "{MODEL}", with: config.model)
        guard let url = URL(string: config.baseURL + path) else { throw FoodFinderAIError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in config.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Auth header (prefix + key). For Anthropic, also the required version header.
        request.setValue(config.apiKeyPrefix + config.apiKey, forHTTPHeaderField: config.apiKeyHeader)
        if config.requestFormat == .anthropicMessages, let version = config.apiVersion {
            request.setValue(version, forHTTPHeaderField: "anthropic-version")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body(prompt: prompt,
                                                                          imageBase64: imageBase64,
                                                                          config: config))
        return request
    }

    /// The provider-specific request body as a JSON-serializable dictionary.
    private static func body(prompt: String, imageBase64: String?, config: AIProviderConfiguration) -> [String: Any] {
        let includeImage = config.supportsVision ? imageBase64 : nil
        switch config.requestFormat {
        case .openAICompatible:
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            if let img = includeImage {
                content.append(["type": "image_url",
                                "image_url": ["url": "data:image/jpeg;base64,\(img)"]])
            }
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "temperature": config.temperature,
                "messages": [["role": "user", "content": content]],
            ]
        case .anthropicMessages:
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            if let img = includeImage {
                content.append(["type": "image",
                                "source": ["type": "base64", "media_type": "image/jpeg", "data": img]])
            }
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "messages": [["role": "user", "content": content]],
            ]
        case .googleGenerativeAI:
            var parts: [[String: Any]] = [["text": prompt]]
            if let img = includeImage {
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": img]])
            }
            return [
                "contents": [["parts": parts]],
                "generationConfig": ["maxOutputTokens": config.maxTokens, "temperature": config.temperature],
            ]
        }
    }
}
