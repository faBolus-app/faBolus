//
//  FoodFinderView.swift
//  faBolus — original (D-12/D-13, 09.18c-01).
//
//  A lean, faBolus-authored carb-estimate surface that REPLACES (does not port) the mirror's 2438-line
//  FoodFinder_EntryPoint + 1698-line FoodFinder_SearchViewModel. Text search → OpenFoodFacts → a
//  carb-estimate card → the single "Add to carbs" confirm.
//
//  SAFETY (D-12): an estimated carb number leaves this surface ONLY as the Int handed to `onApplyGrams`
//  (which BolusEntryView writes into `carbsText`). This view references NO carb-history store, NO
//  closed-loop carb entry, NO bolus calculator, and NO delivery call — the D-18.1 source-scan guard
//  (`FoodFinderCarbSeamGuardTests`) asserts those symbols never appear here. The user still drives the
//  existing calc + hold-to-deliver seam; faBolus never doses automatically.

import SwiftUI
import faBolusDesign

struct FoodFinderView: View {
    /// The ONLY delivery-adjacent output of this surface: the confirmed gram estimate handed back to
    /// `BolusEntryView`, which assigns it into `carbsText`. Nothing else crosses this boundary.
    var onApplyGrams: (Int) -> Void
    /// Injectable so the surface is testable / previewable without a live network call.
    var service: OpenFoodFactsService = OpenFoodFactsService()

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [OpenFoodFactsProduct] = []
    @State private var selected: OpenFoodFactsProduct?
    @State private var servings = 1
    @State private var isSearching = false
    @State private var statusText: String?
    @State private var confirming = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showScanner = false
    @State private var lookupTask: Task<Void, Never>?
    // 09.18c-03 (D-13): the opt-in AI carb-estimate surface. Reachable ONLY when `foodFinderAIEnabled`
    // is on; its estimate flows through the SAME `onApplyGrams` seam as the keyless OFF path.
    @State private var showAIEntry = false

    var body: some View {
        Form {
            searchSection
            if AppSettings.shared.foodFinderAIEnabled {
                aiEntrySection
            }
            if let selected {
                estimateSection(for: selected)
            } else {
                resultsSection
            }
        }
        .navigationTitle("Find food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        // 09.17 readable-width contract: cap the detail width on iPad / regular width.
        .frame(maxWidth: AppTheme.iPadReadableContentMaxWidth)
        .frame(maxWidth: .infinity)
        // 09.18c-02 (D-13): the barcode scanner is an INPUT ADAPTER into this same surface. A scanned
        // barcode resolves via OpenFoodFacts into the EXISTING carb-estimate card + "Add to carbs" confirm
        // seam — it opens no new path to the dose (the scanner only yields a product to estimate over).
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                BarcodeScannerView(onBarcodeScanned: { code in
                    showScanner = false
                    lookupBarcode(code)
                })
            }
        }
        // 09.18c-03 (D-12/D-13): the AI estimate applies through the SAME onApplyGrams seam, then closes
        // both this surface and the AI sheet so the user lands back on the bolus screen with carbsText set.
        .sheet(isPresented: $showAIEntry) {
            NavigationStack {
                FoodFinderAIEntryView(onApplyGrams: { grams in
                    onApplyGrams(grams)
                    dismiss()
                })
            }
        }
        .onDisappear { searchTask?.cancel(); lookupTask?.cancel() }
    }

    // MARK: AI entry (opt-in, default OFF)

    private var aiEntrySection: some View {
        Section {
            Button {
                showAIEntry = true
            } label: {
                Label("Estimate with AI (photo or description)", systemImage: "sparkles")
                    .foregroundStyle(AppTheme.carbs)
            }
        } footer: {
            Text("Uses the AI provider you connected in Settings. Advisory only — the estimate goes into the carb field for you to review.")
        }
    }

    // MARK: Search

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search a food", text: $query)
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                    .accessibilityLabel("Search a food to estimate carbs")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
                // D-13 keyless-default input: scan a barcode instead of typing. Presents the vendored
                // camera scanner; a scanned code resolves through the SAME OFF lookup + estimate card.
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .foregroundStyle(AppTheme.carbs)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan a barcode")
            }
        }
    }

    // MARK: Results / placeholder / status

    @ViewBuilder private var resultsSection: some View {
        if isSearching {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                }
            }
        } else if let statusText {
            Section {
                Text(statusText).font(.footnote).foregroundStyle(.secondary)
            }
        } else if results.isEmpty {
            Section {
                // Documented empty/idle copy (UI-SPEC Copywriting Contract).
                Text("Scan a barcode or search a food to estimate carbs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Section("Results") {
                ForEach(results) { product in
                    Button {
                        select(product)
                    } label: {
                        resultRow(product)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func resultRow(_ product: OpenFoodFactsProduct) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(product.displayName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                if let brands = product.brands, !brands.isEmpty {
                    Text(brands)
                }
                Text(product.servingSizeDisplay)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Carb-estimate card

    @ViewBuilder private func estimateSection(for product: OpenFoodFactsProduct) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(product.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if let brands = product.brands, !brands.isEmpty {
                    Text(brands).font(.footnote).foregroundStyle(.secondary)
                }

                Stepper(value: $servings, in: 1...20) {
                    Text("Servings: \(servings)").font(.body)
                }
                .accessibilityLabel("Servings")

                switch FoodFinderCarbEstimate.estimate(for: product, servings: Double(servings)) {
                case .grams(let grams):
                    estimateReadout(grams: grams)
                    Button {
                        confirming = true
                    } label: {
                        Label("Add to carbs", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.carbs)
                    .disabled(isSearching)
                    // SAFETY confirm (D-12) — verbatim Copywriting Contract copy. On confirm the ENTIRE
                    // action is handing `grams` to `onApplyGrams`; no calc, no units, no delivery.
                    .confirmationDialog("Add \(grams) g to the carb field?",
                                        isPresented: $confirming,
                                        titleVisibility: .visible) {
                        Button("Add to carbs") {
                            onApplyGrams(grams)
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("You'll review and confirm the dose yourself. faBolus never doses for you.")
                    }
                case .manualEntryFallback:
                    Text("We couldn't read the carbs for this item. Enter carbs yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Back to results") { selected = nil }
                    .font(.footnote)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func estimateReadout(grams: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Framing: an estimate the user reviews — never "recommended dose".
            Text("Estimated carbs — you review this")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(grams)")
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.carbs)
                Text("g carbs")
                    .font(.title3)
                    .foregroundStyle(AppTheme.carbs)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Estimated carbs \(grams) grams")
        }
    }

    // MARK: Actions

    private func select(_ product: OpenFoodFactsProduct) {
        servings = 1
        confirming = false
        selected = product
    }

    /// Resolve a scanned barcode through the SAME OpenFoodFacts lookup and land it in the SAME
    /// carb-estimate card as the text path (no parallel card, no new dose path). No-match / network
    /// failures fall back to the documented "enter carbs yourself" copy — never a fabricated estimate,
    /// and never blocking the manual carb field.
    private func lookupBarcode(_ barcode: String) {
        let clean = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        searchTask?.cancel()
        lookupTask?.cancel()
        selected = nil
        results = []
        query = ""
        statusText = nil
        isSearching = true
        lookupTask = Task {
            do {
                let product = try await service.fetchProduct(barcode: clean)
                await MainActor.run {
                    isSearching = false
                    if let product {
                        // Lands in the EXISTING estimate card via the same selection path as text search.
                        select(product)
                    } else {
                        statusText = "No product found for that barcode. Try searching by name, or enter carbs yourself."
                    }
                }
            } catch is CancellationError {
                await MainActor.run { isSearching = false }
            } catch let offError as OpenFoodFactsError {
                await MainActor.run {
                    isSearching = false
                    results = []
                    switch offError {
                    case .productNotFound, .invalidBarcode:
                        // No-match fallback (documented copy) — never a fabricated estimate.
                        statusText = "No product found for that barcode. Try searching by name, or enter carbs yourself."
                    default:
                        statusText = offError.errorDescription
                            ?? "Couldn't reach the food database. Check your connection and try again, or enter carbs yourself."
                    }
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    results = []
                    statusText = "Couldn't reach the food database. Check your connection and try again, or enter carbs yourself."
                }
            }
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        selected = nil
        statusText = nil
        isSearching = true
        searchTask = Task {
            do {
                let products = try await service.searchProducts(query: trimmed)
                await MainActor.run {
                    isSearching = false
                    results = products
                    if products.isEmpty {
                        // No-match fallback — never blocks the manual carb field.
                        statusText = "No product found for that search. Try another name, or enter carbs yourself."
                    }
                }
            } catch is CancellationError {
                await MainActor.run { isSearching = false }
            } catch {
                await MainActor.run {
                    isSearching = false
                    results = []
                    // Network / server error fallback (documented copy).
                    statusText = (error as? OpenFoodFactsError)?.errorDescription
                        ?? "Couldn't reach the food database. Check your connection and try again, or enter carbs yourself."
                }
            }
        }
    }
}
