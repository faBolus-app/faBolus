# Plan — finish the faBolus rebrand (remove every ControlX2 remnant)

The **display-name pass is done** (target names, `CFBundleDisplayName`, Siri names, in-app text,
`fabolus://` deep-link scheme). What remains is the **identity + structure** rebrand so nothing reads
`ControlX2`/`controlx2` anywhere, plus the repo renames.

## Locked decisions
- **Display name:** `faBolus`. **Identifiers / paths / schemes:** `fabolus` (lowercase).
- **Bundle IDs (product-centric):**
  - app `com.fabolus.app`
  - iOS widgets `com.fabolus.app.widgets`
  - watch app `com.fabolus.app.watch`
  - watch complication `com.fabolus.app.watch.widgets`
  - (`.app` included on purpose — nests extensions cleanly and satisfies the "extension ID must be
    prefixed by the app ID" rule; `com.fabolus` is the reverse-domain namespace.)
- **App Group:** `group.com.fabolus.app`
- **Repos:** `ControlX2iOS → faBolus`, `PumpX2Garmin → faBolusGarmin`; **`PumpX2Kit` unchanged**.

## Why this is bigger than a display change (blast radius)
Bundle ID + App Group + Keychain are load-bearing. Changing them means: new App IDs (auto-created),
the **App Group must be re-registered and re-enabled on all 4 targets** (the known GUI friction), the
stored pump-pairing secret is orphaned (**one re-pair on the bench**), and placed widgets need
re-adding. Do it as **one branch/PR**, verify a clean install, then rename the repos.

---

## Work items

### 1. `project.yml` — IDs, App Group, paths
- `bundleIdPrefix: com.fabolus`; set each target's `PRODUCT_BUNDLE_IDENTIFIER` to the IDs above.
- `WKCompanionAppBundleIdentifier: com.fabolus.app` (watch target).
- App Group `group.com.fabolus.app` in every target's `entitlements` block.
- Update `sources:`, `entitlements: path:`, `info: path:` to the renamed folders/files (item 5).
- `CFBundleURLName`s (`com.zgranowitz.controlx2.ciq` / `.deeplink`) → `com.fabolus.app.*`.

### 2. App Group — the operational step
- `Shared/WidgetShared.swift`: `WidgetStore.appGroup = "group.com.fabolus.app"`.
- After `xcodegen generate`, **enable App Groups → `group.com.fabolus.app` on all 4 targets** in
  Xcode → Signing & Capabilities (registers it on the new App IDs). Same one-time step we just did
  for the watch. Until then, signed builds fail on `application-groups`.
- Consequence: the published widget snapshot + widget-bolus state reset (regenerated on next update).

### 3. Keychain (pairing secrets)
- `PairingStore.service` → `com.fabolus.app.pairing`; `WatchPairingStore.service` →
  `com.fabolus.app.watch.pairing`.
- Consequence: existing stored secret is orphaned → **re-pair the pump once** (bench, fresh code).
  (Alternative: keep the old service strings to avoid a re-pair — but that leaves a hidden
  `controlx2` remnant; we're choosing clean.)

### 4. Internal identifiers that must stay in sync (change all sites together)
- **Widget kinds:** `ControlX2Glucose` / `ControlX2Status` / `ControlX2Bolus` / `ControlX2QuickBolus`
  → `fabolus*`. Change each `StaticConfiguration(kind:)` **and** every
  `WidgetCenter…reloadTimelines(ofKind:)` (AppSettings, WidgetBolusReceiver, WidgetBolusIntents,
  WatchModel). Placed widgets/complications get orphaned → re-add after install.
- **Darwin notifications:** `com.zgranowitz.controlx2.widgetBolus` / `.widgetBolusCancel` →
  `com.fabolus.app.*`. Poster (widget intents) + observer (WidgetBolusReceiver) must match.
- **CB restore identifiers:** `…controlx2.pump` / `…controlx2.watch.pump` → `com.fabolus.app.pump` /
  `…watch.pump`.
- **CIQ callback scheme:** `controlx2ciq` → `fabolusciq` in `GarminRemoteBridge.urlScheme` **and**
  Info.plist `CFBundleURLSchemes` (keep `LSApplicationQueriesSchemes: [gcm-ciq]`).

### 5. Folder + file renames (use `git mv` to keep history)
- `ios/ControlX2 → ios/faBolus`, `ios/ControlX2Widgets → ios/faBolusWidgets`,
  `watch/ControlX2Watch → watch/faBolusWatch`, `watch/ControlX2WatchWidgets → watch/faBolusWatchWidgets`.
- Entitlement files: `ControlX2.entitlements → faBolus.entitlements` (and the widget/watch ones).
- Update all `project.yml` paths to match.

### 6. Swift type / symbol names (cosmetic but "no remnant")
- `struct ControlX2App` (@main) → `FaBolusApp`; `ControlX2DeepLink → FaBolusDeepLink`;
  `ControlX2Provider`/`ControlX2Entry`/`ControlX2WidgetBundle` → `FaBolus…`;
  `ControlX2Shortcuts → FaBolusShortcuts`; any other `ControlX2*` type. Update references.

### 7. Garmin (`garmin/` + the `PumpX2Garmin`/`faBolusGarmin` repo)
- `garmin/manifest.xml` app name; `resources` strings `ControlX2 → faBolus`.
- **Keep the Monkey C app UUID unless you deliberately regenerate it** — it must equal
  `GarminRemoteBridge.watchAppUUID`. If you change it, change both sides.
- Align the CIQ callback scheme (`fabolusciq`) with item 4. Rebuild the `.iq`.
- Update `faBolusGarmin` README/HANDOFF references to the app repo's new name.

### 8. Docs (mkdocs)
- `mkdocs.yml`: `site_name`, `site_url` (→ `https://zgranowitz.github.io/faBolus/`), `repo_url`,
  `edit_uri`, `copyright`, nav.
- All `ControlX2` prose + the repo table/links (GitHub URLs) + screenshot alt text.
- `.github/workflows/docs.yml` (Pages deploy) — verify it still targets the renamed repo/Pages.

### 9. Repo renames (GitHub + local)
- GitHub: rename `ControlX2iOS → faBolus` and `PumpX2Garmin → faBolusGarmin` (Settings → Rename;
  GitHub keeps redirects for old URLs).
- Local: `git remote set-url origin …/faBolus.git` (and the Garmin repo). Renaming the **local
  folders** is optional — the `packages: PumpX2Kit: path: ../PumpX2Kit` is a **relative sibling
  path**, so it keeps working as long as PumpX2Kit stays a sibling.
- Fix cross-repo references: `PumpX2Kit` README (if it links ControlX2iOS), `faBolusGarmin`
  HANDOFF/README, docs links, GitHub Pages URL.

### 10. Verify + clean up
- `grep -rin 'controlx2' .` (excluding `.git`, build dirs) → **zero** hits.
- Build **all** targets → install → **re-pair the pump** → verify: dashboard, bolus (+ widget Quick
  Bolus re-added), Siri/Shortcuts under the new app name, watch app + complication, Garmin remote.
- Update the memory notes that reference `ControlX2iOS` paths.

---

## Recommended order (one atomic branch)
1. `project.yml` (IDs, App Group, WKCompanion, URL names) + `git mv` folders/entitlements + fix paths.
2. Shared/code identifiers: App Group constant, DeepLink, Darwin names, Keychain services, restore
   ids, widget kinds, CIQ scheme; then Swift type renames.
3. Garmin + docs.
4. `xcodegen generate` → **enable App Group on all 4 targets in Xcode** → build → install →
   **re-pair pump** → full verify.
5. Final `grep` sweep = zero remnants; commit/PR.
6. Rename the two GitHub repos; update remotes + cross-repo refs + Pages URL; redeploy docs.

## Risks / call-outs
- **App Group re-enable on 4 targets** (GUI, one-time) — the recurring friction; nothing signs until done.
- **One pump re-pair** (Keychain service change) — expected, bench only.
- **Placed widgets/complication must be re-added** (kind change).
- Do the rebrand + verify install **before** renaming repos, to keep the blast radius small.
- The physical-watch dev-registration blocker (see `watch-handoff.md`) is unrelated and still applies
  to seeing it on the watch.
