# Repository secret audit

On October 10, 2026, before changing `aoppenh1-afk/J.A.R.I.S` from private to public:

- Fetched the current remote branch and tags, and scanned all 35 commits reachable from local and remote refs with Gitleaks 8.30.1.
- Scanned a copy of the 153 tracked and new working files, excluding ignored local configuration and build output.
- Scanned GitHub issue and pull-request metadata. No issues, pull requests, release assets, or Actions artifacts existed.
- Extracted every historical image blob and ran accurate CPU OCR on all 19 image versions, checking the extracted text for credential patterns.
- Reviewed environment examples, credential handling, signing settings, and release scripts. The example API key is empty. Runtime credentials are stored in Keychain; signing identity names and team IDs are public identifiers.

No secret candidates were detected by the text scans or image checks. The repository was then changed to public and its visibility was verified through GitHub. No history rewrite was needed.

The Sparkle private key generated afterward was stored in Keychain and a GitHub Actions secret. Its temporary export was deleted. Only its public verification key is included in the app. The new checks workflow repeats a redacted history scan, and Git ignores private-key and certificate export files.
