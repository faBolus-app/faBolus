# Pair your pump

faBolus pairs with your t:slim X2 once, using a code the pump shows. After that it reconnects on its own.

!!! warning "One controller at a time"
    The pump pairs with one app at a time. Unpair the official t:connect app before you pair faBolus.
    Each switch between the two needs a new code from the pump.

## Pair

<ol class="cx2-steps">
<li>Keep the pump next to the phone.</li>
<li>On the pump, go to <strong>Options → Device Settings → Bluetooth Settings</strong>. Turn <strong>Mobile Connection</strong> on if it's off, then tap <strong>Pair Device</strong>. The pump shows a pairing code.</li>
<li>In faBolus, tap <strong>Connect a pump</strong> (on the first screen, the dashboard, or <strong>Settings → Pump</strong>). faBolus looks for pumps in pairing mode, and yours appears in the list. Select it if it isn't already.</li>
<li>Type the code and tap <strong>Pair</strong>.</li>
</ol>

The code is one of two kinds, and faBolus handles both:

- **6 digits** on most pumps;
- **16 letters and numbers** on older firmware (before v7.7). Type it exactly as shown; it's
  case-sensitive.

<div class="cx2-check" markdown>
**Success looks like:** the sheet closes, **Settings → Pump** shows **Connected**, and the dashboard
fills in with glucose, active insulin, reservoir and battery within a few seconds.
</div>

If the pump doesn't show up, the sheet offers **Search again** after a while. A Mobi is listed but can't
be chosen: faBolus doesn't connect to a Mobi yet.

## After pairing

- The pairing stays on the phone. faBolus reconnects by itself when the pump comes back in range, also in
  the background, and after you install a new build.
- **Settings → Pump** shows the pump's model, name, status and API version, and why the link last
  dropped.
- **Pair a different pump or new code** pairs again. If you cancel, the pump you had reconnects.
- **Forget this pump** disconnects and removes the pairing and the logbook. To use the pump again you
  pair with a new code.

## Pump history

faBolus reads the pump's history every 15 minutes and keeps it on the phone, in the
[logbook](../operate/logbook.md). **Settings → Pump → Sync history now** reads it at once.

## faBolus and t:connect

faBolus doesn't do everything the official app does; for example, it doesn't upload your pump's data to
Tandem's t:connect web app. To use t:connect for a while, pair it, then pair faBolus again with a new
code.

!!! tip "Nothing connects?"
    Check that the pump is in pairing mode, that faBolus may use Bluetooth (iPhone **Settings → faBolus**),
    and that t:connect isn't connected to the pump. More in [Troubleshooting](../troubleshoot.md).
