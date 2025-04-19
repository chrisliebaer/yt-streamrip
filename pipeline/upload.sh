#!/bin/bash

set -e

REQUIRED_VARS="WEBDAV_HOST WEBDAV_USER WEBDAV_PASS"
for var in $REQUIRED_VARS; do
	if [ -z "${!var}" ]; then
		echo "Error: $var is not set"
		exit 1
	fi
done

# remove trailing slash from host, if present
WEBDAV_HOST=${WEBDAV_HOST%/}

# small sleep in case path does exist, and we spam the server
sleep "$WATCH_INTERVAL"

# watch for new files passing through the pipeline
while [ "$DO_WORK" = true ]; do
	for file in "$DIR_CONVERT_DONE"/*.{mkv,mp4,webm}; do
		if [ -f "$file" ]; then
			filename=$(basename "$file")

			# urlencoding is difficult in bash, so we encode every character to ensure it's safe
			filename_encoded="$(echo -n "$filename" | jq -sRr @uri)"
			filename_encoded=$(echo "$filename_encoded" | tr -d '[:space:]')
			
			# upload as .tmp file, then rename when upload is complete
			echo "Uploading $filename... via webdav"
			curl --fail-with-body -T "$file" -u "$WEBDAV_USER:$WEBDAV_PASS" "$WEBDAV_HOST/$filename_encoded.tmp"

			# rename file to remove .tmp extension
			echo "Renaming $filename.tmp to $filename"
			curl --fail-with-body -X MOVE -u "$WEBDAV_USER:$WEBDAV_PASS" "$WEBDAV_HOST/$filename_encoded.tmp" --header "Destination: $WEBDAV_HOST/$filename_encoded"

			# delete original file if requested
			if [ "$DELETE_ORIGINAL" = true ]; then
				rm "$file"
			fi

			send_discord_message "Uploaded $filename for your pleasure"
		fi
	done

	# wait for the next iteration
	sleep "$WATCH_INTERVAL"
done
