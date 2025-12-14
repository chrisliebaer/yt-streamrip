#!/bin/bash

set -e
set -o pipefail

DESILENCE_RS="${DESILENCE_RS:-desilence-rs}"
DO_DESILENCE="${DO_DESILENCE:-true}"

# ffmpeg encoding options (input and output files are handled automatically)
# We trim whitespace/newlines from the variable to avoid eval issues
FFMPEG_ENCODE_OPTS="${FFMPEG_ENCODE_OPTS:--c:v libx264 -crf 23 -preset veryfast -c:a libopus -b:a 96k}"
FFMPEG_ENCODE_OPTS="$(echo "$FFMPEG_ENCODE_OPTS" | tr -d '\n')"

function cleanup_tmp_files() {
	rm -rf "${DIR_CONVERT_TMP:?}"/*
}

# shellcheck disable=SC2034
function ffmpeg_encode() {
	local input_file="$1"
	local output_file="$DIR_CONVERT_TMP/ffmpeg_encode.XXXXXX.mkv"
	rm -f "$output_file"

	# Build desilence arguments
	local desilence_args=""
	if [ -n "$DESILENCE_NOISE_THRESHOLD" ]; then
		desilence_args="$desilence_args --noise-threshold $DESILENCE_NOISE_THRESHOLD"
	fi
	if [ -n "$DESILENCE_DURATION" ]; then
		desilence_args="$desilence_args --duration $DESILENCE_DURATION"
	fi

	echo "Starting encoding for $input_file"
	if [ "$DO_DESILENCE" = true ]; then
		# Check if desilence-rs is available
		if ! command -v "$DESILENCE_RS" &> /dev/null; then
			echo "Error: $DESILENCE_RS not found in PATH"
			exit 1
		fi
		echo "Using $DESILENCE_RS version: $($DESILENCE_RS --version)"

		# Pipe: desilence-rs -> ffmpeg
		# We use eval to properly handle quotes in FFMPEG_ENCODE_OPTS
		local cmd="$DESILENCE_RS --ignore-no-silence -i \"$input_file\" $desilence_args | ffmpeg -f nut -i pipe: $FFMPEG_ENCODE_OPTS -y \"$output_file\""
		echo "Executing: $cmd"
		
		# Temporarily disable set -e to avoid bash 'pop_var_context' bug when sourcing
		set +e
		# Use if ! eval to suppress automatic ERR trap for the command inside eval
		if ! eval "$cmd"; then
			local ret=$?
			echo "Command failed with exit code $ret"
			handle_error "$ret" "$cmd"
			exit 1
		fi
		set -e
	else
		# Direct: ffmpeg
		local cmd="ffmpeg -i \"$input_file\" $FFMPEG_ENCODE_OPTS -y \"$output_file\""
		echo "Executing: $cmd"
		
		# Temporarily disable set -e to avoid bash 'pop_var_context' bug when sourcing
		set +e
		# Use if ! eval to suppress automatic ERR trap for the command inside eval
		if ! eval "$cmd"; then
			local ret=$?
			echo "Command failed with exit code $ret"
			handle_error "$ret" "$cmd"
			exit 1
		fi
		set -e
	fi

	if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
		echo "Error: Encoding failed, output file is missing or empty"
		exit 1
	fi

	export stage_input="$output_file"
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

		# run ffmpeg for compression
		if [ -n "$FFMPEG_ENCODE_OPTS" ]; then
			ffmpeg_encode "$stage_input"
		else
			echo "Skipping encoding (FFMPEG_ENCODE_OPTS is empty)"
		fi

		# move to final location is two steps to avoid partial files
		# first move as .tmp file, then rename to final name (atomic, hopefully)
		# Note: mv might warn about ownership preservation on some docker volumes, but the operation succeeds.
		mv "$stage_input" "$target_file.tmp"
		mv "$target_file.tmp" "$target_file"

		cleanup_tmp_files

		send_discord_message "Completed processing of $filename (size: $(du -h "$target_file" | cut -f1))"
	else
		echo "File already exists: $target_file"
	fi

	cleanup_tmp_files

	# delete original file if requested
	# Note: If encoding was skipped, stage_input was the original file, so it was moved above.
	# We check -f to avoid failing if the file is already gone.
	if [ "$DELETE_ORIGINAL" = true ] && [ -f "$file" ]; then
		rm "$file"
	fi
}

function watch_dir() {
	echo "Watching $DIR_ARCHIVE_DONE for new files every $WATCH_INTERVAL..."
	while [ "$DO_WORK" = true ]; do
		cleanup_tmp_files
		# Clear log file for the new iteration
		: > "$LOG_FILE"

		for file in "$DIR_ARCHIVE_DONE"/*.{mkv,mp4,webm}; do
			if [ -f "$file" ]; then
				echo "New file detected: $(basename "$file")"
				handle_new_file "$file"
			fi
		done

		if [ "$DO_WORK" = true ]; then
			sleep "$WATCH_INTERVAL"
		fi
	done
}

watch_dir
