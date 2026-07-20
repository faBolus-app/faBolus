# 5 · Add a Garmin (optional)

The Garmin remote is **optional**. It's a small app for the **Garmin venu3s** that asks your
iPhone to bolus — the phone still owns the pump and confirms everything. It also shows glucose on
your watch face and a history plot. (See [Garmin remote](../remotes/garmin.md) for how it's used.)

!!! note "What is Connect IQ?"
    **Connect IQ** is Garmin's system for third-party watch apps (like the App Store, but for
    Garmin). Building a Connect IQ app uses different (free) tools than the iPhone app. We'll do it
    all inside **Visual Studio Code**, a free editor, using buttons — not commands.

!!! note "The Garmin app lives in its own project"
    It's in the separate **[faBolusGarmin](https://github.com/zgranowitz/faBolusGarmin)** repo. The
    iPhone side is already in the app you built in [Step 3](build-app.md), so here you just build
    the watch app and pair it.

<div class="cx2-shots" markdown>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin glance](../assets/screenshots/garmin-glance.svg)
  <figcaption>Glance</figcaption>
</figure>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin history](../assets/screenshots/garmin-history.svg)
  <figcaption>History plot</figcaption>
</figure>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin confirm](../assets/screenshots/garmin-confirm.svg)
  <figcaption>Tap 1-2-3 to confirm</figcaption>
</figure>
</div>

## What you'll need

- The **iPhone app already built** ([Step 3](build-app.md)) — the Garmin can't do anything on its
  own.
- **Visual Studio Code** (free) with Garmin's **Monkey C** extension (installs the tools for you).
- The **Garmin Connect** app on your iPhone, with your **venu3s** already paired to it.

## Step 1 — Download the Garmin app

In **GitHub Desktop** (the same app from [Step 3](build-app.md#download)): **File → Clone
Repository → URL**, paste the address below, and save it next to your other projects:

```
https://github.com/zgranowitz/faBolusGarmin
```

## Step 2 — Install the Garmin tools (in VS Code)

<ol class="cx2-steps">
<li>Download and open <a href="https://code.visualstudio.com/">Visual Studio Code</a> (free).</li>
<li>Click the <strong>Extensions</strong> icon in the left bar (four squares), search <strong>Monkey C</strong>, and click <strong>Install</strong> (it's by Garmin).</li>
<li>Press <kbd>⌘</kbd> + <kbd>⇧</kbd> + <kbd>P</kbd> to open the command box, type <strong>Verify Installation</strong>, and pick <strong>Monkey C: Verify Installation</strong>. It walks you through downloading the Garmin <strong>SDK</strong> and the <strong>venu3s</strong> device files — just say yes to the prompts.</li>
</ol>

## Step 3 — Make a developer key (one click)

Garmin apps must be "signed" with a key, like the iPhone app. In VS Code, press
<kbd>⌘</kbd> + <kbd>⇧</kbd> + <kbd>P</kbd>, type **Generate**, and choose **Monkey C: Generate a
Developer Key**. VS Code makes it and remembers it. That's all.

??? note "Advanced: make the key in the Terminal instead (optional)"
    ```sh
    openssl genrsa -out ~/Documents/faBolus/developer_key.pem 4096
    openssl pkcs8 -topk8 -inform PEM -outform DER \
      -in ~/Documents/faBolus/developer_key.pem \
      -out ~/Documents/faBolus/developer_key.der -nocrypt
    ```

## Step 4 — Build and preview it

<figure class="cx2-shot wide" markdown="span">
  ![Connect IQ simulator](../assets/screenshots/garmin-sim.svg)
  <figcaption>The Connect IQ simulator shows the app on a virtual venu3s</figcaption>
</figure>

<ol class="cx2-steps">
<li>In VS Code, open the <strong>faBolusGarmin</strong> folder (<strong>File → Open Folder…</strong>).</li>
<li>Press <kbd>⌘</kbd> + <kbd>⇧</kbd> + <kbd>P</kbd>, type <strong>Run</strong>, and choose <strong>Monkey C: Run</strong>.</li>
<li>When it asks for a device, pick <strong>venu3s</strong>. The <strong>Connect IQ simulator</strong> opens with the app running.</li>
</ol>

The simulator can't reach your iPhone or pump, so bolus screens show the "phone unreachable" path
there — that's expected. It's just for checking the screens look right.

??? note "Advanced: build from the Terminal (optional)"
    ```sh
    cd ~/Documents/faBolus/faBolusGarmin
    SDK=~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/<sdk-version>
    "$SDK/bin/monkeyc" -f monkey.jungle -o bin/faBolus.iq -y ~/Documents/faBolus/developer_key.der -e -r -w
    ```
    Check the faBolusGarmin README for the exact device/flags.

## Step 5 — Put it on your watch

Connect your venu3s to the computer with its cable and copy the built app onto it, **or** upload
it to the Connect IQ store as a private beta and install it from **Garmin Connect** on your phone.
The faBolusGarmin README has the exact, current steps for the venu3s.

## Step 6 — Pair the remote to your iPhone

<ol class="cx2-steps">
<li>Make sure <strong>Garmin Connect</strong> is installed on your iPhone and your venu3s is paired to it.</li>
<li>Open the <strong>faBolus</strong> iPhone app, tap the <strong>watch icon</strong> (top-right) → <strong>Set up Garmin remote</strong>. Garmin Connect opens so you can pick your venu3s.</li>
<li>Come back to faBolus — it remembers your watch and shows "Garmin remote: &lt;your watch&gt; ✓".</li>
</ol>

<div class="cx2-check" markdown>
**Success looks like:** the faBolus app on your venu3s shows your glucose, and the iPhone app
lists your watch as the Garmin remote. Learn the screens on the
[Garmin remote](../remotes/garmin.md) page.
</div>
