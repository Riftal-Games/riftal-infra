# The release image: the pinned core image, which is ubuntu:24.04 underneath
# (hard rule 7), plus the production plugin phars, the built zones and the world
# index. deploy/release-image.sh builds it and names the tag.
# The tag is its own argument and its default names a tag that does not exist,
# so a build that is not given the pinned image fails instead of taking whatever
# local-pocketmine-mp was built last.
ARG CORE_REPO=local-pocketmine-mp
ARG CORE_TAG=pin-required
FROM ${CORE_REPO}:${CORE_TAG}

# The base declares /data and /plugins as VOLUMEs, and a mount or a reused
# volume there hides or outlives what the image holds, so the phars live
# outside both. start-release.sh builds the instance's roster from this path
# and passes it to PocketMine, which makes the image tag decide which build
# runs; core's start-pocketmine hard-codes --plugins=/plugins and is not used.
# The runtime user pocketmine owns neither the phars, the configs, the start
# script nor their directories, so it can replace none of them: a replacement
# would survive a restart in the container's writable layer and the tag would
# stop deciding which build runs. The file modes are set in the build context by
# deploy/release-image.sh, and the directory modes are set here so the umask
# of whoever built the image does not decide them.
# /etc/riftal holds the world index and every built zone, and /opt/riftal/boot
# the scripts start-release.sh runs and the digest list it checks them against,
# under the same ownership.
COPY --chown=0:0 plugins/ /opt/riftal/plugins/
COPY --chown=0:0 plugin_data/ /opt/riftal/plugin_data/
COPY --chown=0:0 start-release.sh /opt/riftal/start-release.sh
COPY --chown=0:0 boot/ /opt/riftal/boot/
COPY --chown=0:0 etc/ /etc/riftal/
USER root
RUN chmod 0755 /opt/riftal /opt/riftal/plugins /opt/riftal/plugin_data /opt/riftal/plugin_data/* \
 && find /etc/riftal /opt/riftal/boot -type d -exec chmod 0755 {} +
USER pocketmine

CMD ["/opt/riftal/start-release.sh"]
