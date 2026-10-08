#!/usr/bin/env bash
# Self-test for core-image-cleanup.sh (riftal-infra#674). Stubs `docker` and
# `curl`, so no real image is removed and no API is called.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/core-image-cleanup.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=22
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/pins"

sha() { printf '%040x' "$1"; }
tag() { printf 'local-pocketmine-mp:%s' "$(sha "$1")"; }

# Tag 1 is main's pin and tag 2 an open pull request's, both older than every
# other sha tag. Tags 3 and 4 are the stale ones; 5 to 7 are the newest.
{
  printf '%s 2026-10-08T00:00:00.5Z\n' local-pocketmine-mp:latest
  for n in 1 2 3 4 5 6 7; do
    printf '%s 2026-09-0%sT12:00:00.%s00Z\n' "$(tag "$n")" "$n" "$n"
  done
  printf 'example/other:%s 2026-08-01T00:00:00Z\n' "$(sha 3)"
  printf 'local-pocketmine-mp:%s 2026-08-01T00:00:00Z\n' "$(sha 4 | cut -c1-39)"
} > "$work/images.fixture"
sha 1 > "$work/main.sha"
sha 99 > "$work/missing.sha"
printf '[{"number":11,"head":{"sha":"%s"}},{"number":12,"head":{"sha":"%s"}},%s]\n' \
  "$(sha 111)" "$(sha 112)" "{\"number\":13,\"head\":{\"sha\":\"$(sha 113)\"}}" > "$work/pulls.json"
sha 2 > "$work/pins/$(sha 111)"
printf 'latest\n' > "$work/pins/$(sha 113)"

cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_CALLS"
case "$1 $2" in
  "image ls")
    cut -d' ' -f1 "$STUB_IMAGES"
    ;;
  "image inspect")
    ref="${*: -1}"
    line="$(grep -F "$ref " "$STUB_IMAGES")" || { echo "No such image: $ref" >&2; exit 1; }
    if [ "$3" = --format ]; then printf '%s\n' "${line#* }"; fi
    ;;
  "image rm")
    [ "$#" -eq 3 ] || { echo "stub docker: image rm takes one tag: $*" >&2; exit 125; }
    if [ "$3" = "${STUB_REFUSE:-}" ]; then echo "conflict: $3 is in use" >&2; exit 1; fi
    grep -vF "$3 " "$STUB_IMAGES" > "$STUB_IMAGES.new"
    mv "$STUB_IMAGES.new" "$STUB_IMAGES"
    printf 'Untagged: %s\n' "$3"
    ;;
  *) echo "stub docker: unexpected call: $*" >&2; exit 125 ;;
esac
EOF

cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
config="$(cat)"
[[ "$config" == *'Authorization: Bearer stub-token'* ]] || { echo "stub curl: no token" >&2; exit 2; }
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --config | -w | -H) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
printf 'curl %s\n' "$url" >> "$STUB_CALLS"
case "$url" in
  "$STUB_API"/pulls\?state=open\&per_page=100\&page=1)
    [ -n "${STUB_PULLS_FAIL:-}" ] && { printf 502; exit 0; }
    cp "$STUB_DIR/pulls.json" "$out"
    ;;
  "$STUB_API"/contents/images/core-image.sha\?ref=*)
    ref="${url##*ref=}"
    [ "$ref" = "${STUB_PIN_FAIL:-}" ] && { printf 500; exit 0; }
    [ -f "$STUB_DIR/pins/$ref" ] || { printf 404; exit 0; }
    cp "$STUB_DIR/pins/$ref" "$out"
    ;;
  *) echo "stub curl: unexpected URL: $url" >&2; exit 2 ;;
esac
printf 200
EOF
chmod +x "$work/bin/docker" "$work/bin/curl"

# run <case> <main pin file> [VAR=value...]. Sets $calls, $out and $status.
run() {
  local name="$1" pin="$2"
  shift 2
  mkdir "$work/$name"
  calls="$work/$name/calls" out="$work/$name/out" status=0
  cp "$work/images.fixture" "$work/$name/images"
  : > "$calls"
  env PATH="$work/bin:$PATH" STUB_CALLS="$calls" STUB_IMAGES="$work/$name/images" \
    STUB_DIR="$work" STUB_API=https://api.test/repos/Riftal-Games/riftal-infra \
    GITHUB_API_URL=https://api.test GITHUB_REPOSITORY=Riftal-Games/riftal-infra \
    GH_TOKEN=stub-token GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/main "$@" \
    bash "$SCRIPT" "$pin" > "$out" 2>&1 || status=$?
}

removed() { grep '^docker image rm ' "$calls" | cut -d' ' -f4 | sort | tr '\n' ' '; }

# $1 what the case proves, $2 the exit status it needs, $3 text the output needs
expect_none_removed() {
  if [ "$status" -ne "$2" ]; then
    fail "$1: exit $status, expected $2: $(cat "$out")"
  elif grep -q '^docker image rm' "$calls"; then
    fail "$1: removed $(removed)"
  elif ! grep -qF -- "$3" "$out"; then
    fail "$1: output lacks \"$3\": $(cat "$out")"
  else
    pass "$1"
  fi
}

# $1 tag, $2 why it must survive
survives() {
  if grep -qxF "docker image rm $1" "$calls"; then
    fail "$2 was removed"
  elif ! grep -qF "$1 " "$work/scheduled/images"; then
    fail "$2 is gone from the daemon"
  else
    pass "$2 survives"
  fi
}

run scheduled "$work/main.sha"
if [ "$status" -eq 0 ] && [ "$(removed)" = "$(tag 3) $(tag 4) " ]; then
  pass "a scheduled run of main removes exactly the stale tags 3 and 4"
else
  fail "a scheduled run exited $status and removed: $(removed): $(cat "$out")"
fi
survives "$(tag 1)" "main's pin"
survives "$(tag 2)" "the pin of open pull request #11"
for n in 5 6 7; do
  survives "$(tag "$n")" "newest sha tag $n"
done
survives local-pocketmine-mp:latest "the bare tag"
survives "example/other:$(sha 3)" "another repository's sha tag"
survives "local-pocketmine-mp:$(sha 4 | cut -c1-39)" "a 39-character tag"
for text in "keep $(tag 1): main's images/core-image.sha" \
  "keep $(tag 2): pull request #11" "keep $(tag 7): one of the 3 newest" \
  "pull request #12 has no images/core-image.sha" "pull request #13 pins \"latest\"" \
  "removed $(tag 3)"; do
  if grep -qF -- "$text" "$out"; then
    pass "the log says: $text"
  else
    fail "the log lacks: $text: $(cat "$out")"
  fi
done

run list-fails "$work/main.sha" STUB_PULLS_FAIL=1
expect_none_removed "a failed pull request listing removes nothing" 1 "answered 502"
run pin-fails "$work/main.sha" STUB_PIN_FAIL="$(sha 112)"
expect_none_removed "a failed read of one pull request's pin removes nothing" 1 "#12 answered 500"
run main-pin-missing "$work/missing.sha"
expect_none_removed "main's pin not on the daemon removes nothing" 1 "main's pin does not resolve"
run pull-request "$work/main.sha" GITHUB_EVENT_NAME=pull_request
expect_none_removed "a pull_request run removes nothing" 0 "would remove $(tag 3)"
run dispatch-off-main "$work/main.sha" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/x
expect_none_removed "a dispatch run off main removes nothing" 0 "would remove $(tag 4)"

run refused "$work/main.sha" GITHUB_EVENT_NAME=workflow_dispatch STUB_REFUSE="$(tag 3)"
if [ "$status" -eq 0 ] && grep -qF "refused to remove $(tag 3)" "$out" &&
  grep -qxF "removed $(tag 4)" "$out"; then
  pass "a removal Docker refuses is reported and the rest carry on"
else
  fail "a refused removal: exit $status: $(cat "$out")"
fi

if cat "$work"/*/calls | grep -E -- '--force|(^| )-f( |$)|prune|rmi'; then
  fail "a call above carries a force flag or a prune"
else
  pass "no call carries a force flag or a prune"
fi

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed: stale core image tags go, pinned and newest stay.\n' "$PASSES"
