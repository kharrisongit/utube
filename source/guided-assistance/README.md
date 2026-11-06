# Guided Assistance

A native iPhone and Mac document knowledge assistant. Bring your own references, create reusable request guides, capture changes, and ask an optional on-device model for answers with source passages.

**Status: initial release.** The release workflow runs core tests, builds an AltStore IPA, verifies the app in the iPhone simulator, and compiles the Mac target before publishing. Physical-device AI performance and final AltStore installation still require device confirmation.

## What is included

- A dashboard with document counts, pinned request guides, and recent knowledge updates.
- PDF, UTF-8 text, and Markdown imports; local text search; source passages and original PDF viewing.
- Editable request guides with checklists, steps, suggested wording, and related references.
- Quick knowledge updates with draft/confirmed/archived states, effective dates, and revision history.
- Optional Qwen3.5 4B 4-bit inference through MLX Swift, with an explicit approximately 3 GB model download.
- Answers assembled from retrieved sources, with source-number and quotation checks. Unsupported answer sections are withheld. These checks do not prove that an answer's interpretation is correct.
- Optional device-authentication lock and passphrase-encrypted backups for manual transfer between devices.

The app starts empty. No organization documents, real procedures, personal data, or model weights are bundled. The tests use invented equipment-loan examples.

## Install with AltStore Classic

Refresh **kharrison Apps** and choose **Guided Assistance**. The release workflow publishes the IPA before adding its listing. The existing source is `https://raw.githubusercontent.com/kharrisongit/utube/main/source/apps.json`. You can also import `GuidedAssistance.ipa` from its GitHub release using the + button in AltStore. AltStore handles development signing.

The optional AI model is downloaded separately from Settings. The app starts empty; import your own references after installation.

## Build from source

1. On an Apple Silicon Mac, install Xcode 26 or newer with Swift 6.2 or newer. Use Xcode 27 or newer for an iPhone running iOS 27.
2. Open `GuidedAssistance.xcodeproj`. Allow Xcode to resolve the Swift packages.
3. Select **GuidedAssistance-Mac** and **My Mac** to build the desktop app. Deployment minimum: macOS 15.
4. For the phone, select **GuidedAssistance-iOS**, connect the iPhone, and select it as the run destination. Deployment minimum: iOS 18. In Signing & Capabilities, select your development team and give the bundle identifier a unique value if needed.
5. Run the app. Import a searchable document, or save and confirm a knowledge update.
6. In Settings, explicitly choose **Download local AI** when ready. Keep the app open on Wi-Fi until it completes. Then ask a question containing terms from your references.

Once installed and the model is downloaded, the iPhone does not need the Mac running, a server, or Tailscale. The Mac is needed for this Xcode installation workflow. Development signing and distribution remain subject to your Apple account's provisioning rules; this repository is not an App Store or TestFlight release.

## Keep it current

Use **Add an update** to save a new fact with its source and effective date. A draft is searchable but excluded from AI answers. Confirm it after review. Future-dated information becomes eligible on its effective calendar day. Editing a note records its previous version; only the current version is retrieved.

Documents with identical bytes are rejected as duplicates. A changed document is imported as a separate reference, even if its filename is the same. Delete superseded documents after checking the replacement; importing a file does not automatically retire older sources. Conflicting sources require review.

Importing documents creates a search index. It does not train or modify the model's weights.

## Privacy and transfer

The source repository contains the application only. Imported knowledge is written to the app's private Application Support directory at runtime, outside the repository. On iOS it uses complete file protection. On Mac, enable FileVault if you require encrypted storage at rest. The optional authentication screen is an access gate, not a separate database-encryption password.

App knowledge is excluded from automatic device backups. Make a backup explicitly in Settings. Export uses AES-GCM and PBKDF2-HMAC-SHA256 with 400,000 iterations and a fresh random salt. Transfer the encrypted `.gavault` file with AirDrop or your chosen file-sharing method. Keep the passphrase separately; there is no recovery service. Restore **replaces** the destination knowledge base and does not merge edits. Models are not included in backups.

Only the explicit model-download flow makes application network requests, to Hugging Face and its download infrastructure. It sends no document text or chat prompts. Inference loads a local model directory. There is no cloud AI fallback, automatic synchronization, analytics, or account system. The app does not change the storage or sharing of the original file you choose from Files.

## Current limits

- Model memory use, response latency, thermal behavior, and answer quality need measurement on actual devices. A 4-bit model's file size is not its total working-memory requirement. iOS can terminate an app under memory pressure.
- PDF import extracts embedded text; it does not perform OCR or interpret diagrams. Files are limited to 50 MB and PDFs to 2,000 pages.
- Retrieval is local keyword ranking with limited typo tolerance, not semantic embeddings. Chat receives up to six matching passages, rather than the whole knowledge base. It can miss relevant material.
- Chats are session-only and include limited follow-up context. More reasoning increases the token budget; it does not guarantee accuracy.
- Confirmed notes and guides are user-reviewed records, not automatically official policy.
- Backups are limited to 160 MB of PDF originals and a 300 MB encrypted file. Automatic synchronization and concurrent cross-device editing are not implemented.
- Release IPAs are ad-hoc signed for AltStore to re-sign. This is not an App Store or TestFlight release.

## Development checks

```sh
swift test
python3 scripts/generate_project.py
xcodebuild -project GuidedAssistance.xcodeproj -scheme GuidedAssistance-Mac -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GuidedAssistance.xcodeproj -scheme GuidedAssistance-iOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The shared repository workflow `.github/workflows/guided-assistance.yml` packages the IPA and publishes it to the existing kharrison Apps source only after checks pass. It never downloads the AI model or imports user documents. Simulator fixtures are fictional and excluded from physical-device builds.

See [architecture](docs/ARCHITECTURE.md), [device checks](docs/DEVICE_CHECKS.md), and [third-party notices](THIRD_PARTY_NOTICES.md). An open-source license for the original app code has not been selected yet.
