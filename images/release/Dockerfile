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
# The runtime user pocketmine owns neither the phars nor their directories, so
# it can neither rewrite nor replace a phar: a replacement would survive a
# restart in the container's writable layer and the tag would stop deciding
# which build runs. The phars' mode 0444 is set in the build context by
# deploy/release-image.sh, and the directory modes are fixed here so the umask
# of whoever built the image does not decide them.
COPY --chown=0:0 plugins/ /opt/riftal/plugins/
USER root
RUN chmod 0755 /opt/riftal /opt/riftal/plugins
USER pocketmine
