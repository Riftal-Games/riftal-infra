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
# outside both. Everything under /opt/riftal belongs to root and has no write
# bit, so the process that loads the phars cannot replace one or add another.
# start-release.sh builds the instance's roster from this path and passes it to
# PocketMine, which makes the image tag decide which build runs.
USER root
COPY plugins/ /opt/riftal/plugins/
COPY plugin_data/ /opt/riftal/plugin_data/
COPY start-release.sh /opt/riftal/start-release.sh
RUN chmod -R a-w /opt/riftal && chmod a+x /opt/riftal/start-release.sh
USER pocketmine

CMD ["/opt/riftal/start-release.sh"]
