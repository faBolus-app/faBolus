# Backup & restore

Save your faBolus configuration to a file in **your own iCloud/Files — never our servers** — and
restore it on a new phone. You can back up **app settings**, **pump settings**, or **both**, and there's
an optional path to **reconfigure a new pump** to match your old one.

Find it under **Settings → Backup & restore**.

## Back up

Pick what to include, then **Create backup…** and save the `.json` file wherever you like (choose
**iCloud Drive** in the save sheet to keep it in your personal iCloud):

- **App settings** — your preferences: bolus/entry defaults + increments, display & chart options,
  CGM-failover config (source, usernames, region, URL), alert rules, remotes/watch/Garmin options,
  read-only mode, child-mode allow-list, etc. (Not your CGM passwords or pump PIN — see below.)
- **Pump settings** — your pump's therapy settings: profiles (basal, carb ratio, ISF, target, insulin
  duration per time segment), max bolus, and Control-IQ. Needs a **connected pump**. Readable on both
  **t:slim X2** and **Mobi**.
- **Include credentials & pairing** *(off by default)* — adds your CGM logins and the saved pump PIN to
  the file so a restore is complete without re-entering them. **Only turn this on if you need it, and
  then treat the file as sensitive** (it contains secrets).

## Restore

**Restore from a file…**, pick the backup, and choose which sections to bring back:

- **App settings / credentials** apply immediately (some changes may need reopening the app).
- **Pump settings** open a review screen showing every value.

### Reconfigure a new pump

From the pump-settings review you can push the settings onto the connected pump — **Mobi only**:

- **Tandem Mobi** (with **Advanced control** on): after a confirmation, faBolus **creates** the profiles
  and sets Control-IQ + max bolus.
- **t:slim X2**: the pump can't be reconfigured over Bluetooth (Tandem's protocol only allows those
  writes on Mobi), so the screen **shows the values for you to re-enter on the pump manually**.

!!! danger "Verify against your prescription"
    Reconfiguring a pump writes **therapy-defining** settings and is **experimental and not FDA-cleared**.
    Nothing is written without your explicit confirmation. **Check every value against your prescription
    and your clinician** before and after applying.

## Automatic iCloud sync (optional, advanced)

By default backup/restore is **file-based** — it works on a free Apple account and needs no special
setup. If you build faBolus on the **paid** Apple Developer Program, you can also enable transparent
**iCloud sync of your app settings** across your devices: uncomment the
`com.apple.developer.ubiquity-kvstore-identifier` entitlement in `project.yml` and add `ICLOUD_SYNC` to
the build's Swift compilation conditions. (Pump settings and secrets are never auto-synced — file only.)

> faBolus has no servers. A backup lives only where you put it; automatic sync uses **your** private
> iCloud.
