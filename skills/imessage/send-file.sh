#!/bin/bash

# Send a file via iMessage
# Usage: ./send-file.sh <recipient> <file_path>
#
# NOTE: macOS Messages can only send files from within its own directory
# (~/Library/Messages/Attachments/). Files from other locations fail silently
# with error 25. This script stages files there before sending.

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <recipient> <file_path>"
    echo "Example: $0 '+1234567890' '/path/to/image.jpg'"
    exit 1
fi

RECIPIENT="$1"
FILE_PATH="$2"

# Verify file exists
if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File not found: $FILE_PATH"
    exit 1
fi

# Get absolute path
ABS_PATH=$(cd "$(dirname "$FILE_PATH")" && pwd)/$(basename "$FILE_PATH")

# Copy file into Messages' attachments directory so it can access it
# Messages sandboxes file access — files outside its directory fail with error 25
STAGING_DIR="$HOME/Library/Messages/Attachments/_outgoing"
mkdir -p "$STAGING_DIR"
STAGED_FILE="$STAGING_DIR/$(basename "$ABS_PATH")"
cp "$ABS_PATH" "$STAGED_FILE"

# Send file via AppleScript
osascript <<EOF
set fileToSend to POSIX file "$STAGED_FILE"
tell application "Messages"
    set targetService to 1st account whose service type = iMessage
    set targetBuddy to participant "$RECIPIENT" of targetService
    send fileToSend to targetBuddy
end tell
EOF

if [ $? -eq 0 ]; then
    echo "File sent successfully: $ABS_PATH"
else
    # Clean up staged file on failure
    rm -f "$STAGED_FILE" 2>/dev/null
    echo "Error: Failed to send file"
    exit 1
fi
