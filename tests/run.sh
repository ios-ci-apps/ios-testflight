#!/usr/bin/env bash
# Runs bin/testflight-upload against a fake xcodebuild that records its arguments and builds a
# fake archive, so the argument handling, key handling and build-number check run on Linux.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
check() {
    if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi
}

fakebin="$work/bin"; mkdir -p "$fakebin"
cat > "$fakebin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
# Records each call; "archive" writes an app whose CFBundleVersion follows CURRENT_PROJECT_VERSION
# unless FAKE_FIXED_BUILD is set, the way an Info.plist with a hard-coded build number behaves.
printf '%s\n' "$*" >> "$XCODEBUILD_LOG"
# Build scripts inherit this environment; record whether the key is in it.
[[ -z "${ASC_PRIVATE_KEY+set}" ]] || echo "xcodebuild saw ASC_PRIVATE_KEY" >> "$LEAK_LOG"
if [[ "$1" == archive ]]; then
    archive="" build=""
    while (($#)); do
        case "$1" in
            -archivePath) archive="$2"; shift ;;
            CURRENT_PROJECT_VERSION=*) build="${1#*=}" ;;
        esac
        shift
    done
    mkdir -p "$archive/Products/Applications/Demo.app"
    python3 -c 'import plistlib,sys; plistlib.dump({"CFBundleShortVersionString":"1.2","CFBundleVersion":sys.argv[2]}, open(sys.argv[1],"wb"))' \
        "$archive/Products/Applications/Demo.app/Info.plist" "${FAKE_FIXED_BUILD:-$build}"
fi
FAKE
chmod +x "$fakebin/xcodebuild"
# xcodegen can run commands from project.yml; record whether it can see the key.
cat > "$fakebin/xcodegen" <<'FAKE'
#!/usr/bin/env bash
[[ -z "${ASC_PRIVATE_KEY+set}" ]] || echo "xcodegen saw ASC_PRIVATE_KEY" >> "$LEAK_LOG"
[[ -z "$(find "$TMPDIR" -name 'AuthKey*' 2> /dev/null)" ]] || echo "xcodegen saw the key file" >> "$LEAK_LOG"
echo generated >> "$LEAK_LOG.ran"
FAKE
chmod +x "$fakebin/xcodegen"
mkdir -p "$work/tmp"
# The script's own temporary folder lands here, so the test can see the key file is gone.
export PATH="$fakebin:$PATH" XCODEBUILD_LOG="$work/xcodebuild.log" TMPDIR="$work/tmp" LEAK_LOG="$work/leak.log"
unset RUNNER_TEMP

# Built from pieces so secret scanners don't take this fake key for a real one.
marker="PRIVATE KEY"
KEY="-----BEGIN $marker-----"$'\n'"MIGTAgEAsecretkeymaterial"$'\n'"-----END $marker-----"
ISSUER=69a6de70-1111-47e3-e053-5b8c7c11a4d1
mkdir -p "$work/project"
upload() { (cd "$work/project" && "$ROOT/bin/testflight-upload" --scheme DemoProd --key-id ABCDE12345 --issuer-id "$ISSUER" --output "$work/out" "$@"); }

check "uploads with a key from the environment" 'ASC_PRIVATE_KEY="$KEY" upload --build-number 42 --team-id TEAM123456 > "$work/out.txt" 2>&1 && tail -n 1 "$work/out.txt" | grep -qx "1.2 (42)"'
check "archive gets the build number, team and API key" 'grep "^archive" "$XCODEBUILD_LOG" | grep -q "CURRENT_PROJECT_VERSION=42" && grep "^archive" "$XCODEBUILD_LOG" | grep -q "DEVELOPMENT_TEAM=TEAM123456" && grep "^archive" "$XCODEBUILD_LOG" | grep -q -- "-authenticationKeyID ABCDE12345"'
check "export uploads to App Store Connect" 'grep -q "^-exportArchive" "$XCODEBUILD_LOG" && python3 -c "import plistlib,sys; o=plistlib.load(open(sys.argv[1],\"rb\")); assert o[\"method\"]==\"app-store-connect\" and o[\"destination\"]==\"upload\" and o[\"teamID\"]==\"TEAM123456\" and o[\"manageAppVersionAndBuildNumber\"] is False" "$work/out/ExportOptions.plist"'
check "the private key is never printed" '! grep -q secretkeymaterial "$work/out.txt"'
check "the private key file is removed afterwards" '[[ -z "$(ls -A "$work/tmp")" ]]'
: > "$XCODEBUILD_LOG"
check "the default build number is the UTC minute" 'ASC_PRIVATE_KEY="$KEY" upload > "$work/out.txt" 2>&1 && grep -qE "CURRENT_PROJECT_VERSION=[0-9]{12}( |$)" "$XCODEBUILD_LOG"'
check "no team leaves the project's team alone" '! grep -q DEVELOPMENT_TEAM "$XCODEBUILD_LOG"'
printf '%s\n' "$KEY" > "$work/AuthKey.p8"
check "a key file on the runner works" 'upload --key-path "$work/AuthKey.p8" --build-number 7 > /dev/null 2>&1'
check "a hard-coded Info.plist build number is caught before upload" ': > "$XCODEBUILD_LOG"; ! FAKE_FIXED_BUILD=1 ASC_PRIVATE_KEY="$KEY" upload --build-number 8 2> "$work/err" && grep -q "CURRENT_PROJECT_VERSION" "$work/err" && ! grep -q "^-exportArchive" "$XCODEBUILD_LOG"'
check "a missing key is refused" '! upload 2> "$work/err" && grep -q "no private key" "$work/err"'
check "a file that is not a .p8 key is refused" 'echo nope > "$work/bad.p8" && ! upload --key-path "$work/bad.p8" 2> "$work/err" && grep -q "not a .p8 key" "$work/err"'
check "a malformed key ID is refused" '! (cd "$work/project" && ASC_PRIVATE_KEY="$KEY" "$ROOT/bin/testflight-upload" --scheme S --key-id short --issuer-id "$ISSUER") 2> /dev/null'
check "a malformed build number is refused" '! ASC_PRIVATE_KEY="$KEY" upload --build-number 1.2.3.4 2> /dev/null'
touch "$work/kc.pw"; chmod 644 "$work/kc.pw"
check "a keychain password file others can read is refused" '! ASC_PRIVATE_KEY="$KEY" upload --keychain-password-file "$work/kc.pw" 2> "$work/err" && grep -q "chmod 600" "$work/err"'

# Inputs must not reach a path that gets deleted (a scheme like x/../victim used to remove a
# sibling folder of $RUNNER_TEMP/testflight-x).
rt="$work/runner-temp"; mkdir -p "$rt/testflight-x" "$rt/victim" "$rt/testflight-DemoProd"
echo keep > "$rt/victim/keep"; echo keep > "$rt/testflight-DemoProd/keep"
check "a scheme with a path in it is refused" '! RUNNER_TEMP="$rt" ASC_PRIVATE_KEY="$KEY" "$ROOT/bin/testflight-upload" --scheme "x/../victim" --key-id ABCDE12345 --issuer-id "$ISSUER" 2> "$work/err" && grep -q "scheme name" "$work/err"'
check "a scheme that looks like an option is refused" '! ASC_PRIVATE_KEY="$KEY" "$ROOT/bin/testflight-upload" --scheme "-quiet" --key-id ABCDE12345 --issuer-id "$ISSUER" 2> /dev/null'
check "nothing outside the output is deleted" '[[ -f "$rt/victim/keep" && -f "$rt/testflight-x/../victim/keep" ]]'
check "the default output is a new folder under RUNNER_TEMP" '(cd "$work/project" && RUNNER_TEMP="$rt" ASC_PRIVATE_KEY="$KEY" "$ROOT/bin/testflight-upload" --scheme DemoProd --key-id ABCDE12345 --issuer-id "$ISSUER" --build-number 9 > /dev/null 2>&1) && compgen -G "$rt/testflight.*/App.xcarchive" > /dev/null && [[ -f "$rt/testflight-DemoProd/keep" && -f "$rt/victim/keep" ]]'
echo keep > "$work/out/keep"
check "--output keeps files the script did not write" 'ASC_PRIVATE_KEY="$KEY" upload --build-number 10 > /dev/null 2>&1 && [[ -f "$work/out/keep" && -d "$work/out/App.xcarchive" ]]'

# The key stays out of the environment of everything the script starts.
touch "$work/project/project.yml"; : > "$LEAK_LOG"
check "xcodegen and xcodebuild don't inherit ASC_PRIVATE_KEY" 'ASC_PRIVATE_KEY="$KEY" upload --build-number 11 > /dev/null 2>&1 && [[ -s "$LEAK_LOG.ran" && ! -s "$LEAK_LOG" ]]'
rm "$work/project/project.yml"
check "a relative key path works from another project directory" '(cd "$work" && "$ROOT/bin/testflight-upload" --project-dir project --scheme DemoProd --key-id ABCDE12345 --issuer-id "$ISSUER" --output out --key-path AuthKey.p8 --build-number 12 > /dev/null 2>&1) && grep "^archive" "$XCODEBUILD_LOG" | tail -n 1 | grep -q -- "-authenticationKeyPath $work/AuthKey.p8"'

if ((fails)); then echo "$fails test(s) failed"; exit 1; fi
echo "all tests passed"
