import SwiftUI

/// The ONE guarded-boolean-toggle contract for the whole settings surface (D-05/SC3). Generalized from
/// `AlertRulesView`'s pre-existing `suppressBinding` Binding-intercept model (09.3-RESEARCH.md
/// "Recommended extraction", lines 445-476): `get`/`set` name the real backing property; `skipConfirmIf`
/// lets an already-acknowledged flag bypass the dialog (Shape 2 sites); `requestConfirm` flips whatever
/// `@State` flag drives the caller's `confirmationDialog`.
///
/// Contract:
/// - Reading the binding always returns the real backing value (`get()`) — never a staged value.
/// - Enabling (`true`) when `skipConfirmIf()` is false calls `requestConfirm()` only — `set` is NOT
///   called, so Cancel's snap-back is free: because the backing was never written, a re-read of `get()`
///   still returns false.
/// - Enabling when `skipConfirmIf()` is true calls `set(true)` immediately and never touches
///   `requestConfirm`.
/// - Disabling (`false`) always calls `set(false)` immediately — turning OFF is never confirmed, matching
///   every existing site in this app.
///
/// Deliberately a plain function, NOT a property wrapper: the `@State` confirm flag must stay owned by
/// the View (09.3-RESEARCH.md "Alternatives", lines 138-141).
func guardedToggle(
    get: @escaping () -> Bool,
    set: @escaping (Bool) -> Void,
    skipConfirmIf: @escaping () -> Bool = { false },
    requestConfirm: @escaping () -> Void
) -> Binding<Bool> {
    Binding(get: get, set: { on in
        if on {
            if skipConfirmIf() { set(true) } else { requestConfirm() }
        } else {
            set(false)
        }
    })
}
