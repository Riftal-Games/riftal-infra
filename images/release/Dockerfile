# The release image: the pinned core image, which is ubuntu:24.04 underneath
# (hard rule 7), plus the production plugin phars. deploy/release-image.sh
# builds it and names the tag.
# The tag is its own argument and its default names a tag that does not exist,
# so a build that is not given the pinned image fails instead of taking whatever
# local-pocketmine-mp was built last.
ARG CORE_REPO=local-pocketmine-mp
ARG CORE_TAG=pin-required
FROM ${CORE_REPO}:${CORE_TAG}

# The base declares /data and /plugins as VOLUMEs, and a mount or a reused
# volume there hides or outlives what the image holds, so the phars live
# outside both. Core's start-pocketmine hard-codes --plugins=/plugins and does
# not read this path: nothing in this image starts from it yet.
COPY --chown=1000:1000 plugins/ /opt/riftal/plugins/
