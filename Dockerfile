# as long as we don't need fancy ffmpeg builds, we can use the alpine image
FROM alpine

RUN apk add --no-cache \
	bash \
	curl \
	jq \
	ffmpeg

# these are defaults more suitable for a container
ENV YTARCHIVE_DOWNLOAD_LOCATION="/downloads/tmp"
ENV YTARCHIVE_FINALIZED_LOCATION="/downloads/final"
ENV YTARCHIVE_CLEANUP_DOWNLOADS="true"

COPY --chmod=755 entrypoint.sh /entrypoint.sh

# TODO: create less privileged user (and make sure ids can be set via env vars)
# TODO: requires writeable location for binary and version file

ENTRYPOINT ["/entrypoint.sh"]
