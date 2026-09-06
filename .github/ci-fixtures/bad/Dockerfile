# Expected: hadolint DL3007, and nothing else. An unpinned base makes a rebuild
# non-reproducible, which is the opposite of "deploy by immutable tag".
#
# One defect only. A fixture that trips several rules at once stays red when the
# rule it was written for is switched off, so it stops pinning anything.
FROM ubuntu:latest

CMD ["/bin/bash"]
