//
//  FoodFinderAICarbParse.swift
//  faBolus — original (D-03/D-13, 09.18c-03).
//
//  Strict-but-tolerant parser for the carb number in an AI provider's response. The AI is prompted to
//  return a small JSON object ({"carbs_g": <number>}); this extracts + validates that number into a
//  clamped gram estimate, or falls back to manual entry when the response carries no usable number, a
//  negative value, or a non-finite value. A garbage / refusal / prose response NEVER becomes a
//  fabricated carb input — the user only ever sees a number that survived this validation, and even
//  then only as the reviewed estimate they must confirm into BolusEntryView.carbsText (D-12).
//
//  Pure Foundation; carries NO carb store, carb entry, bolus-calculator, or delivery symbol (the D-18.1
//  source-scan guard, FoodFinderCarbSeamGuardTests, asserts their absence from this file).

import Foundation

enum FoodFinderAICarbParse {

    /// The outcome of parsing an AI response for a carb number. Mirrors `FoodFinderCarbEstimate.Estimate`
    /// so the AI path and the OpenFoodFacts path present the SAME two-case shape to the UI.
    enum Outcome: Equatable {
        case grams(Int)
        /// The response carried no usable carb number — the UI falls back to manual entry rather than
        /// surfacing a fabricated value as if it were a real estimate.
        case manualEntryFallback
    }

    /// The JSON keys (compared case-insensitively, non-alphanumerics stripped) that may carry the carb
    /// number when the provider returns a structured object.
    private static let carbKeys: Set<String> = [
        "carbsg", "carbs", "carbohydrates", "carbohydratesg", "carbgrams", "grams", "totalcarbs",
    ]

    /// Parse an AI response body of arbitrary text into a validated, clamped gram estimate. A usable
    /// positive value is rounded to a non-negative Int and clamped to `0...FoodFinderCarbEstimate
    /// .maxCarbGrams` (the same sane ceiling the OpenFoodFacts path uses); anything else falls back.
    static func parse(_ text: String) -> Outcome {
        guard let value = extractNumber(from: text) else { return .manualEntryFallback }
        // Non-finite / negative are not usable estimates → manual-entry fallback (never a fabricated 0).
        guard value.isFinite, value >= 0 else { return .manualEntryFallback }
        let clamped = min(max(Int(value.rounded()), 0), FoodFinderCarbEstimate.maxCarbGrams)
        return .grams(clamped)
    }

    // MARK: - Extraction

    /// Prefer a structured JSON carb field; fall back to the first plausible number anywhere in the text.
    private static func extractNumber(from text: String) -> Double? {
        if let v = jsonCarbValue(from: text) { return v }
        return firstNumber(in: text)
    }

    /// Find a `{ … }` JSON object anywhere in the text and read a carb field from it. Tolerates the
    /// number arriving as a JSON number OR a numeric string. Returns `nil` if no object / no carb key.
    private static func jsonCarbValue(from text: String) -> Double? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (rawKey, rawValue) in obj {
            let normalized = rawKey.lowercased().filter { $0.isLetter }
            guard carbKeys.contains(normalized) else { continue }
            if let n = rawValue as? NSNumber { return n.doubleValue }
            if let s = rawValue as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }

    /// The first signed decimal number appearing in the text (tolerant free-text fallback, e.g. "≈ 45 g").
    private static func firstNumber(in text: String) -> Double? {
        guard let range = text.range(of: "[-+]?[0-9]*\\.?[0-9]+", options: .regularExpression) else {
            return nil
        }
        return Double(text[range])
    }
}
