#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
BUILD_ROOT="${PROJECT_ROOT}/build/ci"

cd "$PROJECT_ROOT"
mkdir -p "$BUILD_ROOT"

die() {
  print -u2 "ci-quality: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

for tool in swift swift-format zsh plutil gitleaks syft osv-scanner; do
  require_command "$tool"
done

print "== Swift package and lockfile =="
swift package dump-package > "$BUILD_ROOT/package.json"
LOCK_COPY="$(mktemp)"
trap 'rm -f "$LOCK_COPY"' EXIT
cp Package.resolved "$LOCK_COPY"
swift package resolve
cmp -s Package.resolved "$LOCK_COPY" \
  || die "swift package resolve changed Package.resolved; commit the resolved dependency update explicitly"

print "== Swift format =="
# Strict mode turns formatter diagnostics into a non-zero exit status. Keep
# Package.swift in the same gate so CI cannot silently pass style warnings.
swift-format lint --recursive --strict Package.swift Sources tests

print "== Shell and plist syntax =="
zsh -n Scripts/*.sh
plutil -lint Resources/Info.plist

print "== Build and XCTest =="
swift build -c release --product LocalOps
XCTEST_LOG="$BUILD_ROOT/xctest.log"
swift test 2>&1 | tee "$XCTEST_LOG"
if [[ "${LOCALOPS_FORBID_XCTSKIP:-0}" == "1" ]] \
  && grep -Eq 'Test skipped|tests skipped' "$XCTEST_LOG"; then
  die "XCTest skipped tests are forbidden for a release candidate"
fi

print "== Dependency vulnerability scan =="
osv-scanner scan source --recursive "$PROJECT_ROOT"

print "== Secret scan =="
gitleaks detect --source "$PROJECT_ROOT" --no-banner --redact --exit-code 1

print "== Dependency license inventory =="
LICENSE_REPORT="$BUILD_ROOT/dependency-licenses.txt"
: > "$LICENSE_REPORT"
missing_license=0
for checkout in .build/checkouts/*; do
  [[ -d "$checkout" ]] || continue
  license_file="$(find "$checkout" -maxdepth 2 -type f \
    \( -iname 'license' -o -iname 'license.*' -o -iname 'copying' -o -iname 'copying.*' \) \
    -print -quit)"
  if [[ -z "$license_file" ]]; then
    print -u2 "missing license file: $checkout"
    missing_license=$((missing_license + 1))
  else
    print "${checkout:t}\t${license_file#$checkout/}" >> "$LICENSE_REPORT"
  fi
done
(( missing_license == 0 )) || die "one or more resolved dependencies have no discoverable license file"

print "== SBOM =="
syft "dir:${PROJECT_ROOT}" -o "spdx-json=${BUILD_ROOT}/localops-sbom.spdx.json"
print "quality gates passed; reports are under ${BUILD_ROOT}"
