docker run -d --name riftal_smoke_fixture mysql:8
# Must fail container-cleanup.sh at lines 1 and 5. Line 1 is the unkept run
# and there is no shebang above it, so in a scan of two copies the first
# copy's trailing opt-out meets the second copy's run with nothing between.
# container-cleanup: keep a long-lived service
