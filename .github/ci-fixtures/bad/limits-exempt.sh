# Must fail container-limits.sh at each malformed or unused exemption, and past an exemption's first report.
# container-limits: exempt
docker run -m 1g --cpus 1 alpine
# container-limits: keep a service
docker run -m 1g --cpus 1 alpine
# container-limits: exempt over a launch that needs none
docker run -m 1g --cpus 1 alpine
# container-limits: exempt over a blank line

# container-limits: exempt over a comment
# a comment
docker run -m 1g --cpus 1 alpine
# container-limits: exempt the first launch only
docker run --cpus 1 alpine; docker run -m 1g alpine
# container-limits: exempt at the end of the file
