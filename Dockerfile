FROM scratch AS assembler
COPY pipeline /pipeline

# --- ytarchive stage (Alpine) ---
FROM alpine:latest AS ytarchive

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    ffmpeg \
    unzip \
    coreutils

COPY --from=assembler /pipeline /opt/pipeline
RUN chmod -R 755 /opt/pipeline

RUN addgroup -g 1000 pipeline && \
    adduser -u 1000 -G pipeline -D pipeline && \
    mkdir -p /opt/pipeline/workdir/archive_tmp && \
    mkdir -p /opt/pipeline/workdir/archive_done && \
    mkdir -p /opt/pipeline/workdir/convert_tmp && \
    mkdir -p /opt/pipeline/workdir/convert_done && \
    chown -R pipeline:pipeline /opt/pipeline/workdir

USER pipeline
WORKDIR /opt/pipeline/workdir
ENTRYPOINT ["/opt/pipeline/entrypoint.sh"]

# --- converter stage (Ubuntu) ---
# ubuntu to support glibc-linked binaries (like desilence-rs)
FROM ubuntu:24.04 AS converter

RUN apt-get update && apt-get install -y \
	curl \
	jq \
	ffmpeg \
	unzip \
	&& rm -rf /var/lib/apt/lists/*

# Download desilence-rs
RUN curl -s https://api.github.com/repos/chrisliebaer/desilence-rs/releases/latest \
	| jq -r '.assets[] | select(.name == "desilence-rs-linux-static-x86_64") | .browser_download_url' \
	| xargs curl -L -o /usr/local/bin/desilence-rs \
	&& chmod +x /usr/local/bin/desilence-rs

COPY --from=assembler /pipeline /opt/pipeline
RUN chmod -R 755 /opt/pipeline

# prepare user for running the pipeline and create directories so volumes have proper permissions
# Remove default ubuntu user (uid 1000) to avoid conflict
RUN (userdel -r ubuntu || true) && \
	groupadd -g 1000 pipeline && \
	useradd -u 1000 -g pipeline -m pipeline && \
	mkdir -p /opt/pipeline/workdir/archive_tmp && \
	mkdir -p /opt/pipeline/workdir/archive_done && \
	mkdir -p /opt/pipeline/workdir/convert_tmp && \
	mkdir -p /opt/pipeline/workdir/convert_done && \
	chown -R pipeline:pipeline /opt/pipeline/workdir

USER pipeline
WORKDIR /opt/pipeline/workdir

ENTRYPOINT ["/opt/pipeline/entrypoint.sh"]
