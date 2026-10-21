# The release image: the pinned core image, which is ubuntu:24.04 underneath
# (hard rule 7), plus the plugin phars. deploy/release-image.sh builds it and
# names the tag.
# The tag is its own argument and its default names a tag that does not exist,
# so a build that is not given the pinned image fails instead of taking whatever
# local-pocketmine-mp was built last.
ARG CORE_REPO=local-pocketmine-mp
ARG CORE_TAG=pin-required
FROM ${CORE_REPO}:${CORE_TAG}

# The base declares /plugins a VOLUME and runs as pocketmine (uid 1000). Files
# copied in are kept in the layer, and a container started without a mount on
# /plugins gets them copied into its fresh volume. start.sh prints a warning at
# every boot for files not owned by that user and carries on.
COPY --chown=1000:1000 plugins/ /plugins/
