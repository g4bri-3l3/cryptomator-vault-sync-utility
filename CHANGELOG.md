# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [1.0.0] - 2026-07-26

First public release.

### Added

- **Sync** a local Cryptomator vault (or any local folder) to a remote over
  **SFTP** or **WebDAV**, using `rclone copy` (never deletes remote files).
- **Download / restore** from remote to local, with an explicit warning that
  differing local files may be overwritten.
- **Integrity check** between local and remote (`rclone check`), ignoring
  WebDAV `.DAV` session artifacts.
- **USB backup** of the local vault to a removable drive, with a check that the
  drive is connected.
- **Protocol selection** (SFTP or WebDAV) in setup, with only the relevant
  fields shown for the chosen protocol.
- SFTP authentication via **SSH key** (with passphrase support) **or**
  username/password.
- **Host key verification** for SFTP via `known_hosts` (MITM protection).
- Built-in **ed25519 SSH key generation** button.
- Automatic **rclone download** on first run, gated behind an explicit
  confirmation dialog that shows the download URL and the server's TLS
  certificate (subject, issuer, validity, SHA1 fingerprint).
- **Vault-aware safety**: when the target is a Cryptomator vault, sync /
  download / USB backup are blocked while the vault is unlocked, and a live
  status label shows LOCKED / UNLOCKED.
- **Bandwidth limit** (Mbit/s) for uploads.
- Long operations run in a **separate console window** with live output and a
  "press a key to return" pause.
- **Localized UI** with runtime language switching: English (default), Italian,
  German, French. Languages are auto-discovered from the `lang/` folder.
- Config path and log path shown in the main window as **clickable links**.
- **In-place reconfiguration**: saving new settings reloads everything without
  restarting the program.
- Configuration stored locally under `%APPDATA%\CloudVaultSync\config.json`;
  never bundled with the code.

### Security

- SSH private keys are never copied or embedded; only referenced by path.
- SSH key passphrases and SFTP/WebDAV passwords are stored obscured via
  `rclone obscure` (note: obscuring is reversible, not encryption).

[Unreleased]: https://github.com/<YOUR_USER>/cloud-vault-sync/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/<YOUR_USER>/cloud-vault-sync/releases/tag/v1.0.0
