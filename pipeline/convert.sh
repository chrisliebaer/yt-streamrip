#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DESILENCE_PY="${DESILENCE_PY:-$SCRIPT_DIR/desilence.py}"
DO_DESILENCE="${DO_DESILENCE:-true}"

# figure out if it's python or python3
PYTHON="python"
if command -v python3 &>/dev/null; then
	PYTHON="python3"
fi

# we use string with placeholders for ffmpeg command and evaluate it for each file
FFMPEG_ENCODER_CMDS="${FFMPEG_ENCODER_CMDS:-"-i \"\$cmd_in\" -c:v libx264 -crf 23 -preset veryfast -c:a libopus -b:a 96k -y \"\$cmd_out\""}"

function cleanup_tmp_files() {
	rm -rf "${DIR_CONVERT_TMP:?}"/*
}

# shellcheck disable=SC2034
function ffmpeg_encode() {
	tmp_output="$DIR_CONVERT_TMP/ffmpeg_encode.XXXXXX.mkv"
	rm -f "$tmp_output"
	cmd_in="$1"
	cmd_out="$tmp_output"

	# shellcheck disable=SC2086
	eval ffmpeg ${FFMPEG_ENCODER_CMDS}
	export stage_input="$tmp_output"
}

function desilence_file() {
	tmp_output="$DIR_CONVERT_TMP/desilenced.XXXXXX.mkv"
	rm -f "$tmp_output"
	$PYTHON "$DESILENCE_PY" --copy-instead -i "$1" -o "$tmp_output"
	export stage_input="$tmp_output"
}

function handle_new_file() {
	file="$1"
	filename=$(basename "$file")

	# resolve target file path, which is always in mkv format
	target_file="$DIR_CONVERT_DONE/${filename%.*}.mkv"

	# if target file does not exist, process it
	if [ ! -f "$target_file" ]; then

		# store the input file for the next stage
		export stage_input="$file"

		# desilence goes first
		if [ "$DO_DESILENCE" = true ]; then
			desilence_file "$stage_input"
		fi

		# run ffmpeg for compression
		if [ -n "$FFMPEG_ENCODER_CMDS" ]; then
			ffmpeg_encode "$stage_input"
		fi

		# move to final location is two steps to avoid partial files
		# first move as .tmp file, then rename to final name (atomic, hopefully)
		mv "$stage_input" "$target_file.tmp"
		mv "$target_file.tmp" "$target_file"

		cleanup_tmp_files

		send_discord_message "Completed processing of $filename (size: $(du -h "$target_file" | cut -f1))"
	else
		echo "File already exists: $target_file"
	fi

	cleanup_tmp_files

	# delete original file if requested
	if [ "$DELETE_ORIGINAL" = true ]; then
		rm "$file"
	fi
}

function watch_dir() {
	echo "Watching $DIR_ARCHIVE_DONE for new files every $WATCH_INTERVAL..."
	while [ "$DO_WORK" = true ]; do
		cleanup_tmp_files

		for file in "$DIR_ARCHIVE_DONE"/*.{mkv,mp4,webm}; do
			if [ -f "$file" ]; then
				send_discord_message "New file detected: $(basename "$file")"
				handle_new_file "$file"
			fi
		done

		if [ "$DO_WORK" = true ]; then
			sleep "$WATCH_INTERVAL"
		fi
	done
}

watch_dir
