#!/bin/bash

set -e
set -o pipefail
set -o errtrace  # Ensure traps are inherited by functions and sourced scripts

# if an .env file is present, source it (for local development)
if [ -f .env ]; then
	# report error if file is stored with windows line endings
	if grep -q $'\r' .env; then
		echo "Error: .env file contains windows line endings, please convert it to unix line endings"
		exit 1
	fi

	echo "Sourcing .env file, do not use this in production"
	# shellcheck disable=SC1091
	source .env
fi

# trap any errors and send them to discord
trap 'send_discord_message "ytarchive watcher encountered an unexpected error code \`$?\` running \`$BASH_COMMAND\`
caller context:
\`\`\`
$(caller)\`\`\`"' ERR

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# shared configuration variables
export DEV="${DEV:-false}"
export DELETE_ORIGINAL="${DELETE_ORIGINAL:-true}"
export DIR_BASE="${DIR_BASE:-/opt/pipeline/workdir}"
export DIR_ARCHIVE_TMP="${DIR_ARCHIVE_TMP:-${DIR_BASE}/archive_tmp}"
export DIR_ARCHIVE_DONE="${DIR_ARCHIVE_DONE:-${DIR_BASE}/archive_done}"
export DIR_CONVERT_TMP="${DIR_CONVERT_TMP:-${DIR_BASE}/convert_tmp}"
export DIR_CONVERT_DONE="${DIR_CONVERT_DONE:-${DIR_BASE}/convert_done}"
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

export YTARCHIVE_INSTALL_DIR="${DIR_BASE}/ytarchive"
export YTARCHIVE_VERSION_FILE="${DIR_BASE}/ytarchive_version.txt"

export WATCH_INTERVAL="${WATCH_INTERVAL:-5m}"

# Setup logging
export LOG_FILE="/tmp/pipeline.log"
touch "$LOG_FILE"
# Redirect stdout and stderr to the log file, while also keeping them on stdout/stderr
exec > >(tee -a "$LOG_FILE") 2>&1

function make_dirs() {
	mkdir -p "$DIR_BASE"
	mkdir -p "$DIR_ARCHIVE_TMP"
	mkdir -p "$DIR_ARCHIVE_DONE"
	mkdir -p "$DIR_CONVERT_TMP"
	mkdir -p "$DIR_CONVERT_DONE"
	mkdir -p "$YTARCHIVE_INSTALL_DIR"
}

# whenever we run a child process, we need to pass signals to it as well
# we assume that the child pid is stored in the variable $_CHILD_PID
export _CHILD_PID=""
export DO_WORK=true
function signal_handler() {
	echo "Received signal $1, stopping..."

	# signal to loop to exit at the next iteration
	export DO_WORK=false

	if [ -z "$_CHILD_PID" ]; then
		return
	fi

	# $1 is the signal to pass
	if kill -s "$1" "$_CHILD_PID" 2>/dev/null; then
		echo "Passing signal $1 to child process $_CHILD_PID"

		# we now need to wait for the child process to exit
		wait "$_CHILD_PID"
	else
		echo "Child process $_CHILD_PID not found, skipping signal $1"
	fi
}

# install trap for all relevant signals
trap 'signal_handler SIGINT' INT
trap 'signal_handler SIGTERM' TERM
trap 'signal_handler SIGHUP' HUP

function send_discord_message() {
	echo "Sending discord message: $1" >&2
	if [ -z "$DISCORD_WEBHOOK_URL" ]; then
		# no webhook URL provided, do nothing
		return
	fi

	# print the message to stderr as well
	echo "$1" >&2

	# escape the message for JSON and embed it in a JSON object
	echo "$1" | jq -R --slurp '.' | jq --arg content "$1" '{content: $content}' | curl -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL"
}

if [ -z "$1" ]; then
	echo "Usage: $0 <script>"
	exit 1
fi

make_dirs

function handle_error() {
	local exit_code="${1:-$?}"
	local cmd="${2:-$BASH_COMMAND}"
	# Truncate cmd
	cmd=$(echo "$cmd" | head -c 200)
	
	send_discord_message "ytarchive watcher encountered an unexpected error code \`$exit_code\` running \`$cmd\`
caller context:
\`\`\`
$(caller)\`\`\`
Last 20 lines of log:
\`\`\`
$(tail -n 20 "$LOG_FILE" | sed "s/\`/'\''/g" | head -c 1000)
\`\`\`"
}

# trap any errors and send them to discord
trap 'handle_error' ERR

# source instead of running, to keep scope and trap handlers
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/$1.sh"
