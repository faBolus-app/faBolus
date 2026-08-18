// Ported from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  FoodFinder_AIProviderConfig.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — BYO API configuration model. Ported from the upstream provider config and REDUCED to
//  the three providers with a usable no-default-training BYO-key posture: Anthropic, OpenAI, and Google
//  (RESEARCH Open Q#2). The upstream Spoonacular / second-service provider is DROPPED (A7), as are the
//  upstream `withKeychainAPIKey()` (→ faBolus `FoodFinderAIKeyStore`), the UserDefaults persistence
//  extension, and `AISettingsManager` (which reached into services not vendored here).
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//
//  faBolus adapter deltas (09.18c-03, D-13):
//    • provider set reduced to Anthropic / OpenAI / Google only (Spoonacular OUT, A7)
//    • the `apiKey` is loaded from `FoodFinderAIKeyStore` at call time — never persisted in this model
//    • three built-in provider presets added (`.anthropic` / `.openAI` / `.google`)
//  Foundation/os.log only; carries NO carb store, carb entry, bolus-calculator, or delivery symbol (the
//  D-18.1 source-scan guard asserts these symbols are absent from this file).

import Foundation
import os.log

// MARK: - Request Format

/// Determines how the HTTP request body is built and how the response is parsed. The three cases are
/// exactly the Anthropic / OpenAI / Google request shapes (Spoonacular is not a chat provider — OUT).
enum RequestFormat: String, Codable, CaseIterable, Equatable {
    /// OpenAI chat-completion format.
    case openAICompatible
    /// Anthropic Messages API format.
    case anthropicMessages
    /// Google Generative AI (Gemini) format.
    case googleGenerativeAI

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI"
        case .anthropicMessages: return "Anthropic"
        case .googleGenerativeAI: return "Google"
        }
    }

    /// Default response JSON path for extracting the text content.
    var defaultResponseKeyPath: String {
        switch self {
        case .openAICompatible: return "choices.0.message.content"
        case .anthropicMessages: return "content.0.text"
        case .googleGenerativeAI: return "candidates.0.content.parts.0.text"
        }
    }

    /// Default API-key header name.
    var defaultAPIKeyHeader: String {
        switch self {
        case .openAICompatible: return "Authorization"
        case .anthropicMessages: return "x-api-key"
        case .googleGenerativeAI: return "x-goog-api-key"
        }
    }

    /// Default API-key prefix (e.g. "Bearer " for OpenAI).
    var defaultAPIKeyPrefix: String {
        switch self {
        case .openAICompatible: return "Bearer "
        case .anthropicMessages, .googleGenerativeAI: return ""
        }
    }

    /// Default endpoint path (relative to `baseURL`).
    var defaultEndpoint: String {
        switch self {
        case .openAICompatible: return "/chat/completions"
        case .anthropicMessages: return "/messages"
        case .googleGenerativeAI: return "/models/{MODEL}:generateContent"
        }
    }
}

// MARK: - AI Provider Configuration

/// User-configurable AI endpoint for FoodFinder carb estimation. The `apiKey` is transient — it is
/// loaded from `FoodFinderAIKeyStore` (Keychain) at call time and is NEVER persisted in this model
/// (excluded from `Codable`).
struct AIProviderConfiguration: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var endpointPath: String
    var requestFormat: RequestFormat
    var responseKeyPath: String
    var supportsVision: Bool
    var headers: [String: String]

    // Auth
    var apiKeyHeader: String
    var apiKeyPrefix: String

    // Tuning
    var maxTokens: Int
    var temperature: Double

    // Optional
    var apiVersion: String?

    /// Transient — populated from `FoodFinderAIKeyStore` at call time, NOT persisted.
    var apiKey: String

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        model: String,
        endpointPath: String? = nil,
        requestFormat: RequestFormat = .openAICompatible,
        responseKeyPath: String? = nil,
        supportsVision: Bool = true,
        headers: [String: String] = ["Content-Type": "application/json"],
        apiKeyHeader: String? = nil,
        apiKeyPrefix: String? = nil,
        maxTokens: Int = 1024,
        temperature: Double = 0.05,
        apiVersion: String? = nil,
        apiKey: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.endpointPath = endpointPath ?? requestFormat.defaultEndpoint
        self.requestFormat = requestFormat
        self.responseKeyPath = responseKeyPath ?? requestFormat.defaultResponseKeyPath
        self.supportsVision = supportsVision
        self.headers = headers
        self.apiKeyHeader = apiKeyHeader ?? requestFormat.defaultAPIKeyHeader
        self.apiKeyPrefix = apiKeyPrefix ?? requestFormat.defaultAPIKeyPrefix
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.apiVersion = apiVersion
        self.apiKey = apiKey
    }

    /// Returns a copy with the API key loaded from the faBolus Keychain accessor.
    func withStoredAPIKey() -> AIProviderConfiguration {
        var copy = self
        copy.apiKey = FoodFinderAIKeyStore.key() ?? ""
        return copy
    }

    // MARK: - Codable (exclude apiKey from persistence)

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, endpointPath, requestFormat, responseKeyPath
        case supportsVision, headers, apiKeyHeader, apiKeyPrefix
        case maxTokens, temperature, apiVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        endpointPath = try c.decode(String.self, forKey: .endpointPath)
        requestFormat = try c.decode(RequestFormat.self, forKey: .requestFormat)
        responseKeyPath = try c.decode(String.self, forKey: .responseKeyPath)
        supportsVision = try c.decode(Bool.self, forKey: .supportsVision)
        headers = try c.decode([String: String].self, forKey: .headers)
        apiKeyHeader = try c.decode(String.self, forKey: .apiKeyHeader)
        apiKeyPrefix = try c.decode(String.self, forKey: .apiKeyPrefix)
        maxTokens = try c.decode(Int.self, forKey: .maxTokens)
        temperature = try c.decode(Double.self, forKey: .temperature)
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion)
        apiKey = "" // Never decoded — loaded from the Keychain at call time
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
        try c.encode(endpointPath, forKey: .endpointPath)
        try c.encode(requestFormat, forKey: .requestFormat)
        try c.encode(responseKeyPath, forKey: .responseKeyPath)
        try c.encode(supportsVision, forKey: .supportsVision)
        try c.encode(headers, forKey: .headers)
        try c.encode(apiKeyHeader, forKey: .apiKeyHeader)
        try c.encode(apiKeyPrefix, forKey: .apiKeyPrefix)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(temperature, forKey: .temperature)
        try c.encodeIfPresent(apiVersion, forKey: .apiVersion)
        // apiKey intentionally NOT encoded — stored in the Keychain
    }

    // MARK: - Built-in provider presets (BYO key; the three allowed providers only)

    /// The three BYO providers FoodFinder supports. Spoonacular is deliberately absent (A7).
    enum Provider: String, CaseIterable, Identifiable, Equatable {
        case anthropic, openAI, google
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openAI: return "OpenAI"
            case .google: return "Google"
            }
        }
        var keyHelpURL: String {
            switch self {
            case .anthropic: return "https://console.anthropic.com/settings/keys"
            case .openAI: return "https://platform.openai.com/api-keys"
            case .google: return "https://aistudio.google.com/app/apikey"
            }
        }
        /// The default configuration for this provider (user-editable model; sensible current default).
        var configuration: AIProviderConfiguration {
            switch self {
            case .anthropic:
                return AIProviderConfiguration(
                    name: "Anthropic",
                    baseURL: "https://api.anthropic.com/v1",
                    model: "claude-3-5-sonnet-latest",
                    requestFormat: .anthropicMessages,
                    apiVersion: "2023-06-01")
            case .openAI:
                return AIProviderConfiguration(
                    name: "OpenAI",
                    baseURL: "https://api.openai.com/v1",
                    model: "gpt-4o",
                    requestFormat: .openAICompatible)
            case .google:
                return AIProviderConfiguration(
                    name: "Google",
                    baseURL: "https://generativelanguage.googleapis.com/v1beta",
                    model: "gemini-1.5-flash",
                    requestFormat: .googleGenerativeAI)
            }
        }
    }
}
