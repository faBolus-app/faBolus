//
//  FoodFinderAIEntryView.swift
//  faBolus — original (D-12/D-13, 09.18c-03).
//
//  The opt-in, default-OFF FoodFinder AI carb-estimate surface (photo / text). This is the ONLY
//  FoodFinder path where PHI leaves the device, so it is reachable only when `foodFinderAIEnabled` is on
//  and it self-enforces two gates before ANY provider call: (1) the one-time PHI disclosure
//  (`hasAcknowledgedFoodFinderAINotice`) must be acknowledged, and (2) a BYO API key must be stored in
//  the Keychain (`FoodFinderAIKeyStore`). A returned estimate is parsed by `FoodFinderAICarbParse`
//  (garbage / rejected key → manual-entry fallback, never a fabricated number) and flows through the
//  SAME "Add to carbs" confirm → `onApplyGrams` → `BolusEntryView.carbsText` seam the OFF path uses —
//  never auto-applied, never a dose.
//
//  EXCLUDED (D-13): the Pre-Meal Advisor card and any Location→AI reverse-geocoding.
//
//  This file references NO carb store, carb entry, bolus-calculator, or delivery symbol — the D-18.1
//  source-scan guard (FoodFinderCarbSeamGuardTests) asserts their absence.

import SwiftUI
import PhotosUI
import faBolusDesign

struct FoodFinderAIEntryView: View {
    /// The ONLY delivery-adjacent output: the confirmed gram estimate handed back to BolusEntryView (via
    /// FoodFinderView), which assigns it into `carbsText`. Identical seam to the OFF path.
    var onApplyGrams: (Int) -> Void
    /// Injectable so the surface is previewable/testable without a live provider call.
    var adapter: FoodFinderAIServiceAdapter = FoodFinderAIServiceAdapter()

    @Environment(\.dismiss) private var dismiss

    @AppStorage("foodFinderAIProvider") private var providerRaw = AIProviderConfiguration.Provider.anthropic.rawValue
    @AppStorage("foodFinderAIModelOverride") private var modelOverride = ""

    @State private var description = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var keyInput = ""
    @State private var hasKey = FoodFinderAIKeyStore.hasKey
    @State private var isAnalyzing = false
    @State private var outcome: FoodFinderAICarbParse.Outcome?
    @State private var errorText: String?
    @State private var confirming = false
    @State private var showRemoveKeyConfirm = false
    @State private var showPHIDisclosure = false
    @State private var analyzeTask: Task<Void, Never>?

    private var provider: AIProviderConfiguration.Provider {
        AIProviderConfiguration.Provider(rawValue: providerRaw) ?? .anthropic
    }

    /// The provider configuration with the user's model override applied (if any). The API key is loaded
    /// from the Keychain by the adapter at call time.
    private var configuration: AIProviderConfiguration {
        var config = provider.configuration
        let trimmed = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { config.model = trimmed }
        return config
    }

    var body: some View {
        Form {
            providerSection
            keySection
            inputSection
            resultSection
        }
        .navigationTitle("Estimate carbs with AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .frame(maxWidth: AppTheme.iPadReadableContentMaxWidth)
        .frame(maxWidth: .infinity)
        .alert("Sending data to an AI provider", isPresented: $showPHIDisclosure) {
            Button("I understand") { AppSettings.shared.acknowledgeFoodFinderAINotice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turning this on sends your food photo/description to the AI provider you choose. That's health-adjacent data leaving your device. Only your carb estimate comes back — faBolus never doses automatically.")
        }
        .confirmationDialog("Remove your stored API key?",
                            isPresented: $showRemoveKeyConfirm, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) {
                FoodFinderAIKeyStore.removeKey()
                hasKey = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the key from your device Keychain. You can paste it again anytime.")
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { photoData = try? await newItem.loadTransferable(type: Data.self) }
        }
        .onDisappear { analyzeTask?.cancel() }
    }

    // MARK: Provider

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $providerRaw) {
                ForEach(AIProviderConfiguration.Provider.allCases) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }
            HStack {
                Text("Model").foregroundStyle(.secondary)
                TextField(provider.configuration.model, text: $modelOverride)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("AI provider")
        } footer: {
            Text("Bring your own API key from Anthropic, OpenAI, or Google. Advisory only — the estimate goes into the carb field for you to review; faBolus never doses for you.")
        }
    }

    // MARK: BYO key

    @ViewBuilder private var keySection: some View {
        Section {
            if hasKey {
                HStack {
                    Label("Key stored in Keychain", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove key", role: .destructive) { showRemoveKeyConfirm = true }
                        .font(.footnote)
                }
            } else {
                SecureField("Paste your API key", text: $keyInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save key") {
                    if FoodFinderAIKeyStore.save(key: keyInput) {
                        keyInput = ""
                        hasKey = true
                        errorText = nil
                    }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } footer: {
            Text("Paste your API key. It's stored in your device Keychain and included in your encrypted backup — never sent anywhere except your chosen provider.")
        }
    }

    // MARK: Input

    private var inputSection: some View {
        Section {
            TextField("Describe the food (e.g. \"bowl of oatmeal with berries\")",
                      text: $description, axis: .vertical)
                .lineLimit(1...4)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(photoData == nil ? "Add a photo" : "Photo attached",
                      systemImage: photoData == nil ? "photo" : "checkmark.circle.fill")
            }
            if photoData != nil {
                Button("Remove photo", role: .destructive) { photoData = nil; photoItem = nil }
                    .font(.footnote)
            }
            Button {
                runEstimate()
            } label: {
                HStack {
                    if isAnalyzing { ProgressView().padding(.trailing, 4) }
                    Label("Estimate carbs", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.carbs)
            .disabled(isAnalyzing || (description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoData == nil))
        } header: {
            Text("What did you eat?")
        }
    }

    // MARK: Result

    @ViewBuilder private var resultSection: some View {
        if let errorText {
            Section {
                Text(errorText).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let outcome {
            switch outcome {
            case .grams(let grams):
                Section { estimateCard(grams: grams) }
            case .manualEntryFallback:
                Section {
                    Text("The AI couldn't give a usable carb number. Enter carbs yourself.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func estimateCard(grams: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Framing: an estimate the user reviews — never "recommended dose".
                Text("Estimated carbs — you review this")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(grams)")
                        .font(.system(size: 40, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(AppTheme.carbs)
                    Text("g carbs").font(.title3).foregroundStyle(AppTheme.carbs)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Estimated carbs \(grams) grams")
            }
            Button {
                confirming = true
            } label: {
                Label("Add to carbs", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.carbs)
            // SAFETY confirm (D-12) — verbatim copy. The ENTIRE action is handing `grams` to
            // `onApplyGrams`; no units, no delivery.
            .confirmationDialog("Add \(grams) g to the carb field?",
                                isPresented: $confirming, titleVisibility: .visible) {
                Button("Add to carbs") {
                    onApplyGrams(grams)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll review and confirm the dose yourself. faBolus never doses for you.")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Actions

    /// Run one AI estimate — gated on the one-time PHI disclosure + a stored key, then parsed strictly.
    private func runEstimate() {
        // Gate 1: PHI disclosure must be acknowledged before any PHI leaves the device.
        guard AppSettings.shared.hasAcknowledgedFoodFinderAINotice else {
            showPHIDisclosure = true
            return
        }
        // Gate 2: a BYO key must be configured.
        guard FoodFinderAIKeyStore.hasKey else {
            errorText = "Paste your API key first."
            return
        }
        outcome = nil
        errorText = nil
        isAnalyzing = true
        let prompt = Self.prompt(for: description)
        let imageBase64 = photoData.map { $0.base64EncodedString() }
        let config = configuration
        analyzeTask?.cancel()
        analyzeTask = Task {
            do {
                let text = try await adapter.analyze(prompt: prompt, imageBase64: imageBase64, config: config)
                let parsed = FoodFinderAICarbParse.parse(text)
                await MainActor.run {
                    isAnalyzing = false
                    outcome = parsed
                }
            } catch is CancellationError {
                await MainActor.run { isAnalyzing = false }
            } catch let aiError as FoodFinderAIError {
                await MainActor.run {
                    isAnalyzing = false
                    // A rejected key surfaces the documented copy; every other failure falls back to
                    // manual entry (never a fabricated number).
                    errorText = aiError.errorDescription
                    outcome = aiError == .keyRejected ? nil : .manualEntryFallback
                }
            } catch {
                await MainActor.run {
                    isAnalyzing = false
                    outcome = .manualEntryFallback
                    errorText = "Couldn't reach the AI provider. Enter carbs yourself."
                }
            }
        }
    }

    /// The instruction sent to the provider — asks for ONLY a small JSON object with the total carb
    /// grams, so `FoodFinderAICarbParse` can validate it. Kept advisory + estimate-framed.
    static func prompt(for description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let food = trimmed.isEmpty ? "the food in the image" : trimmed
        return """
        Estimate the total grams of carbohydrate in \(food). \
        Respond with ONLY a JSON object of the form {"carbs_g": <number>} and nothing else. \
        If you cannot estimate it, respond with {"carbs_g": null}.
        """
    }
}
