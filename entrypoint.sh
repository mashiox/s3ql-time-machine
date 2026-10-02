#!/bin/bash
set -e

echo "Starting S3QL Time Machine Container..."

# FUSE requires the /dev/fuse device node
if [ ! -c /dev/fuse ]; then
  echo "Error: /dev/fuse not found. Ensure you run this container with --device /dev/fuse and --cap-add SYS_ADMIN"
  exit 1
fi

# Fallback to a shell if no command is provided
if [ $# -eq 0 ]; then
    exec /bin/bash
else
    exec "$@"
fi
