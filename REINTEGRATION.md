# REINTEGRATION.md — dev/extended-bolus

## Feature preserved

The **Extended (combo) bolus** surface — the full, working feature as it exists before the
narrow-main gate §1 retirement removes it from `main`. On `main` the feature is force-pinned
off (`extendedBolusEnabled = false`) and runtime-hidden; this branch carries it in its
un-pinned, user-reachable form.

## Base

Cut from `experimental` (the pre-programme tip that demonstrably still contains the full,
un-hidden surface). `main` also compiles the code paths but pins the toggle off; `experimental`
is the tip where the feature is actually reachable and exercisable end-to-end.

## Actual symbols preserved (verified present on this branch)

- **UI** — `ios/faBolus/Views/BolusEntryView.swift`: `extendedBolusSection`
  (`@ViewBuilder`, declared ~:689, rendered ~:721; gated at ~:692 on
  `settings.extendedBolusEnabled && model.capabilities.supportsExtendedBolus`).
- **Settings toggle** — `ios/faBolus/Views/SettingsView.swift`:
  `Toggle("Extended (combo) bolus", isOn: $settings.extendedBolusEnabled)` (~:484).
- **Stored flag** — `ios/faBolus/Data/AppSettings.swift`: `extendedBolusEnabled` stored
  property (~:466), its `defaults` load (~:1021), the force-pin in `AppSettings.init`
  (the §1 pin, `extendedBolusEnabled = false`), the settings-envelope emit (~:1092), and the
  restore hook (~:1175).
- **Settings catalog** — `ios/faBolus/Data/SettingsCatalog.swift`:
  `.init("extendedBolusEnabled", .bolus, from: .advanced, backsUp: true)` (~:110).
- **Capability** — `Packages/faBolusCore/.../Models.swift`: `capabilities.supportsExtendedBolus`
  and the `extendedBolus` gating vocabulary (~:733).
- **Signed write path** — `Packages/faBolusCore/.../GatedPumpWrite.swift`:
  `GatedPumpWrite.deliverExtendedBolus` case and its `requiredMode` / capability mapping
  (~:18/:56/:92/:105); `Packages/faBolusCore/.../PumpBackend.swift`:
  `deliverExtendedBolus(totalUnits:nowUnits:durationMinutes:...)` (~:72) and its
  `TandemBackend` / `MockBackend` implementations.

## Reintegration steps

1. This is a gate-flip + surface restore, not a whole-target strip. The signed
   `deliverExtended` path is a dose/signed-core path under
   `scripts/check-dose-byte-identity.sh`'s `DOSE_PATHS` — any restoration touching
   `GatedPumpWrite` / `PumpBackend` must go through the same byte-identity discipline as the
   original removal, not a verbatim copy-back.
2. Re-derive the UI section and the settings toggle against whatever `BolusEntryView.swift` /
   `SettingsView.swift` look like at reintegration time (the surrounding view bodies will have
   moved); un-pin `extendedBolusEnabled` in `AppSettings.init`.
3. Re-confirm the TandemKit oracle byte-parity and `faBolusCore` tests green with the extended
   path reachable.
