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

    @Test func estimateForProductReturnsScaledGrams() throws {
        let product = try Self.product(from: Self.v3ProductJSON)
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 1) == .grams(15))
        #expect(FoodFinderCarbEstimate.estimate(for: product, servings: 2) == .grams(30))
    }
}
