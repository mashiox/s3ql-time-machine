#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <bucket_name>"
    exit 1
fi

BUCKET_NAME="$1"
IMAGE_NAME="s3ql-version-id"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building Docker image $IMAGE_NAME..."
docker build -q -t "$IMAGE_NAME" -f "$DIR/Dockerfile.versionid" "$DIR" > /dev/null
echo "Build complete."

echo "Running version identification..."
# We pass through standard AWS environment variables if they exist,
# and also mount ~/.aws in case the user relies on a credentials file.
# Note: we check if ~/.aws exists before mounting to avoid Docker creating an empty directory on the host.

AWS_MOUNT=""
if [ -d "${HOME}/.aws" ]; then
    AWS_MOUNT="-v ${HOME}/.aws:/root/.aws:ro"
fi

docker run --rm -it \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -e AWS_DEFAULT_REGION \
    -e AWS_PROFILE \
    $AWS_MOUNT \
    "$IMAGE_NAME" "$BUCKET_NAME"
