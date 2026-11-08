# Security policy

Please report security problems privately through **Report a vulnerability** under this repository's *Security* tab, not in a public issue.

Worth reporting: a way for the script to print or leave behind the App Store Connect private key or the keychain password; a way for inputs to run commands or write outside the build folder; anything in this repository's own CI that could reach a self-hosted runner.

Keep the API key in a GitHub secret or a chmod 600 file on the runner, never in a repository. A key with the Admin role can manage your whole App Store Connect team; revoke it in App Store Connect if it leaks.
