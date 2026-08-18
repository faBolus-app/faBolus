// Ported from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  FoodFinder_OpenFoodFactsService.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — OpenFoodFacts API client for keyless food-product search + barcode lookup.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//
//  faBolus adapter deltas (09.18c-01, D-03 / RESEARCH Pitfall 1):
//    • base URL  world.openfoodfacts.NET (staging, HTTP-basic-auth)  →  world.openfoodfacts.ORG (production)
//    • barcode   api/v2/product/{barcode}.json (deprecated)          →  api/v3/product/{barcode}.json
//    • text search stays on cgi/search.pl (v3 has no drop-in text-search equivalent) but on the .org host
//    • User-Agent  "Loop-iOS-Diabetes-App/1.0"                       →  "faBolus/<ver> (<contact>)"
//    • the mirror's #if DEBUG MockURLProtocol + its .net / api/v0 mock URLs are DROPPED
//    • strict decode: a response-body byte cap + JSON-only content-type + tolerant Codable
//  Foundation/os.log only; carries NO carb store, carb entry, bolus calculator, or delivery symbol — an
//  estimated carb number leaves FoodFinder ONLY as a string the user confirms into BolusEntryView.carbsText
//  (the D-18.1 source-scan guard asserts these symbols are absent from this file).

import Foundation
import os.log

/// Keyless client for the OpenFoodFacts REST API (product search + barcode lookup). Immutable
/// (`let`-only, Sendable-typed members) so it is safe to use from a detached `Task` (Swift 6 concurrency).
final class OpenFoodFactsService: Sendable {

    // MARK: Configuration

    /// Production host (NOT the mirror's `.net` staging host, which needs HTTP-basic auth).
    static let baseURL = "https://world.openfoodfacts.org"
    /// Hard cap on a decoded response body — an oversized body is rejected, never decoded (DoS guard).
    static let maxResponseBytes = 1_048_576 // 1 MB

    private let session: URLSession
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fabolus.app",
                             category: "OpenFoodFactsService")

    /// OFF policy requires an identifying User-Agent with a contact. faBolus identifies itself with its
    /// app version + project contact (never the mirror's `Loop-iOS-Diabetes-App/1.0`).
    static var userAgent: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        return "faBolus/\(version) (https://github.com/faBolus-app)"
    }

    // MARK: Init

    /// - Parameter session: injectable so decode/error paths are testable without a live network call.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30.0
            config.timeoutIntervalForResource = 60.0
            config.waitsForConnectivity = true
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Public API

    /// Search food products by free text. Uses `cgi/search.pl` on the production `.org` host — kept
    /// deliberately (v3 has no drop-in text-search equivalent), unlike the deprecated `api/v2` product path.
    func searchProducts(query: String, pageSize: Int = 20) async throws -> [OpenFoodFactsProduct] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw OpenFoodFactsError.invalidURL
        }
        let clamped = min(max(pageSize, 1), 50)
        let urlString = "\(Self.baseURL)/cgi/search.pl?search_terms=\(encoded)&search_simple=1&action=process&json=1&page_size=\(clamped)"
        guard let url = URL(string: urlString) else { throw OpenFoodFactsError.invalidURL }

        let data = try await fetch(url)
        let response = try Self.decode(OpenFoodFactsSearchResponse.self, from: data)
        return response.products.filter { $0.hasSufficientNutritionalData }
    }

    /// Look up a single product by barcode on the production v3 endpoint.
    func fetchProduct(barcode: String) async throws -> OpenFoodFactsProduct? {
        let clean = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidBarcode(clean) else { throw OpenFoodFactsError.invalidBarcode }
        let urlString = "\(Self.baseURL)/api/v3/product/\(clean).json"
        guard let url = URL(string: urlString) else { throw OpenFoodFactsError.invalidURL }

        let data = try await fetch(url)
        return try Self.decodeProductResponse(from: data)
    }

    // MARK: Testable strict-decode helpers (no network)

    /// Decode a barcode-lookup body under the strict contract: reject an oversized body BEFORE decoding,
    /// then tolerantly decode `code` + `product`. Returns the product (or `nil` if the response carried
    /// none). Exposed for unit tests so the byte-cap + decode contract is verifiable without a live call.
    static func decodeProductResponse(from data: Data) throws -> OpenFoodFactsProduct? {
        guard data.count <= maxResponseBytes else { throw OpenFoodFactsError.responseTooLarge(data.count) }
        let response = try decode(OpenFoodFactsProductResponse.self, from: data)
        return response.product
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxResponseBytes else { throw OpenFoodFactsError.responseTooLarge(data.count) }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenFoodFactsError.decodingError
        }
    }

    static func isValidBarcode(_ barcode: String) -> Bool {
        guard !barcode.isEmpty else { return false }
        // 8–14 numeric digits covers EAN-8, EAN-13, UPC-A, etc.
        return barcode.range(of: "^[0-9]{8,14}$", options: .regularExpression) != nil
    }

    // MARK: Networking

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30.0

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("OpenFoodFacts network error: \(error.localizedDescription, privacy: .public)")
            throw OpenFoodFactsError.networkError
        }

        guard let http = response as? HTTPURLResponse else { throw OpenFoodFactsError.invalidResponse }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !contentType.contains("json") {
            throw OpenFoodFactsError.invalidResponse
        }
        guard data.count <= Self.maxResponseBytes else {
            throw OpenFoodFactsError.responseTooLarge(data.count)
        }

        switch http.statusCode {
        case 200:
            return data
        case 404:
            throw OpenFoodFactsError.productNotFound
        case 429:
            throw OpenFoodFactsError.rateLimitExceeded
        case 500...599:
            throw OpenFoodFactsError.serverError(http.statusCode)
        default:
            throw OpenFoodFactsError.invalidResponse
        }
    }
}
