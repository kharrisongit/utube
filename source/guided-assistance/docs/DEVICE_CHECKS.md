# First native verification

These checks are pending; they are not a record of successful execution.

1. Resolve dependencies, run `swift test`, and build both app targets with Xcode. Confirm MLX's Metal resources are included.
2. Launch on the Mac and physical iPhone. Check the dashboard, tab bar/sidebar, dark mode, keyboard, scrolling, and large text sizes.
3. Use a fictional searchable PDF with at least two pages. Import, search, inspect the cited page, relaunch, and verify persistence. Import the same bytes twice and confirm the duplicate message.
4. Import an image-only PDF and verify that the app reports missing extractable text. Import a UTF-8 text file and a Markdown file.
5. Create draft, confirmed, archived, and future-dated updates. Verify answer retrieval only uses current eligible content. Edit a note and verify its prior wording appears in history but not retrieval.
6. Create a guide with a checklist and steps. Pin, edit, search, and delete it. Confirm checklist ticks reset when the view is recreated.
7. Download the model while monitoring memory and storage. Cancel a download and retry. After installation, use airplane mode and ask questions with known answers. Verify quotations, uncertainty handling, follow-ups, cancellation, and backgrounding.
8. Test a contradictory pair of fictional policies and a document containing misleading model instructions. Check that no unsupported action is presented as verified policy.
9. Export an encrypted backup. Restore it with the correct passphrase on the other device. Try an incorrect passphrase and a truncated file; existing knowledge must remain intact.
10. Enable authentication, background and reopen the app, and test a failed biometric attempt. Verify screen content is not visible before unlocking.

Record the device, OS, peak memory, response times, and any build/runtime errors before promoting this preview to a release.
