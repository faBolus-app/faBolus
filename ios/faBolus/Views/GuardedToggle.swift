import SwiftUI

/// The one guarded-boolean-toggle contract for the settings surface. Generalized from
/// `AlertRulesView`'s `suppressBinding` intercept: `get`/`set` name the real backing property;
/// `skipConfirmIf` lets an already-acknowledged flag bypass the dialog; `requestConfirm` flips
/// whatever `@State` flag drives the caller's `confirmationDialog`.
///
/// Contract:
/// - Reading the binding always returns the real backing value (`get()`) — never a staged value.
/// - Enabling (`true`) when `skipConfirmIf()` is false calls `requestConfirm()` only — `set` is NOT
///   called, so Cancel's snap-back is free: because the backing was never written, a re-read of `get()`
///   still returns false.
/// - Enabling when `skipConfirmIf()` is true calls `set(true)` immediately and never touches
///   `requestConfirm`.
/// - Disabling (`false`) always calls `set(false)` immediately — turning OFF is never confirmed,
///   matching every existing site in this app.
///
/// Deliberately a plain function, not a property wrapper: the `@State` confirm flag must stay owned
/// by the View.
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
