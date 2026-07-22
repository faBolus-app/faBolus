# iPhone remote (control another phone)

Use one iPhone to view and control the pump connected to **another** iPhone — for example, a parent's
phone controlling a child's pump. The child's phone is the **host** (it owns the pump's Bluetooth
link); the parent's phone is the **remote**. Like the Mac remote, the remote never touches the pump —
it relays confirmed commands to the host over an encrypted Bluetooth link.

!!! warning "Proximity only — this is not internet-distance control"
    The link is **Bluetooth LE (local, no cloud)**, so the two phones must be within Bluetooth range
    (roughly the same home). It keeps working when the **host phone is locked or backgrounded**, but it
    is **not** remote-across-town control — that would require a cloud relay, which faBolus does not do.

## Set up

**On the host (child's) phone**

1. **Settings → Remotes & devices → Remote access → “Allow remote devices”** (off by default).
2. **Remotes → Pair a remote → Pair with QR code** (recommended) — or a typed 6-digit code.
3. Choose what this remote may do (see [permissions](#security-permissions)).

**On the remote (parent's) phone**

1. **Settings → Remotes & devices → Control another phone.** This switches the whole app into
   **Remote mode** (see below).
2. **Scan the host's QR code** (or pick the host under *Nearby hosts* and type the code). Pairing is
   **by the code** — the remote connects to any nearby faBolus host, so it works even when the host
   phone is **locked or backgrounded**. The device list prunes devices that are no longer nearby, and
   a backgrounded host shows a readable **“faBolus device (xxxx)”** label instead of a raw UUID.
3. Once paired, you'll see the host's status and — if the host granted it — can bolus, cancel, and
   clear alerts. Pairing is remembered; it reconnects automatically.

## Remote mode (app-wide) & switching

"Control another phone" puts the **whole app** into **Remote mode**: the app operates against the
paired host's pump and looks like a host (a Remote dashboard + Settings), rather than being a screen
buried in Settings. The remote connection stays alive as you move around the app.

Switch between controlling **this phone's own pump** and the **remote** host anytime under
**Settings → Controlling** — the choice is remembered across launches, so a phone used purely as a
remote reopens straight into Remote mode. (A phone can do both: use its own pump *and* act as a remote,
switching between them.)

## What the remote can do

A mirror of the host dashboard: glucose ring + trend, chart, pills, optional statistics, alerts, and a
**bolus** screen (standard **and** extended/combo) that you confirm on the remote. Every action is
limited to what the host granted, and every bolus still runs through the host's validated signed path
(max-bolus clamp + interlocks) — the remote only *requests*.

## Security & permissions {#security-permissions}

- **Authenticated pairing** (`MacPairing`): a one-time code (QR = 128-bit, or a typed 6-digit) drives a
  mutual HMAC handshake; the host refuses everything until authenticated, then a 256-bit token secures
  reconnects.
- **End-to-end encrypted channel** (`SealedTransport`, AES-GCM with replay protection) — the whole
  stream is encrypted, not just the handshake. This applies to every Bluetooth remote (Mac + phone).
- **Opt-in, off by default.** While *Allow remote devices* is off, the phone advertises nothing (no
  added attack surface or battery cost). Turning it on makes the phone advertise a connectable
  Bluetooth service — a small added attack surface, which is why it's opt-in with a warning. Your
  **Apple Watch and Garmin are unaffected** (they're bound to your own paired device, not discoverable
  by others — no gate needed).
- **Per-remote permissions.** A new remote starts **view-only**; the host grants each of *bolus*,
  *extended bolus*, *cancel*, *dismiss alerts*, *suspend/resume* individually, per remote.
- **Per-remote bolus mode.** Each remote is either *auto-execute* (the parent confirms on their phone;
  the host runs it) or *host approval* (the host phone must approve on-device first).
- **Read-only switch.** A single host toggle blocks all insulin-affecting writes over Bluetooth
  (bolus/extended/suspend-resume) while still allowing status, cancel, and alert-dismiss.
- **Overrides child lock.** An authorized parent remote is governed only by its granted permissions —
  so you can disable the child's *local* bolus with [child mode](../operate/child-mode.md) yet still
  bolus from the parent phone.

## Reverse approval (optional)

The host can require that a bolus **started on its own phone** be approved by a paired remote first:
**Settings → Remote access → “Require a remote to approve my boluses.”** Off by default. When on, a
host bolus waits for the parent to approve or deny; if no paired remote responds within ~60 s it is
**aborted** (safe default). This is oversight for a child bolusing on their own phone.

## Limits

- Bluetooth range (~10 m); the remote (parent) phone is foreground when controlling, the host (child)
  phone may be locked/backgrounded.
- **Chained remotes** — driving the child host from the parent's *own* Apple Watch / Mac (relayed
  through the parent phone) is designed but **not yet enabled**; see the note in the source/roadmap.
  (The parent watch's glucose *complication* already reflects the child while the parent phone is on
  the remote screen.)
