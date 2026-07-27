# Cryptomator Vault Sync Utility
A small Windows GUI tool (PowerShell) to sync a **[Cryptomator](https://cryptomator.org/)**
vault to any cloud storage exposed via **SFTP** or **WebDAV**, using
**[rclone](https://rclone.org/)** under the hood.

Your files stay **encrypted on your own machine** with Cryptomator (AES-256)
*before* they ever leave it. The cloud only ever sees ciphertext. This tool
just moves that ciphertext around — up to the cloud, back down for a restore,
or onto a USB drive for a local backup — from a simple interface, without you
having to remember rclone commands.

> Works with a storage box, a VPS, a NAS, Nextcloud / ownCloud, or any other
> SFTP/WebDAV-compatible provider. Nothing in the code is tied to a specific
> vendor.

---

## Why encrypt your data before the cloud?

When you upload data to a typical consumer cloud (Google Drive, OneDrive,
iCloud, Dropbox...), they are stored in a form the provider can read. The
transfer is encrypted in transit, and the provider encrypts data at rest — but
**the provider holds the keys**. That means the files can be scanned, indexed,
handed over on legal request, or exposed in a breach.

Cryptomator flips this around with **client-side, end-to-end encryption**:

- Each file is encrypted **on your device** with AES-256 before upload.
- File **contents and file names** are both encrypted.
- Only you hold the passphrase — the cloud stores unreadable blobs.
- It's **free and open source**, audited, and cross-platform (Windows, macOS,
  Linux, Android, iOS).

This tool is built around that model: Cryptomator does the encryption, and
Vault Sync handles moving the encrypted vault to and from your storage.

---

## Features

- **SFTP or WebDAV** transport, selectable in setup (only the relevant fields
  are shown for the protocol you pick).
- **SFTP** auth via **SSH key** (with passphrase support) **or** username/password.
- **Host key verification** for SFTP (`known_hosts`) to protect against MITM.
- **SSH Keys** generation embedded
- Automatic **rclone download** on first run, with an explicit confirmation
  dialog showing the download URL and the server's TLS certificate.
- **Sync** (local -> remote), never deletes anything remote (`rclone copy`).
- **Download / restore** (remote -> local), with an explicit overwrite warning.
- **Integrity check** (hash-based where the server supports it), ignoring
  WebDAV `.DAV` session artifacts.
- Optional **USB backup** (local -> USB) to complete the **3-2-1 backup rule**.
- **Vault-aware safety**: when the target is a Cryptomator vault, the tool
  refuses to sync/backup while the vault is unlocked/mounted, so it never reads
  half-written ciphertext.
- **Bandwidth limit** (Mbit/s) so a big upload doesn't saturate your line.
- Live output in a **separate console window** for long operations, with a
  "press a key to return" pause so you can read the final summary.
- **Localized UI** (English default, Italian, German and French included) via JSON files.
- **No manual restart on config change**: reconfiguring reloads everything in place.

---

## Backup best practice

A widely used guideline: keep **3** copies of your data, on **2** different
media, with **1** copy off-site. With this tool a typical setup is:

- Copy 1 — the vault on your computer's **internal drive**
- Copy 2 — the vault on a **separate physical device** (USB drive) — the
  "Backup to USB" button
- Copy 3 — the vault in the **cloud** (off-site, different infrastructure) — the
  "Sync" button

Three copies, on independent devices, with one off-site — the goal of 3-2-1
being that no single failure or event can take out all copies at once.

Because the vault is encrypted client-side, the USB drive and the cloud copy
are both unreadable without your passphrase — so neither a lost USB stick nor a
cloud breach exposes your data.

---

## Requirements

- Windows 10/11 with **PowerShell 5.1+** (included by default).
- Windows **OpenSSH client** (for `ssh-keygen`, only needed for SFTP key auth) —
  included by default from Windows 10 onward.
- A storage endpoint reachable via **SFTP** (over SSH, port 22 or custom) or **WebDAV**
  (HTTPS URL).
- **Cryptomator** for managing the vault (not required by the script itself,
  but it's the intended use case).
- `rclone` is **not** required up front — the tool offers to download it on first
  run.

---

## Project layout

```
CloudVaultSync.ps1     # the script — run this
lang/
  en.json              # English (default)
  it.json              # Italian
  de.json              # German
  fr.json              # French
```

Keep `CloudVaultSync.ps1` and the `lang/` folder together — the script reads
its UI strings from `lang/`.

---

## Getting started

1. Download the latest release (or clone the repo) and keep `CloudVaultSync.ps1`
   and the `lang/` folder together.
2. Run the script (see the Execution Policy note below).
3. On first launch, a setup form appears. Pick a language, choose the protocol
   (SFTP or WebDAV), fill in the relevant fields, then set the local vault
   path, the drive letter Cryptomator uses when unlocked, the remote
   destination folder, and an optional bandwidth limit.
4. For **SFTP with a key**: generate one with the built-in button if you don't
   have it, then upload the resulting `.pub` file to your provider (control
   panel, or via SFTP into `.ssh/authorized_keys`). If the key has a
   passphrase, enter it in the dedicated field.
5. For **WebDAV**: enter the full URL, username, and password (an app-password
   is preferable if your provider supports one).
6. Use **Test connection** before syncing anything.

### Running the script (Execution Policy)

Windows blocks unsigned scripts by default. The simplest way to run it without
changing any system-wide setting:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\CloudVaultSync.ps1"
```

**Is `-ExecutionPolicy Bypass` a security risk?** No. PowerShell's Execution
Policy is [explicitly not a security boundary](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies)
— Microsoft describes it as a guardrail against *accidental* execution, not a
defense against malicious code (it can be bypassed trivially in many ways). The
`Bypass` flag applies **only to that single invocation**: it disables nothing
permanently and lowers no protection for any other process. The real safeguard
is whether you trust the script's contents — and since this is open source, you
can read every line first.

If you prefer alternatives:

- **One-time, per-user policy** (allows local unsigned scripts, still requires a
  signature for scripts downloaded from the internet):
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
  ```
  then run the script directly.
- **Sign the script** with a code-signing certificate (even self-signed) — the
  most robust option for a public release, as it also lets others verify the
  script hasn't been tampered with.

You can make a Desktop shortcut with the `Bypass` command as the **Target** for
a double-click launch. Add `-NoExit` while troubleshooting if you want the
window to stay open.

---

## Typical workflow

1. Add/import your data into the **unlocked** Cryptomator vault as usual.
2. **Lock** the vault in Cryptomator (this flushes all writes to the encrypted
   files on disk).
3. Open Vault Sync utility — the status line turns green ("Vault: LOCKED").
4. Click **Sync local vault to remote**. A console window shows live progress.
5. Optionally click **Backup to USB** for the local copy.
6. Run **Verify integrity** now and then, or after a big transfer.

For a restore on a new machine, use **Download remote to local** (read the
overwrite warning first), then open the downloaded vault in Cryptomator.

---

## Where configuration is stored

All configuration (host/URL, username, paths, key reference, language) is saved
to:

```
%APPDATA%\CloudVaultSync\config.json
```

The main window shows this path and lets you open the folder with a click.
**This file is never part of the repository** and should not be published — it
holds setup-specific data. The included `.gitignore` excludes it.

`rclone` is downloaded (if you accept) into
`%APPDATA%\CloudVaultSync\rclone\`.

---

## Localization

UI strings live in `lang/` — `en.json` (default), `it.json`, `de.json`, and
`fr.json`. The setup form lets you pick the language, applied without restarting
the program. To add another language, copy `en.json`, translate the values
(keep the keys and any `{0}`/`{1}` placeholders unchanged), and save it as
`lang/<code>.json` — it appears automatically in the dropdown.

---

## Security notes

- The **SSH private key is never copied or embedded** in the tool — it stays
  where you generated it, protected by its passphrase.
- **Always set a passphrase** on your SSH key. The key passphrase and any
  WebDAV/SFTP password are stored *obscured* in rclone's config — note that
  rclone "obscure" is **reversible**, not real encryption. Treat
  `%APPDATA%\CloudVaultSync` as sensitive: it's protected only by your Windows
  user profile. On a shared or non-encrypted machine, consider full-disk
  encryption (BitLocker).
- **Verify the host key** of your SFTP endpoint before first use, against the
  fingerprint published by your provider. The `known_hosts` field exists for
  exactly this.
- The tool **never** handles unlocking/locking the vault — the vault passphrase
  is always a manual step, never stored or automated.
- `Sync` and `Backup` use `rclone copy` and **never delete** remote/USB files,
  even if you remove them locally. `Download` **can overwrite** local files
  that differ — it warns you first.

---

## Known limitations

- Hash-based verification depends on the server exposing a comparable hash over
  SFTP. When it doesn't (some password/port-22 setups), rclone falls back to a
  **size comparison** — still valid for catching missing or truncated files,
  just not a full content hash. Key-based access on providers that expose
  hashes gives you the stronger check.
- Designed for **single-user, personal use**, not multi-user or server
  scenarios.

---

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Built on the excellent work of the [Cryptomator](https://cryptomator.org/) and
[rclone](https://rclone.org/) projects. This tool is an independent helper and
is not affiliated with either.
