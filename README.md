# ios-testflight

A GitHub Action that archives an iOS app on your self-hosted Mac runner and uploads it to TestFlight.

Signing goes through an **App Store Connect API key**. Nobody signs in to Xcode on the runner, and no distribution certificate is kept on the Mac. Xcode creates the certificates and profiles it needs from the key, and the App Store upload is signed in Apple's cloud.

Needs a paid Apple Developer Program membership. For a free team, see [ios-ota-server](https://github.com/ios-ci-apps/ios-ota-server), which installs builds from a private web page instead.

## One-time setup

Everything here can be done in a phone's browser.

1. **API key.**
   - App Store Connect → Users and Access → Integrations → **App Store Connect API** → Team Keys → generate a key with the **Admin** role (see [Why Admin](#why-the-key-needs-the-admin-role)). Make a key just for this CI, so it can be revoked without breaking anything else.
   - Note the **Key ID** and **Issuer ID**.
   - Download the `.p8` file. It can only be downloaded once.
2. **Bundle IDs.** Certificates, Identifiers & Profiles → Identifiers → register each app's bundle ID, and each extension's, with the capabilities it uses (HealthKit, App Groups, ...).
   - If Apple says an ID is not available, another team (for example an old free personal team) holds it, and the app needs a new bundle ID.
   - Xcode can also register IDs itself during the first upload, but registering them first shows this problem early.
3. **App records.** App Store Connect → Apps → **+** → New App, one per app, with its bundle ID.
4. **Secrets in the app repository**, under Settings → Environments → New environment (for example `testflight`):
   - secret `ASC_PRIVATE_KEY`: the whole contents of the `.p8` file;
   - variables `ASC_KEY_ID`, `ASC_ISSUER_ID` and `APPLE_TEAM_ID` (Account → Membership details);
   - under **Deployment branches and tags**, allow only `main`, so a workflow on any other branch cannot read the key. Add required reviewers if uploads should wait for approval.

   If you can't add secrets to the repository, put the `.p8` on the runner instead (chmod 600, outside any repository) and pass `api-key-path`.
5. **The app's Info.plist:**
   - `CFBundleVersion` must be `$(CURRENT_PROJECT_VERSION)`, so each upload can set its own build number. The action stops before uploading if it isn't.
   - Add `ITSAppUsesNonExemptEncryption` = `NO` if the app uses no encryption beyond Apple's own, so builds don't wait for the export-compliance question.
6. **TestFlight.** In App Store Connect → the app → TestFlight, add yourself to an internal group, and install the TestFlight app on the iPhone. Internal testing needs no review.

Then copy [`examples/testflight.yml`](examples/testflight.yml) into the app repository, set `scheme`, and replace `<full commit SHA>` with the 40-character SHA of the release you want (see [Security](#security)).

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `scheme` | yes | | scheme to archive |
| `api-key-id`, `api-issuer-id` | yes | | the API key's IDs |
| `api-private-key` | one of these two | | the `.p8` contents, from a secret |
| `api-key-path` | | | the `.p8` file on the runner |
| `team-id` | | project's `DEVELOPMENT_TEAM` | team that signs |
| `build-number` | | UTC time, `yyyymmddHHMM` | `CFBundleVersion`; must grow with every upload |
| `project-dir`, `project`, `workspace` | | `.`, found by xcodebuild | where the Xcode project is |
| `configuration` | | `Release` | build configuration |
| `keychain-password-file` | | | runner user's login password file (chmod 600), to unlock the keychain first |

`xcodegen generate` runs first when the project directory has a `project.yml` and `xcodegen` is on `PATH`.

## Notes

- **Build numbers.** App Store Connect refuses a build number it has already seen for the same version. The default, the UTC minute, keeps growing even when uploads come from different workflows.
- **Keychain.** Xcode keeps the development certificate it creates for the archive step in the runner user's login keychain. A runner service can find that keychain locked (`errSecInternalComponent`). Pass `keychain-password-file` to unlock it first, and run `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<password>' ~/Library/Keychains/login.keychain-db` once.
- **The key's reach.** An Admin key can manage the whole App Store Connect team. Keep it in a secret, never in a repository, and revoke it in App Store Connect if it leaks. The action never prints it; see [Security](#security) for where it is exposed during a run.
- **Processing.** After the upload, App Store Connect processes the build, usually within minutes, before it appears in TestFlight. Internal testers get it without review.

## Security

### Using it from another organization

This repository holds only the action's code. It never sees your key, your app or your runner:

- **Secrets come from the calling repository.** `api-private-key` is whatever the app repository's workflow passes in, from its own secret. Nothing is stored here; the action itself hands the key only to `xcodebuild`, which uses it with Apple.
- **The Mac runner is yours.** The job runs on the runner the calling workflow picks with `runs-on`, registered to your organization or repository. This repository's own CI runs only on GitHub-hosted runners and never reaches it.
- **Pin a full commit SHA**, not a tag or branch: `uses: ios-ci-apps/ios-testflight@<40-character SHA> # v1.0.0`. A tag can be moved to other code; a SHA cannot. Read the diff before you move the pin to a newer SHA. Dependabot can propose those updates for you.

### Untrusted code must never reach the deploy runner

During a run, everything that executes on the runner can use the key:

- The action removes `ASC_PRIVATE_KEY` from the environment before it starts anything, so `xcodegen`, `xcodebuild` and build scripts do not inherit it.
- But `xcodebuild` must read the key, so it is written to a private temporary file (mode 600, deleted when the step ends) for the archive and upload steps. Run Script build phases, Swift package plugins, CocoaPods scripts and `xcodegen` commands run as the same user and could read that file, the login keychain, and `keychain-password-file`.
- So the code being built is trusted with an Admin key. Only build code that has been reviewed into your default branch.

In practice:

- Trigger uploads with `workflow_dispatch`, `push` to `main`, or `workflow_run` limited to `push` events on `main` (`if: github.event.workflow_run.event == 'push' && github.event.workflow_run.head_branch == 'main'`). Never with `pull_request` or `pull_request_target`, and never check out a pull request's code in a job that has the key.
- Keep the key in an environment that only `main` can deploy to (setup step 4).
- Give the Mac a runner group that only your trusted private app repositories can use. Never let a public repository's workflows run on it: anyone can open a pull request against a public repository.
- Use a dedicated macOS user for the runner, with nothing else in its keychain.
- Set `permissions: contents: read` in the workflow, and `persist-credentials: false` on checkout, as the example does.

### Why the key needs the Admin role

The action uses automatic, cloud-managed signing: `-allowProvisioningUpdates` lets Xcode create the development certificate and profiles for the archive, and the App Store distribution signature comes from a cloud-managed certificate. With an API key, Apple only allows cloud-managed distribution signing for **Admin** keys: an **App Manager** or **Developer** key typically fails at the upload with *"Cloud signing permission error"*, and unlike a user account, an API key cannot be given the separate "Access to Cloud Managed Distribution Certificate" permission. Apple does not document this requirement; it is what Apple's developer forums report.

A lower-privilege setup needs manual signing instead: keep an Apple Distribution certificate in the runner's keychain and an App Store provisioning profile on the Mac, and an App Manager key is then enough to upload. That brings back the certificate on the Mac this action is designed to avoid, so the action does not support it.

## Tests

```bash
tests/run.sh
```

The tests run the script against a fake `xcodebuild` and `xcodegen`, so they cover argument, key, output-folder and build-number handling on Linux, including that the key stays out of child processes' environment and that inputs cannot delete anything outside the output folder. The real archive and upload need a Mac and a paid team.

## License

MIT
