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
        // Clamp in Double space BEFORE the Int() conversion: a hallucinated/adversarial value above
        // Int.max (e.g. {"carbs_g": 1e19} or a 25-digit prose number) would trap Int(_:) and crash.
        // `maxCarbGrams` is exactly representable as a Double, so Int() of the capped value is safe.
        let capped = min(max(value.rounded(), 0), Double(FoodFinderCarbEstimate.maxCarbGrams))
        return .grams(Int(capped))
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
            // WR-04: JSONSerialization represents JSON true/false as an NSNumber, so a naive
            // `as? NSNumber` would coerce `{"carbs_g": true}` into 1.0. A boolean is not a carb value —
            // skip it (→ manual-entry fallback) rather than fabricating a number.
            if let n = rawValue as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
            if let s = rawValue as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }

    /// The first signed decimal number that is directly attached to a grams unit (e.g. "45 g", "12g",
    /// "3 grams") — NOT merely the first number anywhere in the text. WR-03: taking the first number
    /// surfaced a leading NON-carb figure (a serving count in "2 servings, roughly 55 g", a percentage in
    /// "12% sugar, about 40g carbs") as the estimate on a dose-adjacent surface. Requiring a grams unit
    /// keeps the intended tolerant prose fallback while routing ambiguous, unit-less prose to manual entry.
    private static func firstNumber(in text: String) -> Double? {
        let pattern = "([-+]?[0-9]*\\.?[0-9]+)\\s*g(?:ram(?:me)?s?)?\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return Double(ns.substring(with: match.range(at: 1)))
    }
}
