#!/bin/sh
# Runs the designer suite inside a container.
#
# The project is mounted read-only and the environment lives at
# UV_PROJECT_ENVIRONMENT inside the container. A uv environment written into a
# bind-mounted project is a Linux one, with a lib64 symlink and a pyvenv.cfg
# pointing at a container interpreter, and uv on a Windows checkout then fails
# on it with "Access is denied" instead of rebuilding it.
#
# CONTAINER_ENGINE names any runtime taking docker's run flags. Extra
# arguments go to pytest.
set -eu

engine="${CONTAINER_ENGINE:-docker}"
image="${DESIGNER_TEST_IMAGE:-python:3.12-alpine}"
# Matches the uv that CI's setup-uv step installs.
uv_version="0.12.0"
project="$(cd "$(dirname "$0")" && pwd)"

# The mount keeps the checkout's depth: the fragment tests look for a sibling
# riftal-game three levels above a test file, and skip when it is absent.
workdir=/src/riftal-infra/designer

# Expanded by the container's shell, which receives the uv version as $0.
# shellcheck disable=SC2016
inner='
  set -eu
  pip install --quiet --disable-pip-version-check --root-user-action=ignore "uv==$0"
  uv sync --locked --group dev
  uv run --frozen pytest -q -p no:cacheprovider "$@"
'

exec "$engine" run --rm -m 1g --cpus 1 \
  -v "$project:$workdir:ro" \
  -w "$workdir" \
  -e UV_PROJECT_ENVIRONMENT=/opt/designer-venv \
  -e UV_CACHE_DIR=/tmp/uv-cache \
  -e PYTHONDONTWRITEBYTECODE=1 \
  "$image" \
  sh -c "$inner" "$uv_version" "$@"
