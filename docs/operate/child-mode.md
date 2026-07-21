# Child (locked) mode

Child mode is a **PIN-protected lock** for putting faBolus on a child's device: you decide what the
child can do, and a PIN is required to change those choices or turn the mode off. It's found under
**Settings → Child mode**.

## Turning it on

1. Go to **Settings → Child mode → Turn on child mode**.
2. Set a PIN (4–6 digits) the child doesn't know.
3. Choose what stays allowed (see below).

When it's on, blocked actions simply no-op with a short note on whichever device tried them.

## What you can allow or block

| Action | Default when locked |
| --- | --- |
| **Deliver boluses** (phone, watch, Garmin, widget) | Blocked |
| **Advanced pump control** (suspend/resume, temp basal, modes, profiles, cartridge, CGM session) | Blocked |
| **Change settings** (sources, credentials, pairing, and child mode itself) | Blocked |
| **Cancel a running bolus** | Allowed (it only stops insulin) |
| **Clear / snooze alerts** | Allowed |

The default posture is **block anything that gives insulin, allow the safe things** — then re-enable
specific items if you want (tap *Unlock to edit* and enter the PIN).

!!! info "It covers every device"
    Enforcement lives in the phone app, which owns the pump link — so a blocked bolus can't be driven
    from the watch, Garmin, or a widget either. If **Change settings** is blocked, the whole Settings
    tab is hidden behind the PIN so the child can't change CGM sources, re-pair, or turn the lock off.

## Turning it off

**Settings → Child mode → Turn off** and enter the PIN. This also clears the stored PIN.

!!! warning "Not a medical safety device"
    Child mode reduces accidental actions on a shared device; it is not a substitute for supervision.
    faBolus remains experimental and not FDA-cleared.
