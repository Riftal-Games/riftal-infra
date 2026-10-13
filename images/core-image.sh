# Sourced, never run. Every check that boots the core image takes its tag from
# core_image and from nowhere else (riftal-infra#363).
#
# pmmp-core's Docker image CI tags local-pocketmine-mp:<full riftal sha> on
# the self-hosted runners' shared Docker daemon once a push run of riftal
# passes its smoke steps. core-image.sha beside this file names the one these
# checks run, so a change to what they test is a commit here. The bare tag is
# whatever was built last on that daemon, so it is never a fallback, and
# nothing here pulls: the tag exists only on that daemon.

# $1 the sha file, core-image.sha beside this script when omitted. Sets
# CORE_IMAGE to the pinned tag, or prints an ::error:: and returns 1 when the
# file is malformed or the tag is not on this daemon.
core_image() {
  local file="${1:-$(dirname "${BASH_SOURCE[0]}")/core-image.sha}" sha tag
  CORE_IMAGE=
  if ! sha="$(tr -d '[:space:]' < "$file")"; then
    printf '::error::cannot read the pinned core image sha from %s\n' "$file"
    return 1
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf '::error::%s holds "%s", not a full 40-character pmmp-core sha\n' "$file" "$sha"
    return 1
  fi
  tag="local-pocketmine-mp:$sha"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    printf '::error::pinned core image %s is not on this Docker daemon; a push run of pmmp-core riftal at that sha tags it\n' "$tag"
    return 1
  fi
  CORE_IMAGE="$tag"
}
