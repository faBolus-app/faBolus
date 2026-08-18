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

    var body: some View {
        Form {
            searchSection
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
        .onDisappear { searchTask?.cancel() }
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
