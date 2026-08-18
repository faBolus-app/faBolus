//
//  FoodFinderCarbEstimate.swift
//  faBolus — original.
//
//  The pure carb-estimate function for FoodFinder (D-03). Turns an OpenFoodFacts product + a serving
//  count into a validated, clamped gram estimate — the number the user reviews on the carb-estimate card
//  and confirms into BolusEntryView.carbsText. Pure Foundation; NO carb store, carb entry, bolus
//  calculator, or delivery symbol (the D-18.1 source-scan guard asserts their absence).

import Foundation
import faBolusCore

enum FoodFinderCarbEstimate {

    /// A sane upper bound for a single carb-estimate entry (grams), clamped to avoid a runaway number.
    static let maxCarbGrams = 1000

    /// The outcome of estimating carbs for a product + serving count.
    enum Estimate: Equatable {
        case grams(Int)
        /// The product carried no usable carbohydrate value — the UI falls back to manual entry rather
        /// than surfacing a fabricated 0-carb number as if it were real data.
        case manualEntryFallback
    }

    /// Carbohydrates for one serving of the product, or `nil` if the product carries no usable
    /// (present, finite, non-negative) carbohydrate value. When the serving quantity is unknown, this
    /// falls back to the per-100g value (mirror parity).
    static func carbsPerServing(from product: OpenFoodFactsProduct) -> Double? {
        guard let per100 = product.nutriments.carbohydrates, per100.isFinite, per100 >= 0 else { return nil }
        guard let servingQuantity = product.servingQuantity, servingQuantity.isFinite, servingQuantity > 0 else {
            return per100
        }
        return per100 * servingQuantity / 100.0
    }

    /// Scale a per-100g carbohydrate value by a serving quantity and serving count, rounded to a
    /// non-negative Int and clamped to `0...maxCarbGrams`. An unknown/zero serving quantity is treated as
    /// a 100 g serving (so the per-100g value is used as-is).
    static func grams(carbsPer100g: Double, servingQuantity: Double, servings: Double) -> Int {
        guard carbsPer100g.isFinite, carbsPer100g >= 0, servings.isFinite, servings >= 0 else { return 0 }
        let quantity = (servingQuantity.isFinite && servingQuantity > 0) ? servingQuantity : 100.0
        let raw = carbsPer100g * quantity / 100.0 * servings
        // Route the untrusted Double→Int through the shared `clampedInt` funnel (faBolusCore): it maps a
        // non-finite `raw` (e.g. an overflow to +inf) to the floor (0) and clamps a finite value in Double
        // space to `0...maxCarbGrams` BEFORE the `Int(_:)`, so a garbled/malicious OFF nutriment (e.g. 1e19,
        // above Int.max) can never trap the carb-estimate card. One guarded path, no re-derived inline clamp.
        return clampedInt(raw, max: maxCarbGrams)
    }

    /// The carb estimate for `servings` servings of a product: `.grams(N)` when the product carries a
    /// usable carbohydrate value, else `.manualEntryFallback` (never a fabricated 0).
    static func estimate(for product: OpenFoodFactsProduct, servings: Double) -> Estimate {
        guard let per100 = product.nutriments.carbohydrates, per100.isFinite, per100 >= 0 else {
            return .manualEntryFallback
        }
        return .grams(grams(carbsPer100g: per100, servingQuantity: product.servingQuantity ?? 0, servings: servings))
    }
}
