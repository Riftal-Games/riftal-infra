# The `backup` service's image. backup.sh tests each instance's server.lock
# with util-linux flock (ADR 015 item 6), which mysql:8 does not carry, beside
# mysqldump, GNU tar and find. util-linux is essential on the base, so only the
# MySQL client is installed.
FROM ubuntu:24.04

# Ubuntu drops a superseded package version from its archive, so an exact pin
# stops this building at the next security release. The image tag is the pin.
# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends mysql-client \
  && rm -rf /var/lib/apt/lists/*
