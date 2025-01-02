#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

YTARCHIVE_QUALITY="${YTARCHIVE_QUALITY:-best}"
GITHUB_OWNER="${GITHUB_OWNER:-Kethsar}"
GITHUB_REPO="${GITHUB_REPO:-ytarchive}"


function get_installed_version() {
	if [ ! -f "$YTARCHIVE_VERSION_FILE" ]; then
		echo "0.0.0" > "$YTARCHIVE_VERSION_FILE"
	fi

	cat "$YTARCHIVE_VERSION_FILE"
}

function get_github_latest_release() {
	version=$(basename "$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/latest)")
	echo "$version"
}

function install_from_archive() {
	if [ -z "$1" ]; then
		echo "No archive URL provided"
		exit 1
	fi

	archive_extension="${1##*.}"
	archive_file="/tmp/ytarchive.$archive_extension"

	echo "Downloading and installing ytarchive from $1"
	curl -Ls "$1" -o "$archive_file"

	case "$archive_extension" in
		zip)
			unzip -o "$archive_file" -d "$YTARCHIVE_INSTALL_DIR"
			;;
		tar.gz)
			tar -xzf "$archive_file" -C "$YTARCHIVE_INSTALL_DIR"
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
	latest_version=$(get_github_latest_release)
	installed_version=$(get_installed_version)

	if [ "$latest_version" != "$installed_version" ]; then
		echo "Updating ytarchive from $installed_version to $latest_version"
		install_version_from_github "$latest_version"
		echo "$latest_version" > "$YTARCHIVE_VERSION_FILE"
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

		# keep monitoring for live streams (causes ytarchive to run forever)
		# we can't use this, because ytarchive will move all files to the finalized location, before merging
		# this creates a situation during which partially written files become visible to other services
		##--monitor-channel
		##--retry-stream "$WATCH_INTERVAL"
		#--temporary-dir "$DIR_ARCHIVE_TMP"

		# output template is not very powerfull, but we can rename the file later
		--output "$DIR_ARCHIVE_TMP/%(title)s(%(id)s)"

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
	echo "ytarchive args: ${ytarchive_args[*]}"

	# always sleep before entering the loop in case something triggers an error and we would start spaming services
	if [ "$DEV" != "true" ]; then
		echo "Sleeping for 30 seconds before starting the loop"
		sleep 30
	else
		echo "Skipping sleep because DEV is true"
	fi

	# if cleanup is enabled, remove lingering downloads from previous runs
	if [ "$DELETE_ORIGINAL" == "true" ]; then
		rm -rf "${DIR_ARCHIVE_TMP:?}"/*
	fi

	# do periodic updates of ytarchive and keep track of last time we checked
	LAST_UPDATE_CHECK="0"

	# since the monitoring feature of ytarchive is unsuitable for our use case, we need to run ytarchive in a loop
	while [ "$DO_WORK" = true ]; do

		# if more than a day has passed since the last update check, check for updates
		if [ $(( $(date +%s) - LAST_UPDATE_CHECK )) -gt 86400 ]; then
			echo "Haven't checked for updates for ytarchive in over a day, checking now"

			# check if ytarchive has an update
			if [ "$NO_INSTALL_OR_UPDATE" != "true" ]; then
				install_or_update_ytarchive
			else
				echo "Skipping install or update of ytarchive because NO_INSTALL_OR_UPDATE is set to true"
			fi
			ytarchive="${YTARCHIVE_INSTALL_DIR}/ytarchive"
			LAST_UPDATE_CHECK=$(date +%s)
		fi

		# ytarchive always reports an error if there is no livestream, making it's exit code unusable
		$ytarchive "${ytarchive_args[@]}" &
		export _CHILD_PID=$!

		# wait for process to finish (ignore exit code, since it's unusable)
		if wait $_CHILD_PID; then
			echo "ytarchive exited cleanly, new live stream recorded"
		else
			echo "ytarchive exited with an error, waiting $WATCH_INTERVAL seconds before retrying"
		fi
		
		# move all files from the download location to the finalized location (filter for relevant extensions)
		# if we would have to move files cross-device, we would have to copy them instead
		# we don't want other services to pick up partially written files, so we move them to a temporary name first
		for file in "$DIR_ARCHIVE_TMP"/*.{mkv,webm,mp4}; do
			if [ -f "$file" ]; then
				base_file="$(basename "$file")"

				# read creation time of the file and use as prefix for the target file in format YYYYMMDD-HHMMSS
				creation_epoch=$(stat -c %Y "$file")
				creation_date=$(date -d "@$creation_epoch" +%Y%m%d-%H%M%S)

				target_file="$DIR_ARCHIVE_DONE/${creation_date}_${base_file}"

				# move the file to a temporary name
				mv "$file" "$target_file.tmp"

				# then rename the file to remove the .tmp extension
				mv "$target_file.tmp" "$target_file"

				echo "finished new stream recording: $base_file"
				send_discord_message "Finished new stream recording for channel @$WATCH_TARGET: $base_file (size: $(du -h "$target_file" | cut -f1))"
			fi
		done

		if [ "$DO_WORK" = true ]; then
			sleep "$WATCH_INTERVAL"
		fi
	done
}


watcher_loop
