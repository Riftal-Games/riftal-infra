#!/bin/bash
# Runs ahead of each instance's start script and stops the boot when
# RiftalCustody.phar is not built, then execs the command it was given. An
# instance without RiftalCustody writes item entities into its chunk saves and
# lets players fill tiles (ADR 013 item 11, riftal-pm
# docs/decisions/013-item-yielding-entities-are-never-saved.md). Both instances
# load every plugin at the top of /plugins, so the phar here is in each roster:
# instance-b reads /plugins directly and start-instance.sh copies it.
set -euo pipefail

phar=/plugins/RiftalCustody.phar
if [ ! -s "$phar" ]; then
	echo "$phar is not built; every instance loads RiftalCustody (ADR 013). See images/README.md, RiftalCustody." >&2
	exit 1
fi

exec "$@"
