// Ported from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  FoodFinder_Models.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Data models for OpenFoodFacts API responses and food products.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//
//  faBolus adapter deltas (09.18c-01, D-03): reduced to the fields the keyless carb-estimate path needs;
//  `Nutriments.carbohydrates` made OPTIONAL for strict decode (missing carbs → nil → a manual-entry
//  fallback, never a fabricated 0-carb number); the product-response decode ignores the `status`/
//  `status_verbose` field entirely so it tolerates BOTH the v2 integer-status and v3 string-status
//  shapes (it only needs `code` + `product`). Foundation-only; carries NO carb store, carb entry, bolus
//  calculator, or delivery symbol (the D-18.1 source-scan guard asserts their absence).

import Foundation
import faBolusCore

// MARK: - OpenFoodFacts API Response Models

/// Root response for the OpenFoodFacts text-search endpoint (`cgi/search.pl`).
struct OpenFoodFactsSearchResponse: Codable {
    let products: [OpenFoodFactsProduct]
    let count: Int?
    let page: Int?
    let pageCount: Int?
    let pageSize: Int?

    enum CodingKeys: String, CodingKey {
        case products
        case count
        case page
        case pageCount = "page_count"
        case pageSize = "page_size"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.products = (try? container.decodeIfPresent([OpenFoodFactsProduct].self, forKey: .products)) ?? []
        self.count = try? container.decodeIfPresent(Int.self, forKey: .count)
        self.page = try? container.decodeIfPresent(Int.self, forKey: .page)
        self.pageCount = try? container.decodeIfPresent(Int.self, forKey: .pageCount)
        self.pageSize = try? container.decodeIfPresent(Int.self, forKey: .pageSize)
    }

    init(products: [OpenFoodFactsProduct]) {
        self.products = products
        self.count = products.count
        self.page = 1
        self.pageCount = 1
        self.pageSize = products.count
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(products, forKey: .products)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encodeIfPresent(page, forKey: .page)
        try container.encodeIfPresent(pageCount, forKey: .pageCount)
        try container.encodeIfPresent(pageSize, forKey: .pageSize)
    }
}

/// Response for a single product lookup by barcode. Decodes ONLY `code` + `product`; the OFF `status`
/// field is `1`/`0` (v2) or `"success"`/`"failure"` (v3) — we tolerate both by not decoding it at all.
struct OpenFoodFactsProductResponse: Codable {
    let code: String?
    let product: OpenFoodFactsProduct?

    enum CodingKeys: String, CodingKey {
        case code
        case product
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try? container.decodeIfPresent(String.self, forKey: .code)
        self.product = try? container.decodeIfPresent(OpenFoodFactsProduct.self, forKey: .product)
    }

    init(code: String?, product: OpenFoodFactsProduct?) {
        self.code = code
        self.product = product
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(product, forKey: .product)
    }
}

// MARK: - Core Product Model

/// A food product from the OpenFoodFacts database — the untrusted third-party JSON that crosses into a
/// carb estimate. Every nutriment/serving field is optional (strict decode).
struct OpenFoodFactsProduct: Codable, Identifiable, Hashable {
    let id: String
    let productName: String?
    let brands: String?
    let nutriments: Nutriments
    let servingSize: String?
    let servingQuantity: Double?
    let code: String? // barcode

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case brands
        case nutriments
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let code = try? container.decodeIfPresent(String.self, forKey: .code)
        let productName = try? container.decodeIfPresent(String.self, forKey: .productName)

        // Stable identity: barcode if present, else a synthetic id derived from the name.
        if let code = code, !code.isEmpty {
            self.id = code
            self.code = code
        } else {
            let name = productName ?? "unknown"
            // WR-02: `abs(name.hashValue)` traps when hashValue == Int.min (no positive representation).
            // A non-trapping unsigned bit-pattern gives a stable, always-valid synthetic id.
            self.id = "synthetic_\(UInt(bitPattern: name.hashValue))"
            self.code = nil
        }

        self.productName = productName
        self.brands = try? container.decodeIfPresent(String.self, forKey: .brands)
        // Missing/garbled nutriments decode to an all-nil Nutriments (never throws).
        self.nutriments = (try? container.decode(Nutriments.self, forKey: .nutriments)) ?? Nutriments.empty()
        self.servingSize = try? container.decodeIfPresent(String.self, forKey: .servingSize)
        // OFF returns `serving_quantity` as a Double or a String ("30") — tolerate both (mirror parity).
        if let q = try? container.decodeIfPresent(Double.self, forKey: .servingQuantity) {
            self.servingQuantity = q
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .servingQuantity) {
            self.servingQuantity = Double(s)
        } else {
            self.servingQuantity = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(productName, forKey: .productName)
        try container.encodeIfPresent(brands, forKey: .brands)
        try container.encode(nutriments, forKey: .nutriments)
        try container.encodeIfPresent(servingSize, forKey: .servingSize)
        try container.encodeIfPresent(servingQuantity, forKey: .servingQuantity)
        try container.encodeIfPresent(code, forKey: .code)
    }

    /// Memberwise init for tests / programmatic construction.
    init(id: String,
         productName: String?,
         brands: String?,
         nutriments: Nutriments,
         servingSize: String?,
         servingQuantity: Double?,
         code: String?) {
        self.id = id
        self.productName = productName
        self.brands = brands
        self.nutriments = nutriments
        self.servingSize = servingSize
        self.servingQuantity = servingQuantity
        self.code = code
    }

    // MARK: Computed display helpers (no dose logic)

    /// Display name with a fallback chain (name → brand → localized "Unknown Product").
    var displayName: String {
        if let productName, !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return productName
        } else if let brands, !brands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return brands
        } else {
            return NSLocalizedString("Unknown Product", comment: "Fallback name for products without names")
        }
    }

    /// A human-readable serving descriptor for the results list / card.
    var servingSizeDisplay: String {
        if let servingSize, !servingSize.isEmpty {
            return servingSize
        } else if let servingQuantity, servingQuantity.isFinite, servingQuantity > 0 {
            // Route the untrusted OFF `serving_quantity` through the shared `clampedInt` funnel (faBolusCore):
            // it clamps in Double space to `0...100_000` (a sane 100 kg display bound) BEFORE the `Int(_:)`,
            // so an unbounded value above Int.max (e.g. 1e19) can never trap the results-list / card render
            // (every row calls this). One guarded path — no re-derived inline clamp per site.
            let g = clampedInt(servingQuantity, max: 100_000)
            return "\(g) g"
        } else {
            return "100 g"
        }
    }

    /// Whether this product carries a usable, non-negative, finite carbohydrate value.
    var hasSufficientNutritionalData: Bool {
        guard let carbs = nutriments.carbohydrates else { return false }
        return carbs.isFinite && carbs >= 0 && !displayName.isEmpty
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: OpenFoodFactsProduct, rhs: OpenFoodFactsProduct) -> Bool { lhs.id == rhs.id }
}

/// Nutritional values, keyed off the OFF per-100g fields. All optional — a missing carb value is `nil`
/// (never coerced to 0), so downstream code can distinguish "no data" from "zero carbs".
struct Nutriments: Codable, Hashable {
    let carbohydrates: Double?
    let sugars: Double?
    let proteins: Double?
    let fat: Double?

    enum CodingKeys: String, CodingKey {
        case carbohydrates100g = "carbohydrates_100g"
        case sugars100g = "sugars_100g"
        case proteins100g = "proteins_100g"
        case fat100g = "fat_100g"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Base on the per-100g values; serving-size scaling is applied by FoodFinderCarbEstimate.
        self.carbohydrates = try? container.decodeIfPresent(Double.self, forKey: .carbohydrates100g)
        self.sugars = try? container.decodeIfPresent(Double.self, forKey: .sugars100g)
        self.proteins = try? container.decodeIfPresent(Double.self, forKey: .proteins100g)
        self.fat = try? container.decodeIfPresent(Double.self, forKey: .fat100g)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(carbohydrates, forKey: .carbohydrates100g)
        try container.encodeIfPresent(sugars, forKey: .sugars100g)
        try container.encodeIfPresent(proteins, forKey: .proteins100g)
        try container.encodeIfPresent(fat, forKey: .fat100g)
    }

    init(carbohydrates: Double?, sugars: Double? = nil, proteins: Double? = nil, fat: Double? = nil) {
        self.carbohydrates = carbohydrates
        self.sugars = sugars
        self.proteins = proteins
        self.fat = fat
    }

    static func empty() -> Nutriments { Nutriments(carbohydrates: nil) }
}

// MARK: - Error Type

/// Errors surfaced by the OpenFoodFacts client. All map to a user-facing "enter carbs yourself" fallback
/// at the UI — none blocks the manual carb field.
enum OpenFoodFactsError: Error, LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case responseTooLarge(Int)
    case decodingError
    case networkError
    case productNotFound
    case invalidBarcode
    case rateLimitExceeded
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("Invalid API URL", comment: "OpenFoodFacts invalid URL")
        case .invalidResponse:
            return NSLocalizedString("Invalid API response", comment: "OpenFoodFacts invalid response")
        case .responseTooLarge:
            return NSLocalizedString("The food database response was too large.", comment: "OpenFoodFacts oversized response")
        case .decodingError:
            return NSLocalizedString("The food database response was unreadable.", comment: "OpenFoodFacts decode failure")
        case .networkError:
            return NSLocalizedString("Couldn't reach the food database. Check your connection and try again, or enter carbs yourself.", comment: "OpenFoodFacts network error")
        case .productNotFound:
            return NSLocalizedString("No product found for that barcode. Try searching by name, or enter carbs yourself.", comment: "OpenFoodFacts product not found")
        case .invalidBarcode:
            return NSLocalizedString("Invalid barcode format", comment: "OpenFoodFacts invalid barcode")
        case .rateLimitExceeded:
            return NSLocalizedString("Too many requests. Please try again in a moment.", comment: "OpenFoodFacts rate limited")
        case .serverError(let code):
            return String(format: NSLocalizedString("Food database error (%d)", comment: "OpenFoodFacts server error"), code)
        }
    }
}
