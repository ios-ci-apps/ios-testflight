# ios-testflight

A GitHub Action that archives an iOS app on your self-hosted Mac runner and uploads it to TestFlight.

Signing goes through an **App Store Connect API key**. Nobody signs in to Xcode on the runner, and no distribution certificate is kept on the Mac. Xcode creates the certificates and profiles it needs from the key, and the App Store upload is signed in Apple's cloud.

Needs a paid Apple Developer Program membership. For a free team, see [ios-ota-server](https://github.com/ios-ci-apps/ios-ota-server), which installs builds from a private web page instead.

## One-time setup

Everything here can be done in a phone's browser.

1. **API key.**
   - App Store Connect → Users and Access → Integrations → **App Store Connect API** → Team Keys → generate a key with the **Admin** role.
   - Note the **Key ID** and **Issuer ID**.
   - Download the `.p8` file. It can only be downloaded once.
2. **Bundle IDs.** Certificates, Identifiers & Profiles → Identifiers → register each app's bundle ID, and each extension's, with the capabilities it uses (HealthKit, App Groups, ...).
   - If Apple says an ID is not available, another team (for example an old free personal team) holds it, and the app needs a new bundle ID.
   - Xcode can also register IDs itself during the first upload, but registering them first shows this problem early.
3. **App records.** App Store Connect → Apps → **+** → New App, one per app, with its bundle ID.
4. **Secrets in the app repository**, under Settings → Secrets and variables → Actions:
   - secret `ASC_PRIVATE_KEY`: the whole contents of the `.p8` file;
   - variables `ASC_KEY_ID`, `ASC_ISSUER_ID` and `APPLE_TEAM_ID` (Account → Membership details).

   If you can't add secrets to the repository, put the `.p8` on the runner instead (chmod 600, outside any repository) and pass `api-key-path`.
5. **The app's Info.plist:**
   - `CFBundleVersion` must be `$(CURRENT_PROJECT_VERSION)`, so each upload can set its own build number. The action stops before uploading if it isn't.
   - Add `ITSAppUsesNonExemptEncryption` = `NO` if the app uses no encryption beyond Apple's own, so builds don't wait for the export-compliance question.
6. **TestFlight.** In App Store Connect → the app → TestFlight, add yourself to an internal group, and install the TestFlight app on the iPhone. Internal testing needs no review.

Then copy [`examples/testflight.yml`](examples/testflight.yml) into the app repository and set `scheme`.

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
- **The key's reach.** An Admin key can manage the whole App Store Connect team. Keep it in a secret, never in a repository, and revoke it in App Store Connect if it leaks. The action writes it to a private temporary file and deletes it when done, and never prints it.
- **Processing.** After the upload, App Store Connect processes the build, usually within minutes, before it appears in TestFlight. Internal testers get it without review.

## Tests

```bash
tests/run.sh
```

The tests run the script against a fake `xcodebuild`, so they cover argument, key and build-number handling on Linux. The real archive and upload need a Mac and a paid team.

## License

MIT
