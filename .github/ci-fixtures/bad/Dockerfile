# Expected: hadolint fails. An unpinned base makes a rebuild non-reproducible,
# which is the opposite of "deploy by immutable tag", and the apt line leaves
# the package lists in the layer.
FROM ubuntu:latest

RUN apt-get update && apt-get install curl
