# S3QL Time Machine

S3QL Time Machine provides containerized recovery tools for legacy, encrypted S3QL filesystems stored in Amazon S3.

## Overview

Modern versions of S3QL cannot mount filesystems formatted with older S3QL revisions. Running destructive upgrades on live buckets can cause irreversible data loss.

This project solves that problem by building isolated Docker containers that run legacy S3QL releases (such as 3.8.1). The container mounts the remote S3 filesystem via FUSE and shares the decrypted filesystem with your host computer through a local directory. You can then copy your files out safely using standard tools like `rsync` without changing your host system packages or modifying the remote metadata format.

## System Requirements

- Linux operating system with the FUSE kernel module loaded (`/dev/fuse` present).
- Docker engine installed and running.
- AWS credentials with read and write permissions to the target S3 bucket.
- An S3QL authentication file (`~/.s3ql/authinfo2`) with credentials and filesystem passphrases.
- Sufficient local disk space to store the decrypted files.

## Project Files

- `Dockerfile`: Builds an Ubuntu 20.04 image with Python 3.8, FUSE3 libraries, and a specific legacy version of S3QL (defaults to version 3.8.1).
- `entrypoint.sh`: Container entrypoint script that verifies `/dev/fuse` availability.
- `s3ql-time-machine.sh`: Bash script that builds the image, starts the container, mounts credentials, and exposes the filesystem under `./pool/<bucket-name>`.
- `Dockerfile.versionid`: Lightweight Python container used to run `s3ql_version_id.py` without installing dependencies on the host.
- `s3ql_version_id.py`: Python script that reads and parses S3 object metadata headers on `s3ql_metadata` to check encryption status and filesystem version.
- `s3ql_version_id.sh`: Shell wrapper to run the version identification container.
- `troubleshooting-runbook.md`: Diagnostic guide for common errors, lock handling, and recovery steps.

## Initial Setup

### 1. Configure S3QL Authentication (`~/.s3ql/authinfo2`)

Create or update `~/.s3ql/authinfo2` on your host. Permissions must be strictly set to `0600`.

```ini
[my-bucket]
storage-url: s3://us-west-1/my-bucket
backend-login: YOUR_AWS_ACCESS_KEY_ID
backend-password: YOUR_AWS_SECRET_ACCESS_KEY
fs-passphrase: YOUR_FILESYSTEM_PASSPHRASE
```

Set file permissions:
```bash
chmod 600 ~/.s3ql/authinfo2
```

Important note on passphrases with percent signs:
Python's `configparser` interprets `%` characters as variable interpolation. If your `fs-passphrase` contains a percent sign (`%`), you must escape it by writing two percent signs (`%%`). For example, change `secret%123` to `secret%%123`.

### 2. Verify AWS Credentials

Make sure your AWS credentials are available through standard environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) or in `~/.aws/credentials`.

## Step-by-Step Recovery Procedure

### Step 1: Inspect the Remote S3QL Bucket

Before attempting a mount, inspect the headers of the remote `s3ql_metadata` object:

```bash
bash s3ql_version_id.sh <bucket-name>
```

This script inspects the metadata headers to identify the encryption type (for example, `AES_v2`) and the metadata format. If the filesystem is encrypted, S3QL stores the revision number inside the encrypted data block, which requires mounting with a matching legacy version.

### Step 2: Mount the Filesystem

Run the Time Machine script with your bucket name:

```bash
bash ./s3ql-time-machine.sh <bucket-name> [s3ql-version]
```

If omitted, `s3ql-version` defaults to `3.8.1`.

The script performs the following actions:
1. Builds the Docker image for the requested S3QL version if not already cached.
2. Starts the container with `/dev/fuse` and `SYS_ADMIN` capabilities.
3. Mounts your host `~/.s3ql/authinfo2` as read-only inside the container.
4. Binds the `./pool` directory with shared mount propagation.
5. Runs `mount.s3ql --allow-other` inside the container.

Once mounted, the decrypted filesystem is accessible on your host machine at:
`./pool/<bucket-name>`

### Step 3: Handle Stale Locks (If Needed)

If the filesystem was not cleanly unmounted in the past, `mount.s3ql` will exit with code 31:
`ERROR: Backend reports that fs is still mounted elsewhere, aborting.`

To clear this lock safely:
1. Keep the container running in the background.
2. Execute `fsck.s3ql` inside the container with `--force-remote`:
   ```bash
   docker exec s3ql_mount_<bucket-name> fsck.s3ql --log none --force-remote --authfile /root/.s3ql/authinfo2 s3://<region>/<bucket-name>
   ```
3. Once `fsck` completes and reports that metadata has been uploaded, retry the mount:
   ```bash
   docker exec -it s3ql_mount_<bucket-name> mount.s3ql --allow-other --authfile /root/.s3ql/authinfo2 s3://<region>/<bucket-name> /pool/<bucket-name>
   ```

### Step 4: Extract Plaintext Data

Copy the files from the `./pool/<bucket-name>` directory to your host backup location using `rsync`. Exclude the root-only `lost+found` folder:

```bash
rsync -avz --progress --exclude 'lost+found' "./pool/<bucket-name>/" "/path/to/backup/<bucket-name>/"
```

### Step 5: Unmount and Clean Up

After copying all data, cleanly unmount the filesystem so the remote metadata lock is released in S3:

```bash
docker exec -it s3ql_mount_<bucket-name> umount.s3ql "/pool/<bucket-name>"
docker rm -f s3ql_mount_<bucket-name>
```

## Common Issues and Troubleshooting

### 1. FUSE Permission Denied on Mount Point
If the host user cannot view contents inside `./pool/<bucket-name>`:
- The mount command must include `--allow-other`.
- The Docker container must be launched with `--device /dev/fuse`, `--cap-add SYS_ADMIN`, and `-v $(pwd)/pool:/pool:shared`.

### 2. Transport Endpoint Is Not Connected
If a container was killed while a filesystem was mounted, the host mount point may enter a disconnected state:
```bash
docker run --rm --privileged -v /absolute/path/to/docker-recovery/pool:/pool:shared ubuntu:20.04 umount -l /pool/<bucket-name>
```

### 3. Exit Code 17: Wrong Passphrase
```
ERROR: Wrong file system passphrase (or file system revision needs upgrade, or backend data is corrupted).
```
This indicates that the passphrase provided in `authinfo2` failed the cryptographic HMAC check on the `s3ql_passphrase` object. Verify the passphrase in `~/.s3ql/authinfo2`.

### 4. Exit Code 31: Filesystem Still Mounted Elsewhere
This indicates an uncleared lock in S3 metadata. Run `fsck.s3ql --force-remote` inside the container as described in Step 3.

### 5. Out of Disk Space During Extraction
Ensure the destination storage path has enough free space to hold the entire uncompressed and un-deduplicated contents of the bucket.
