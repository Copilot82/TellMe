# GitHub repository configuration

## 1. Publication policy

GitHub publishes the source code, release artifacts, CI evidence, security analysis, and technical
documentation. The repository is not operated as a public collaboration project: third-party pull
requests, issues, and integration requests are not processed.

No public roadmap, release cadence, or response schedule is stated.

Before publication, the owner reviews the diff, commit metadata, and secret-scan result. An
automated push requires separate explicit approval from the owner.

## 2. General properties

The following values are configured under **Settings → General**:

- Description: `Self-hosted E2E iOS messenger with a Rust backend`;
- Website: `https://copilot82.github.io/TellMe/`;
- Topics: `ios`, `swift`, `rust`, `self-hosted`, `e2ee`, `axum`, `webrtc`, `cryptography`;
- **Issues**, **Discussions**, **Projects**, and **Wikis** are disabled;
- no funding links or public support channels are published;
- Releases identify validated source versions.

Disabling community features defines the repository access model and is not replaced by a formal
invitation to contribute in README.

## 3. GitHub Pages

**Settings → Pages → Build and deployment** uses **GitHub Actions**. The `Documentation` workflow
runs a strict build, local-link validation, and a structural-parity check for Russian and English;
deployment is allowed only from the default branch.

After a documentation change, verify:

- the landing page and navigation;
- Mermaid diagrams at desktop and mobile viewport widths;
- external Apple, Docker, Caddy, and TestFlight links;
- the absence of UI controls that suggest editing through a pull request;
- Russian and English search behavior and the language switcher.

## 4. Default-branch protection

The default-branch ruleset provides:

- deletion and force-push protection;
- linear history;
- required status checks;
- direct-write access restricted to the repository owner;
- signed commits when a stable signing configuration is available.

Required checks:

- Rust formatting, Clippy, and tests;
- dependency and license policy;
- local Compose smoke;
- iOS unit tests;
- headless E2E;
- strict documentation build, link validation, and translation parity;
- Swift CodeQL;
- Gitleaks history scan.

A pull-request requirement is not enabled. The absence of a public review workflow is an
intentional repository constraint.

## 5. Security features

The repository enables:

- dependency graph and Dependabot alerts;
- secret scanning and push protection;
- private vulnerability reporting without a stated response SLA;
- the `CodeQL` workflow without simultaneous GitHub default setup;
- Gitleaks checks for published history.

Automated results apply to a specific commit. They do not replace an independent review of the
protocol, iOS client, and production infrastructure.

A code-scanning alert is dismissed as a false positive only after a static review of the source,
sink, trust boundary, and actual data contract. The alert comment records the reason.

## 6. Release

Release `v2.0.0` records:

- the project purpose as a corporate self-hosted source base;
- the complete commit hash;
- the executed CI and release gates;
- the deployment-guide URL;
- the public TestFlight URL and its possible unavailability before Apple review;
- the absence of an independent security audit and group messaging;
- license information.

Release assets must not contain `.env` files, APNs keys, provisioning profiles, signing
certificates, device logs, `xcresult` bundles with personal data, or production backups.

## 7. Privacy checks before push

Minimum validation:

```bash
git status --short
git diff --check
git log --format='%an <%ae>' | sort -u
rg -n -i 'password|secret|token|private.?key' --glob '!**/.git/**'
gitleaks git --redact --no-banner
```

The final command checks history, not only the working tree. If commit metadata contains a personal
name or email address, changing README is insufficient: create the public history with a neutral
project identity or rewrite it before push.

## 8. Configuration drift control

After changing repository settings in the UI or through the API, verify:

- visibility, default branch, and the GitHub Pages URL;
- community-feature state;
- the default-branch ruleset;
- Dependabot, CodeQL, secret scanning, and push-protection state;
- the latest run of each required check;
- that the release tag resolves to the validated commit.

Actual GitHub settings take precedence over this document. Correct any discrepancy in the same
administrative change that modified the repository configuration.
