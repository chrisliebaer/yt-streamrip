FROM scratch as ASSEMBLER
COPY pipeline /pipeline
COPY desilence/desilence.py /pipeline/desilence.py

# as long as we don't need fancy ffmpeg builds, we can use the alpine image
FROM alpine

RUN apk add --no-cache \
	bash \
	curl \
	jq \
	python3 \
	ffmpeg

COPY --chmod=755 --from=ASSEMBLER /pipeline /opt/pipeline

# prepare user for running the pipeline and create directories so volumes have proper permissions
RUN addgroup -g 1000 pipeline && \
	adduser -D -u 1000 -G pipeline pipeline && \
	mkdir -p /opt/pipeline/workdir/archive_tmp && \
	mkdir -p /opt/pipeline/workdir/archive_done && \
	mkdir -p /opt/pipeline/workdir/convert_tmp && \
	mkdir -p /opt/pipeline/workdir/convert_done && \
	chown -R pipeline:pipeline /opt/pipeline/workdir

USER pipeline
WORKDIR /opt/pipeline/workdir

ENTRYPOINT ["/opt/pipeline/entrypoint.sh"]
