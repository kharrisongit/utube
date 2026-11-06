# Architecture

The two Xcode targets share the SwiftUI App sources and the Foundation-only Core sources. The root Swift package exists solely to run Core tests independently of MLX, Metal, or Apple UI frameworks.

## Knowledge

`LibraryStore` owns a versioned JSON catalog and original PDF files. Catalog replacement is atomic. Imported PDFs are named with generated UUIDs in Application Support; a source filename never becomes a destination path. SHA-256 rejects byte-identical imports. All knowledge files are excluded from system backups.

`KnowledgeSearch` constructs bounded, overlapping passages and term-frequency statistics. Ranking uses a BM25-style score, title matches, coverage, and limited one-character typo tolerance. Answer retrieval excludes archived or draft notes and guides, and future-dated references. Only the latest note version is indexed. Date eligibility refreshes when the app becomes active.

Request guides are edited by the user. Checklist state is ephemeral. Notes have revision checks to avoid silently overwriting another open note editor. There is no multi-device synchronization protocol.

## Answers

Chat retrieves six passages, then opens a fresh local MLX chat session with those passages, the current question, and limited previous-question context. It does not upload user material. The model returns JSON with answer sections and exact supporting quotations. The app validates source bounds and quotation membership before displaying a section.

Quotation validation cannot establish that the text supports the interpretation. Prompt rules about conflicts and embedded instructions are best-effort model guidance. The assistant has no action tools, network tool, document-write capability, or authority to confirm its own drafts.

The model is a separate optional runtime download. Downloads resolve one repository commit and use that same revision for every file. Large-file SHA-256 and byte counts are verified when supplied by the model repository. The completed model is exposed only after all files have arrived. MLX loads only that local directory. No Hugging Face account or token is required.

The app depends on MLXLLM, MLXVLM, MLXLMCommon, and Tokenizers. The concrete tokenizer adapter avoids pulling in the FoundationModels integration or a macro-based network downloader. Top-level package versions are pinned; commit the Xcode-generated Package.resolved after the first successful native resolution to also pin transitive versions.

## Backups

Encrypted backups contain the catalog and PDF originals, never the model. AES-GCM authenticates the payload. PBKDF2 derives a 256-bit key from the passphrase and a new 128-bit salt. Restore checks the schema, duplicate IDs, exact PDF-name set, file signatures, and hashes before any catalog replacement.

Restored documents receive new UUIDs and are written alongside existing originals. The catalog is committed before old originals are removed. An interrupted restore may leave orphan originals, but does not intentionally remove the old originals before the new catalog exists. There is no password recovery, synchronization, or conflict merge.

On Mac the App Sandbox allows selected-file access and outgoing network connections for model downloads. There is no incoming network server. The optional biometric/passcode gate does not encrypt the database separately from device file protection or FileVault.
