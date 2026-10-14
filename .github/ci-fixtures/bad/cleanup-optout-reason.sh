#!/usr/bin/env bash
# Must fail container-cleanup.sh: the opt-out ends in a space and a tab and
# gives no reason.
# container-cleanup: keep 	 
docker run --rm mysql:8 true
