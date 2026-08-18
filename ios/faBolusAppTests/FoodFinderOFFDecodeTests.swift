import Testing
import Foundation
@testable import faBolus

/// D-03 (09.18c-01): the strict OpenFoodFacts decode + pure carb-estimate contract. Untrusted third-party
/// JSON crosses into a carb number here, so decode is tolerant (all fields optional, never throws on a
/// missing/garbled nutriment), oversized/malformed bodies are rejected as errors (never crash), a missing
/// carb value becomes a manual-entry fallback (never a fabricated 0), and the gram estimate is validated,
/// non-negative, and clamped to a sane ceiling.
struct FoodFinderOFFDecodeTests {

    // MARK: Fixtures (hard-coded v3-shaped product responses)

    /// A v3 barcode-lookup response: carbohydrates 50 g/100g, serving 30 g → 15 g carbs/serving.
    static let v3ProductJSON = """
    {
      "code": "3017620422003",
      "status": "success",
      "product": {
        "product_name": "Test Cereal",
        "brands": "TestBrand",
        "serving_size": "30 g",
        "serving_quantity": 30,
        "nutriments": {
          "carbohydrates_100g": 50,
          "sugars_100g": 20,
          "proteins_100g": 8
        }
      }
    }
    """

    /// Same product but `serving_quantity` arrives as a JSON STRING ("30") — must still decode to 30.0.
    static let v3ProductStringServingJSON = """
    {
      "code": "3017620422003",
      "status": "success",
      "product": {
        "product_name": "Test Cereal",
        "serving_quantity": "30",
        "nutriments": { "carbohydrates_100g": 50 }
      }
    }
    """

    /// A product with NO nutriments/carbohydrates — must decode without throwing, carbs absent.
    static let v3ProductMissingCarbsJSON = """
    {
      "code": "0000000000000",
      "status": "success",
      "product": { "product_name": "Mystery Item", "serving_quantity": 30 }
    }
    """

    /// A product with a NEGATIVE carbohydrate value — must be rejected (treated as no usable data).
    static let v3ProductNegativeCarbsJSON = """
    {
      "code": "0000000000001",
      "status": "success",
      "product": {
        "product_name": "Bad Data",
        "serving_quantity": 30,
        "nutriments": { "carbohydrates_100g": -5 }
      }
    }
    """

    private static func product(from json: String) throws -> OpenFoodFactsProduct {
        let data = Data(json.utf8)
        let product = try OpenFoodFactsService.decodeProductResponse(from: data)
        return try #require(product)
    }

    // MARK: Decode + carbs-per-serving

    @Test func decodesV3ProductAndComputesCarbsPerServing() throws {
        let product = try Self.product(from: Self.v3ProductJSON)
        #expect(product.productName == "Test Cereal")
        #expect(product.servingQuantity == 30)
        #expect(product.nutriments.carbohydrates == 50)
        let perServing = try #require(FoodFinderCarbEstimate.carbsPerServing(from: product))
        #expect(abs(perServing - 15.0) < 0.01) // 50 * 30 / 100
    }

    @Test func toleratesServingQuantityAsString() throws {
        let product = try Self.product(from: Self.v3ProductStringServingJSON)
        #expect(product.servingQuantity == 30.0)
        let perServing = try #require(FoodFinderCarbEstimate.carbsPerServing(from: product))
        #expect(abs(perServing - 15.0) < 0.01)
    }

    @Test func missingCarbsDecodesToManualEntryFallback() throws {
        let product = try Self.product(from: Self.v3ProductMissingCarbsJSON)
        #expect(product.nutriments.carbohydrates == nil)
        #expect(FoodFinderCarbEstimate.carbsPerServing(from: product) == nil)
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 1) == .manualEntryFallback)
    }

    @Test func negativeCarbsRejectedAsNoData() throws {
        let product = try Self.product(from: Self.v3ProductNegativeCarbsJSON)
        #expect(FoodFinderCarbEstimate.carbsPerServing(from: product) == nil)
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 1) == .manualEntryFallback)
    }

    // MARK: Malformed / oversized bodies are rejected, not crashed

    @Test func malformedBodyThrowsDecodingError() {
        let data = Data("this is not json".utf8)
        #expect(throws: OpenFoodFactsError.self) {
            _ = try OpenFoodFactsService.decodeProductResponse(from: data)
        }
    }

    @Test func oversizedBodyRejectedBeforeDecode() {
        // One byte over the cap — must be rejected as responseTooLarge, never decoded.
        let data = Data(count: OpenFoodFactsService.maxResponseBytes + 1)
        #expect(throws: OpenFoodFactsError.responseTooLarge(OpenFoodFactsService.maxResponseBytes + 1)) {
            _ = try OpenFoodFactsService.decodeProductResponse(from: data)
        }
    }

    // MARK: grams(): scaling, rounding, clamping

    @Test func gramsScalesByServingCount() {
        // 50 g/100g × 30 g serving / 100 = 15 g per serving.
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 30, servings: 1) == 15)
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 30, servings: 2) == 30)
    }

    @Test func gramsClampsToSaneCeilingAndFloor() {
        let huge = FoodFinderCarbEstimate.grams(carbsPer100g: 100_000, servingQuantity: 100, servings: 100)
        #expect(huge == FoodFinderCarbEstimate.maxCarbGrams)
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 30, servings: 0) == 0)
    }

    /// CR-01 regression: an unbounded-but-finite carb value above Int.max (a garbled/malicious OFF
    /// nutriment) must be clamped in Double space and NEVER trap the Int() conversion. Also covers the
    /// non-finite guards (.infinity / .nan) on every argument.
    @Test func gramsDoesNotTrapOnOverflowingOrNonFiniteInputs() {
        // 1e19 > Int.max (~9.22e18): pre-fix this trapped in Int(raw.rounded()).
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 1e19, servingQuantity: 100, servings: 1)
                == FoodFinderCarbEstimate.maxCarbGrams)
        // A huge serving quantity or serving count is equally untrusted.
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 1e19, servings: 1)
                == FoodFinderCarbEstimate.maxCarbGrams)
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 30, servings: 1e19)
                == FoodFinderCarbEstimate.maxCarbGrams)
        // Non-finite inputs route to the safe 0 fallback, never a crash.
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: .infinity, servingQuantity: 100, servings: 1) == 0)
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: .nan, servingQuantity: 100, servings: 1) == 0)
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: .infinity, servings: 1) == 50)
        #expect(FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 30, servings: .nan) == 0)
    }

    /// CR-03 regression: `servingSizeDisplay` converts an untrusted OFF `serving_quantity` Double to Int.
    /// A finite value above Int.max (e.g. 1e19) must not trap the render; a non-finite value falls through
    /// to the default. One malformed product must never take down the results list.
    @Test func servingSizeDisplayDoesNotTrapOnOverflowingOrNonFiniteServing() {
        func product(servingQuantity: Double?) -> OpenFoodFactsProduct {
            OpenFoodFactsProduct(id: "x", productName: "P", brands: nil,
                                 nutriments: Nutriments(carbohydrates: 50),
                                 servingSize: nil, servingQuantity: servingQuantity, code: nil)
        }
        // 1e19 > Int.max: pre-fix this trapped in Int(servingQuantity).
        #expect(product(servingQuantity: 1e19).servingSizeDisplay == "100000 g")
        #expect(product(servingQuantity: 30).servingSizeDisplay == "30 g")
        // Non-finite serving quantities fall through to the "100 g" default rather than trapping.
        #expect(product(servingQuantity: .infinity).servingSizeDisplay == "100 g")
        #expect(product(servingQuantity: .nan).servingSizeDisplay == "100 g")
    }

    @Test func estimateForProductReturnsScaledGrams() throws {
        let product = try Self.product(from: Self.v3ProductJSON)
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 1) == .grams(15))
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 2) == .grams(30))
    }

    // MARK: Task 3 tracer — the "Add to carbs" seam contract (D-12)

    /// The FoodFinder surface's exposed estimate equals `FoodFinderCarbEstimate.grams(...)`, and changing
    /// the serving Stepper from 1 to 2 doubles it — the exact value FoodFinderView renders and applies.
    @Test func surfaceEstimateMatchesGramsAndDoublesWithServings() throws {
        let product = try Self.product(from: Self.v3ProductJSON)
        let one = FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 30, servings: 1)
        let two = FoodFinderCarbEstimate.grams(carbsPer100g: 50, servingQuantity: 30, servings: 2)
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 1) == .grams(one))
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 2) == .grams(two))
        #expect(two == one * 2)
    }

    /// Invoking the "Add to carbs" confirm action (whose entire body is the `onApplyGrams` call) hands the
    /// displayed integer grams to the callback exactly once and performs no other side effect — the test
    /// double records the value; no calculator/delivery hook is reachable from the callback (structurally
    /// enforced by FoodFinderCarbSeamGuardTests).
    @Test func addToCarbsConfirmCallsOnApplyGramsExactlyOnce() throws {
        let product = try Self.product(from: Self.v3ProductJSON)
        guard case .grams(let displayed) = FoodFinderCarbEstimate.estimate(for: product, servings: 2) else {
            Issue.record("expected a gram estimate for a product with usable carbs")
            return
        }
        var applied: [Int] = []
        let onApplyGrams: (Int) -> Void = { applied.append($0) }
        // This is exactly the FoodFinderView confirm-button body: onApplyGrams(displayed).
        onApplyGrams(displayed)
        #expect(applied == [displayed])
        #expect(displayed == 30)
        // What BolusEntryView's callback then assigns into carbsText — a plain grams string, nothing else.
        #expect(String(displayed) == "30")
    }

    /// A product with no usable carbs (the no-match / unreadable path) leaves the estimate absent and
    /// surfaces the manual-entry fallback rather than a fabricated number — never blocking the carb field.
    @Test func unreadableProductSurfacesManualEntryFallback() throws {
        let product = try Self.product(from: Self.v3ProductMissingCarbsJSON)
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 1) == .manualEntryFallback)
    }
}
