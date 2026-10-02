#!/bin/bash
# S3QL Time Machine - Non-Destructive Data Egress Automation
# Mounts a legacy S3QL bucket via Docker FUSE and rsyncs the cleartext data.

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <bucket_name> [s3ql_version]"
    echo "Example: $0 eur-media 3.8.1"
    exit 1
fi

BUCKET_NAME="$1"
S3QL_VERSION="${2:-3.8.1}"

LOCAL_POOL="./pool/$BUCKET_NAME"
BACKUP_DIR="/home/mwalther/projects/aws-s3-backup/decrypt/$BUCKET_NAME"
AUTHINFO_FILE="$HOME/.s3ql/authinfo2"
CONTAINER_NAME="s3ql_mount_$BUCKET_NAME"
IMAGE_TAG="s3ql-time-machine:$S3QL_VERSION"

mkdir -p "$LOCAL_POOL"
mkdir -p "$BACKUP_DIR"

if [ ! -f "$AUTHINFO_FILE" ]; then
    echo "Error: authinfo2 file not found at $AUTHINFO_FILE"
    exit 1
fi

STORAGE_URL=$(grep "storage-url:.*$BUCKET_NAME" "$AUTHINFO_FILE" | head -n 1 | awk '{print $2}')
if [ -z "$STORAGE_URL" ]; then
    echo "Warning: Could not find full storage-url for $BUCKET_NAME in authinfo2, defaulting to s3://$BUCKET_NAME"
    STORAGE_URL="s3://$BUCKET_NAME"
fi

echo "Building S3QL Time Machine Docker image (S3QL Version: $S3QL_VERSION)..."
docker build --build-arg S3QL_VERSION="$S3QL_VERSION" -t "$IMAGE_TAG" -f Dockerfile .

echo "Starting isolated FUSE mount environment for $STORAGE_URL..."

# Ensure any leftover container is removed
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$CONTAINER_NAME" \
    --device /dev/fuse \
    --cap-add SYS_ADMIN \
    --security-opt apparmor:unconfined \
    -v "$AUTHINFO_FILE:/root/.s3ql/authinfo2:ro" \
    -v "$(pwd)/pool:/pool:shared" \
    "$IMAGE_TAG" \
    sleep infinity

echo "Container $CONTAINER_NAME is running."
echo "Waiting for container to initialize..."
sleep 2

echo "Mounting S3QL filesystem..."
docker exec -it "$CONTAINER_NAME" mount.s3ql --allow-other --authfile /root/.s3ql/authinfo2 "$STORAGE_URL" "/pool/$BUCKET_NAME"

echo "S3QL mounted successfully at $LOCAL_POOL"
echo "Starting rsync extraction of plain-text data..."

# Print the following commands for utility. @todo break discrete actions into distinct command
echo "rsync -avz --progress --exclude 'lost+found' \"$LOCAL_POOL/\" \"$BACKUP_DIR/\""

echo "Rsync extraction complete! Unmounting S3QL..."
echo "docker exec -it \"$CONTAINER_NAME\" umount.s3ql \"/pool/$BUCKET_NAME\""

echo "Stopping and removing container..."
echo "docker rm -f \"$CONTAINER_NAME\""

echo "Recovery fully completed for $BUCKET_NAME! Plain-text data is located at $BACKUP_DIR."
