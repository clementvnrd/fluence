#!/bin/bash
# Checks a built Fluence.app the way it ships, then launches it with --selftest (FLU-35).
#
#   Tools/check_app_bundle.sh <path/to/Fluence.app> [--public] [--timeout SECONDS]
#
# 1. the signature: codesign --verify --strict --deep;
# 2. Info.plist: CFBundleShortVersionString is Resources/Info.plist's (or $EXPECT_VERSION) and
#    CFBundleVersion is the build number derived from it (major*10000 + minor*100 + patch);
# 3. Sparkle: the framework is embedded, the binary links it through @rpath, and the rpath
#    @executable_path/../Frameworks that finds it is there;
# 4. with --public: no Wispr Flow interop in the binary (FLU-69);
# 5. the launch: Contents/MacOS/Fluence --selftest must print "selftest: passed" and exit 0
#    within the timeout. A broken rpath, a bad signature, a trap at launch or a hang all fail.
#
# Every check runs even after one fails, so one run lists everything that is wrong.
# Exit 0 when all pass, 1 otherwise. Never touches /Applications or the user's data: the
# self-test works in a scratch folder of its own (AppPaths.override, see SelfTest.swift).
set -u

bundle=""
public=0
timeout=120
while [ $# -gt 0 ]; do
  case "$1" in
    --public) public=1 ;;
    --timeout) shift; timeout="${1:?--timeout needs seconds}" ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) bundle="$1" ;;
  esac
  shift
done
[ -n "$bundle" ] || { echo "usage: $0 <Fluence.app> [--public] [--timeout SECONDS]" >&2; exit 2; }
bundle="${bundle%/}"

here="$(cd "$(dirname "$0")/.." && pwd)"
binary="$bundle/Contents/MacOS/Fluence"
plist="$bundle/Contents/Info.plist"
sparkle="$bundle/Contents/Frameworks/Sparkle.framework"
failures=0

pass() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1"
  # GitHub Actions turns this into an annotation on the run.
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=App bundle check::$1"
  failures=$((failures + 1))
}

[ -d "$bundle" ] || { fail "no bundle at $bundle"; exit 1; }
[ -x "$binary" ] || fail "no executable at Contents/MacOS/Fluence"

# 1. Signature
if out=$(codesign --verify --strict --deep "$bundle" 2>&1); then
  signer=$(codesign -dvv "$bundle" 2>&1 | sed -n 's/^Authority=//p;s/^Signature=//p' | head -1)
  pass "signature: codesign --verify --strict --deep (${signer:-unknown signer})"
else
  fail "signature: $out"
fi

# 2. Version
expected="${EXPECT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$here/Resources/Info.plist" 2>/dev/null)}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)
derived=$(echo "$version" | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $1 * 10000 + $2 * 100 + $3 }')
if [ -z "$version" ] || [ "$version" != "$expected" ]; then
  fail "version: bundle says '$version', expected '$expected'"
elif [ -z "$derived" ] || [ "$build" != "$derived" ]; then
  fail "version: CFBundleVersion '$build', expected $derived for $version"
else
  pass "version: $version ($build)"
fi

# 3. Sparkle and the rpath
if [ ! -f "$sparkle/Versions/B/Sparkle" ]; then
  fail "sparkle: Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle is missing"
else
  pass "sparkle: framework embedded"
fi
if otool -L "$binary" 2>/dev/null | grep -q "@rpath/Sparkle.framework/Versions/B/Sparkle"; then
  pass "sparkle: linked through @rpath"
else
  fail "sparkle: the binary does not link @rpath/Sparkle.framework"
fi
if otool -l "$binary" 2>/dev/null | grep -A2 LC_RPATH | grep -q "path @executable_path/../Frameworks "; then
  pass "rpath: @executable_path/../Frameworks"
else
  fail "rpath: @executable_path/../Frameworks is missing (rpaths: $(otool -l "$binary" 2>/dev/null | grep -A2 LC_RPATH | sed -n 's/^ *path \(.*\) (offset.*/\1/p' | tr '\n' ' '))"
fi

# 4. A public build carries no Wispr Flow interop
if [ "$public" = 1 ]; then
  if strings "$binary" | grep -qE "WisprReader|WisprTrigger"; then
    fail "public build: WisprReader or WisprTrigger found in the binary"
  else
    pass "public build: no Wispr Flow interop"
  fi
fi

# 5. The launch. perl's alarm is the timeout macOS lacks; SIGALRM ends the process.
log=$(mktemp -t fluence-selftest)
started=$(date +%s)
perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$timeout" "$binary" --selftest >"$log" 2>&1
status=$?
elapsed=$(( $(date +%s) - started ))
sed 's/^/      | /' "$log"
if [ $status -eq 0 ] && grep -q "^selftest: passed" "$log"; then
  pass "launch: --selftest passed in ${elapsed} s"
elif [ $status -eq 142 ]; then
  fail "launch: --selftest still running after ${timeout} s (hang)"
elif [ $status -gt 128 ]; then
  fail "launch: crashed with signal $((status - 128)) ($(kill -l $((status - 128)) 2>/dev/null || echo '?')) after ${elapsed} s"
elif [ $status -eq 0 ]; then
  fail "launch: exited 0 without 'selftest: passed' (was --selftest ignored?)"
else
  fail "launch: --selftest exited with status $status"
fi
rm -f "$log"

if [ $failures -eq 0 ]; then
  echo "all checks passed: $bundle"
  exit 0
fi
echo "$failures check(s) failed: $bundle"
exit 1
