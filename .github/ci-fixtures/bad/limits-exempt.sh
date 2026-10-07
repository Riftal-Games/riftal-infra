# Must fail container-limits.sh at each malformed or unused exemption, and at each launch none excuses.
# container-limits: exempt
docker run -m 1g --cpus 1 alpine
# container-limits: keep a service
docker run --rm alpine
# container-limits: exempt over a launch that needs none
docker run -m 1g --cpus 1 alpine
# container-limits: exempt over a blank line

# container-limits: exempt over a comment
# a comment
docker run --rm alpine
# container-limits: exempt the next line only
docker run --rm alpine
docker run --rm alpine
#container-limits: exempt unspaced
docker ps
# container-limits: exempt at the end of the file
