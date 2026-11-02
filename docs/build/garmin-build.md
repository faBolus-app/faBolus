# 4 · Garmin watch (optional)

The watch app runs on a **Garmin Venu 3S**. It shows your glucose and pump status and can ask the phone
for a bolus. The phone checks every request and is the only thing that talks to the pump. How to use it
is on the [Garmin watch](../remotes/garmin.md) page.

## What you'll need

- The phone app **built with Garmin's SDK**: [Step 3, Garmin's SDK](build-app.md#garmin-sdk). If
  **Settings → Watch** in the app says Garmin isn't included, add the SDK, make the project again and
  run it on the phone.
- The **Garmin Connect** app on the iPhone, with your Venu 3S paired to it.
- A free **Garmin account**, to download Garmin's developer tools.
- The watch's USB cable.

There are two ways to get the app onto the watch. **Copying it over USB** needs nothing more than the
cable. **A private beta in the Connect IQ Store** installs and updates over the air, but needs a Garmin
developer account and an upload each time. Both build from the same code.

## Step 1: Download the watch app's code

In **GitHub Desktop**, choose **File → Clone Repository… → URL** and paste
`https://github.com/faBolus-app/faBolusGarmin`. Choose the **Developer/faBolus** folder as before, so the
Local Path ends in `Developer/faBolus/faBolusGarmin`, and click **Clone**.

## Step 2: Install Garmin's Connect IQ SDK

<ol class="cx2-steps">
<li>Go to <a href="https://developer.garmin.com/connect-iq/sdk/">developer.garmin.com/connect-iq/sdk</a>, download the <strong>SDK Manager</strong> for Mac, and open it.</li>
<li>Sign in with your Garmin account and accept the license.</li>
<li>On the <strong>SDK</strong> tab, download the newest SDK. The watch app is built and tested with <strong>9.2.0</strong>.</li>
<li>On the <strong>Devices</strong> tab, download <strong>Venu 3S</strong>.</li>
</ol>

## Step 3: Install Java

Garmin's compiler is a Java program, and a new Mac has no Java. In Terminal:

```sh
brew install --cask temurin
```

It asks for your Mac password.

<div class="cx2-check" markdown>
**Success looks like:** `java -version` prints a version.
</div>

## Step 4: Make a developer key

Garmin apps are signed with a key you make once. In Terminal:

```sh
cd ~/Developer/faBolus
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
```

This makes `developer_key.der` in **Developer → faBolus**. Keep it: an update to the watch app must be
signed with the same key.

## Step 5: Build the watch app

```sh
cd ~/Developer/faBolus/faBolusGarmin
./scripts/stamp-revision.sh
SDK="$(ls -d "$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/"connectiq-sdk-* | sort -V | tail -1)"
"$SDK/bin/monkeyc" -f monkey.jungle -d venu3s -y ../developer_key.der -o bin/faBolus.prg
```

The first line moves to the watch app's folder. The second records which version of the code you're
building; the watch shows it in its Details screen, and the build fails without it. The third finds the
SDK you installed, and the fourth builds.

<div class="cx2-check" markdown>
**Success looks like:** `BUILD SUCCESSFUL`, and a file **faBolus.prg** in **faBolusGarmin → bin**.
</div>

??? note "Optional: try it in the simulator first"
    Start the simulator, and wait until its window opens:

    ```sh
    "$SDK/bin/connectiq" &
    ```

    Then load the app into it:

    ```sh
    "$SDK/bin/monkeydo" bin/faBolus.prg venu3s
    ```

    The app runs on a virtual Venu 3S. It can't reach your phone, so it shows that
    the phone is unreachable. That's expected.

## Step 6a: Copy it to the watch over USB

<ol class="cx2-steps">
<li>Connect the watch to the Mac with its cable.</li>
<li>The Venu 3S doesn't appear in Finder. Install a free file-transfer app for Android-style devices, such as <a href="https://openmtp.ganeshrvel.com/">OpenMTP</a>, and open it.</li>
<li>On the watch's side, open the <strong>GARMIN</strong> folder, then <strong>APPS</strong>.</li>
<li>Copy <strong>faBolus.prg</strong> from <strong>Developer → faBolus → faBolusGarmin → bin</strong> into <strong>APPS</strong>.</li>
<li>Disconnect the watch. The app appears in its app list as <strong>faBolus</strong>.</li>
</ol>

To update the watch app later, build again and copy the new **faBolus.prg** over the old one.

## Step 6b: Or publish a private beta

Instead of copying over USB, you can upload the app to the Connect IQ Store as a beta that only your
Garmin account sees. The store needs a unique app ID for every beta, so a script makes one for you, builds
the file to upload, and points your phone app at that ID:

Quit Xcode first, because the script makes the phone app's project again. Then:

```sh
cd ~/Developer/faBolus/faBolusGarmin
SDK="$(ls -d "$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/"connectiq-sdk-* | sort -V | tail -1)"
MONKEYC="$SDK/bin/monkeyc" KEY=../developer_key.der ./scripts/beta-build.sh
```

Then:

<ol class="cx2-steps">
<li>The script wrote your app ID into the phone app's <code>LocalConfig.xcconfig</code> and printed <strong>Regenerated the iPhone Xcode project</strong>. If that line is missing, or you use <code>FABOLUS_TIME_SENSITIVE=1</code>, make the project yourself (<code>cd ../faBolus</code>, then the command from Step 4 of the iPhone guide).</li>
<li>Open the project in Xcode and press <strong>▶</strong> to put the updated phone app on your iPhone.</li>
<li>Sign in to the <a href="https://apps.garmin.com/developer/">Connect IQ developer dashboard</a>, create a beta app, and upload <strong>bin/faBolus-beta-personal.iq</strong>, which the script showed in Finder.</li>
<li>Install it on the watch from the <strong>Connect IQ Store</strong> app on the iPhone. A beta shows only to the Garmin account that uploaded it, so sign in to Garmin Connect with that account.</li>
</ol>

The script keeps your app ID in a hidden file, `.beta-app-id`, in the faBolusGarmin folder, and reuses it
every time. Keep that file, and copy it into any new clone of faBolusGarmin: a new ID is a new app, and
the phone would lose the watch. More detail is in faBolusGarmin's
[build guide](https://github.com/faBolus-app/faBolusGarmin/blob/main/docs/BUILDING.md).

## Step 7: Connect the watch to the phone

<ol class="cx2-steps">
<li>In faBolus on the iPhone, open <strong>Settings → Watch</strong>.</li>
<li>Tap <strong>Choose watch in Garmin Connect</strong>. Garmin Connect opens: choose your Venu 3S, and it returns to faBolus.</li>
<li>Open faBolus on the watch. In <strong>Settings → Watch</strong> on the phone, <strong>Link</strong> shows <strong>Connected</strong>.</li>
</ol>

Bolusing from the watch is off until you turn on **Allow bolusing from the watch** on the same screen.
See [Garmin watch](../remotes/garmin.md).

The same screen has **How to install the watch app**, which opens this page.

<div class="cx2-check" markdown>
**Success looks like:** the watch shows your glucose and its age, and **Settings → Watch** on the phone
names your watch.
</div>
