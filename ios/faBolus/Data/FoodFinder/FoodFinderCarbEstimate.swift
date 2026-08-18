//
//  FoodFinderCarbEstimate.swift
//  faBolus — original.
//
//  The pure carb-estimate function for FoodFinder (D-03). Turns an OpenFoodFacts product + a serving
//  count into a validated, clamped gram estimate — the number the user reviews on the carb-estimate card
//  and confirms into BolusEntryView.carbsText. Pure Foundation; NO carb store, carb entry, bolus
//  calculator, or delivery symbol (the D-18.1 source-scan guard asserts their absence).

import Foundation

enum FoodFinderCarbEstimate {

    // RED STUB (Task 2 TDD): returns sentinels so FoodFinderOFFDecodeTests fail before the real math lands.

    /// A sane upper bound for a single carb-estimate entry (grams), clamped to avoid a runaway number.
    static let maxCarbGrams = 1000

    /// The outcome of estimating carbs for a product + serving count.
    enum Estimate: Equatable {
        case grams(Int)
        /// The product carried no usable carbohydrate value — the UI falls back to manual entry rather
        /// than surfacing a fabricated 0-carb number as if it were real data.
        case manualEntryFallback
    }

    static func carbsPerServing(from product: OpenFoodFactsProduct) -> Double? { nil }

    static func grams(carbsPer100g: Double, servingQuantity: Double, servings: Double) -> Int { 0 }

    static func estimate(for product: OpenFoodFactsProduct, servings: Double) -> Estimate { .manualEntryFallback }
}
