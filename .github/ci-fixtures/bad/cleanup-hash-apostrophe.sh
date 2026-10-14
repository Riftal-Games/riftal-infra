#!/usr/bin/env bash
# Must fail container-cleanup.sh: an apostrophe in a here-document body opens
# no quote, so the run after the body is a command.
cat <<'EOF'
don't # x
EOF
docker run -d mysql:8
