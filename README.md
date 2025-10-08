# Bitcoin App Reproducibility Verification Scripts

Tooling used by [WalletScrutiny.com](https://walletscrutiny.com) to examine whether released wallet binaries can be rebuilt bit-for-bit from public source code.

## What Are Reproducible Builds?

A build is *reproducible* when independent parties can compile the same source revision and obtain identical binaries. Reproducibility matters because it allows end users to verify that the binaries they install match the audited source, reducing the risk of supply-chain attacks or unreviewed changes.

## About WalletScrutiny

WalletScrutiny documents the security posture of Bitcoin and Lightning wallets. Part of that review involves checking reproducibility claims—if a wallet project publishes source code, WalletScrutiny attempts to rebuild it and compare the resulting artifacts against what is distributed on app stores or vendor websites. These scripts encapsulate repeatable workflows for that verification.

## Repository Layout

- `test/android/` – Android-focused helper scripts that plug into the WalletScrutiny `test.sh` harness.
- `test/desktop/` – Standalone desktop verification scripts.
- `test/hardware/` – Firmware verification helpers for hardware wallets.
- `LICENSE` – MIT license covering this repository.

## Script Catalogue

| Path | Target | Purpose |
| --- | --- | --- |
| `test/android/io.horizontalsystems.bankwallet.sh` | Unstoppable Wallet (Android) | Defines repo metadata and a containerized Gradle build function that the WalletScrutiny harness calls when verifying Play Store APKs. |
| `test/desktop/verify_electrumdesktop.sh` | Electrum Desktop | End-to-end reproducibility script: downloads official release artifacts, runs Electrum’s Docker-based build, compares outputs, and reports differences. |
| `test/hardware/bitBox2.sh` | BitBox02 firmware (btc or multi editions) | Automates downloading vendor firmware, rebuilding inside the upstream container image, stripping signatures, and comparing hashes. |

## Using the Scripts

### Common Prerequisites

- Linux host with Bash, `git`, and `wget`.
- Container runtime (`podman` preferred; `docker` accepted).
- Adequate disk space (several gigabytes per build) and RAM (12 GB recommended for Android/desktop builds).

### Hardware Firmware (BitBox02)

```bash
cd bitcoinAppReproducibilityVerificationScripts/test/hardware
./bitBox2.sh 9.23.2 btc
```

The script creates `~/wsTest`, downloads the signed firmware, builds the matching edition inside the upstream container, strips the vendor signature header, and prints hashes for comparison. Remove `~/wsTest` afterwards if you no longer need the artifacts.

### Desktop Wallets (Electrum)

```bash
cd bitcoinAppReproducibilityVerificationScripts/test/desktop
./verify_electrumdesktop.sh 4.6.2
```

Review the disclaimers printed at startup, then follow the prompts. The script downloads reference binaries, builds the target release using Electrum’s Docker workflow, and writes comparison results under `output/`.

### Android Wallets (Harness-Driven)

`test/android/io.horizontalsystems.bankwallet.sh` is sourced by WalletScrutiny’s broader `test.sh` framework. The harness clones the app repository, sets the desired tag, and calls the script’s `test()` function to perform the containerized Gradle build. Use it via the upstream harness rather than running it directly.

## Contributing

1. Ensure new scripts expose clear usage information (flags, required tools, expected outputs).
2. Prefer containerized builds to avoid leaking host dependencies.
3. Document any non-reproducible differences and the rationale for accepting them.
4. Submit changes under the MIT license (see `LICENSE`).

For background on WalletScrutiny’s verification process, visit the site or reach out at [contact@walletscrutiny.com](mailto:contact@walletscrutiny.com).
