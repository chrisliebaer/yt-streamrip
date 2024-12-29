#!/bin/bash

set -e

# if an .env file is present, source it (for local development)
if [ -f .env ]; then
	# report error if file is stored with windows line endings
	if grep -q $'\r' .env; then
		echo "Error: .env file contains windows line endings, please convert it to unix line endings"
		exit 1
	fi

	echo "Sourcing .env file, do not use this in production"
	source .env
fi

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

YTARCHIVE_DOWNLOAD_LOCATION="${YTARCHIVE_DOWNLOAD_LOCATION:-downloads/tmp}"
YTARCHIVE_CLEANUP_DOWNLOADS="${YTARCHIVE_CLEANUP_DOWNLOADS:-false}"
YTARCHIVE_FINALIZED_LOCATION="${YTARCHIVE_FINALIZED_LOCATION:-downloads/final}"
YTARCHIVE_RETRY_INTERVAL="${YTARCHIVE_RETRY_INTERVAL:-300}"
YTARCHIVE_QUALITY="${YTARCHIVE_QUALITY:-best}"


INSTALL_LOCATION="${INSTALL_LOCATION:-/usr/local/bin}"
CURRENT_VERSION_FILE="${CURRENT_VERSION_FILE:-/ytarchive_version.txt}"
GITHUB_OWNER="${GITHUB_OWNER:-Kethsar}"
GITHUB_REPO="${GITHUB_REPO:-ytarchive}"

function send_discord_message() {
	if [ -z "$DISCORD_WEBHOOK_URL" ]; then
		# no webhook URL provided, do nothing
		return
	fi

	# print the message to stderr as well
	echo "$1" >&2

	# escape the message for JSON and embed it in a JSON object
	echo "$1" | jq -R --slurp '.' | jq --arg content "$1" '{content: $content}' | curl -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL"
}

function get_installed_version() {
	if [ ! -f "$CURRENT_VERSION_FILE" ]; then
		echo "0.0.0" > "$CURRENT_VERSION_FILE"
	fi

	cat "$CURRENT_VERSION_FILE"
}

function get_github_latest_release() {
	version=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/latest))
	echo "$version"
}

function install_from_archive() {
	if [ -z "$1" ]; then
		echo "No archive URL provided"
		exit 1
	fi

	mkdir -p "$INSTALL_LOCATION"

	archive_extension="${1##*.}"
	archive_file="/tmp/ytarchive.$archive_extension"

	echo "Downloading and installing ytarchive from $1"
	curl -Ls "$1" -o "$archive_file"

	case "$archive_extension" in
		zip)
			unzip -o "$archive_file" -d "$INSTALL_LOCATION"
			;;
		tar.gz)
			tar -xzf "$archive_file" -C "$INSTALL_LOCATION"
			;;
		*)
			echo "Unsupported archive format: $archive_extension"
			exit 1
			;;
	esac
}

function install_version_from_github() {
	if [ -z "$1" ]; then
		echo "No version provided"
		exit 1
	fi

	archive_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$1/ytarchive_linux_amd64.zip"
	install_from_archive "$archive_url"
}

function install_or_update_ytarchive() {
	mkdir -p "$INSTALL_LOCATION"
	mkdir -p "$(dirname "$CURRENT_VERSION_FILE")"

	latest_version=$(get_github_latest_release)
	installed_version=$(get_installed_version)

	if [ "$latest_version" != "$installed_version" ]; then
		echo "Updating ytarchive from $installed_version to $latest_version"
		install_version_from_github "$latest_version"
		echo "$latest_version" > "$CURRENT_VERSION_FILE"
	else
		echo "ytarchive is already up to date"
	fi
}

function watcher_loop() {

	ytarchive_args=(
		# always download entire VOD
		--live-from 0

		# mux into mkv instead of random bullshit
		--mkv

		# store staging files in different directory so they don't get picked up by other services
		--temporary-dir "$YTARCHIVE_DOWNLOAD_LOCATION"

		# keep monitoring for live streams (causes ytarchive to run forever)
		--monitor-channel
		--retry-stream "$YTARCHIVE_RETRY_INTERVAL"

		# output template is not very powerfull, but only way to use the atomic move semantic from ytarchive
		--output "$YTARCHIVE_FINALIZED_LOCATION/%(title)s(%(id)s)"

		# always finalize the download, even if interrupted
		--merge

		# prefer vp9, if available
		--vp9

		# if a livestream is announced, ignore it and retry later
		--no-wait
	)

	# if PROXY is set, add it to the ytarchive args
	if [ -n "$PROXY" ]; then
		echo "Picked up proxy $PROXY from environment, adding it to ytarchive args"
		ytarchive_args+=(--proxy "$PROXY")
	fi

	# WATCH_TARGET is required
	if [ -z "$WATCH_TARGET" ]; then
		echo "No WATCH_TARGET provided, exiting"
		exit 1
	fi

	# user can provide channel handle or live url via WATCH_TARGET
	# if WATCH_TARGET starts with "https://", assume it's a live URL
	if [[ "$WATCH_TARGET" == "https://"* ]]; then
		echo "Using live URL $WATCH_TARGET to monitor for live streams"
		ytarchive_args+=("$WATCH_TARGET")
	else
		# remove leading @, if present
		WATCH_TARGET="${WATCH_TARGET#@}"
		echo "Using channel handle @$WATCH_TARGET to monitor for live streams"
		ytarchive_args+=(https://www.youtube.com/@"$WATCH_TARGET"/live)
	fi

	# quality is provided by user
	echo "Using quality $YTARCHIVE_QUALITY"
	ytarchive_args+=("$YTARCHIVE_QUALITY")

	# print the ytarchive args for debugging
	echo "ytarchive args: ${ytarchive_args[@]}"

	# always sleep before entering the loop in case something triggers an error and we would start spaming services
	if [ "$DEV" != "true" ]; then
		echo "Sleeping for 30 seconds before starting the loop"
		sleep 30
	else
		echo "Skipping sleep because DEV is true"
	fi

	# check if ytarchive has an update
	if [ "$NO_INSTALL_OR_UPDATE" != "true" ]; then
		install_or_update_ytarchive
	else
		echo "Skipping install or update of ytarchive because NO_INSTALL_OR_UPDATE is set to true"
	fi
	ytarchive="${INSTALL_LOCATION}/ytarchive"

	# ensure ytarchive is properly installed
	if [ ! -x "$ytarchive" ]; then
		echo "ytarchive is not installed or not executable, exiting"
		exit 1
	fi

	# ensure download and finalized directories exist
	mkdir -p "$YTARCHIVE_DOWNLOAD_LOCATION"
	mkdir -p "$YTARCHIVE_FINALIZED_LOCATION"

	# if cleanup is enabled, remove lingering downloads from previous runs
	if [ "$YTARCHIVE_CLEANUP_DOWNLOADS" == "true" ]; then
		if [ -n "$YTARCHIVE_DOWNLOAD_LOCATION" ] && [ "$YTARCHIVE_DOWNLOAD_LOCATION" != "/" ]; then
			echo "Cleaning up downloads from previous runs"
			rm -rf "$YTARCHIVE_DOWNLOAD_LOCATION"/*
		else
			echo "Error: YTARCHIVE_DOWNLOAD_LOCATION is not set or is root directory, refusing to clean up"
			exit 1
		fi
	fi

	# ytarchive is going to run forever and needs to respond to signals, so we exec it
	# this will also get rid of our traps, but I don't have a better solution right now
	exec $ytarchive "${ytarchive_args[@]}"
}


# trap any errors and send them to discord
trap 'send_discord_message "ytarchive watcher encountered an unexpected error code \`$?\` running \`$BASH_COMMAND\`
caller context:
\`\`\`
$(caller)\`\`\`"' ERR

watcher_loop
