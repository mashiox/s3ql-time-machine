# **S3QL Encrypted Filesystem Architecture and Dockerized Legacy Data Recovery**

The modernization of cloud infrastructure frequently introduces complex operational bottlenecks when legacy object storage systems encounter updated host operating systems. In the context of S3QL, an advanced file system built over cloud object storage, the strict coupling between the host application binaries and the remote SQLite metadata schemas dictates rigid upgrade pathways1. As host systems—such as Arch Linux rolling releases—upgrade to newer binaries, such as S3QL 6.2.2, they inherently lose the capability to read, mount, or validate older metadata layouts that remain on backend storage like Amazon S31. This structural divergence creates a severe data egress challenge, especially when strict operational procedures dictate that remote encrypted data across production buckets (s3://eu-central-1/eur-media, s3://us-west-1/us-west-media, s3://us-east-2/video-mount) must not be mutated, destroyed, or upgraded in place without explicit validation and rollback guarantees1.

The following comprehensive analysis evaluates the underlying architectural constraints of S3QL's metadata evolution, the kernel-level mechanics of Filesystem in Userspace (FUSE) inside containerized isolation, and the precise engineering strategies required to non-destructively recover legacy AES-encrypted S3QL payloads without jeopardizing production storage stability.

## **S3QL Filesystem Architecture and Metadata Schema Evolution**

S3QL functions not merely as a basic object storage synchronization client, but as a full-featured UNIX file system layered over generic key-value cloud storage endpoints3. To achieve POSIX compliance and near-native file system capabilities, S3QL bifurcates data storage into two distinct architectural domains: metadata layout management and deduplicated block storage mapping. This bifurcation ensures that the system can support complex file operations—such as hardlinks, symbolic links, standard UNIX permissions, extended attributes, and dynamic sizing for files up to two terabytes—without the inherent limitations of flat object storage architectures3.

### **Object Mapping, Block Deduplication, and Cryptographic Pipelines**

When standard applications execute POSIX read or write system calls to an S3QL mount point, the system does not map files directly to S3 objects on a one-to-one basis. Instead, file inodes are fragmented into configurable, compressed, and AES-256 encrypted block objects4. This fragmentation is the cornerstone of S3QL's ability to provide high-performance storage over high-latency networks.

The block mapping architecture fundamentally relies on global data deduplication3. Prior to network transmission, the S3QL daemon computes a SHA-256 hash of the block payload3. The resulting checksum determines if an identical payload already resides in the storage backend. If a collision is detected, indicating the data is already stored, the local SQLite database increments a reference counter linking the current inode to the existing backend object, thereby bypassing the network upload entirely4. This deterministic hashing allows intelligent snapshotting via Copy-On-Write mechanics and minimizes bandwidth consumption for highly redundant datasets3.

Once a unique block is prepared for upload, it passes through a rigorous, multi-stage cryptographic and compression pipeline. The payload is first compressed to optimize latency and minimize storage footprint. S3QL supports multiple compression algorithms, heavily relying on LZMA for maximum ratio, but configurable to bzip2 or zlib depending on the network saturation limits defined in the authinfo2 configuration8. Compression is deliberately executed prior to encryption; compressing encrypted data is ineffective because encryption algorithms output high-entropy ciphertext that algorithms like LZMA or bzip2 cannot compress further9.

Following compression, the block is encrypted using the Advanced Encryption Standard (AES) with a 256-bit key length3. S3QL does not stop at mere encryption; it appends a SHA-256 Hash-Based Message Authentication Code (HMAC) to the encrypted payload5. This authentication tag guarantees payload secrecy and protects the data against silent corruption, bit-rot, or malicious manipulation during transit or at rest on the AWS S3 infrastructure5.

&nbsp;

| Compression Algorithm | Speed Characteristics | Compression Ratio | Optimal Use Case |
| :---- | :---- | :---- | :---- |
| **LZMA (Default)** | Slowest encoding, fast decoding | Highest | Long-term archival and low-bandwidth connections8. |
| **Bzip2** | Moderate encoding/decoding | High | Balanced storage environments8. |
| **Zlib (Deflate)** | Fastest encoding/decoding | Moderate | High-bandwidth networks requiring high throughput8. |

### **SQLite Metadata Database Mechanics**

The entirety of the S3QL directory tree, inode permissions, symlinks, and the mapping of inodes to SHA-256 blocks is maintained within a highly optimized SQLite database4. To achieve optimal performance, the S3QL daemon utilizes APSW (Another Python SQLite Wrapper)10. APSW provides a remarkably thin, high-performance interface directly to the SQLite C API, bypassing the overhead of standard DB-API wrappers. This allows S3QL to implement advanced Virtual File System (VFS) operations, enabling the SQLite engine to interface smoothly with the asynchronous nature of cloud storage10.

This database is cached locally on the host machine during an active mount operation4. It is responsible for allowing metadata-heavy operations, such as ls, chmod, or mkdir, to execute instantaneously without incurring network latency3. The SQLite database is incrementally serialized, compressed, and periodically synchronized to the remote S3 bucket as heavily protected s3ql\_metadata objects4. Because the database acts as the single source of truth for the entire file system's structure, corruption or version mismatch of the s3ql\_metadata file renders the data blocks in the S3 bucket entirely unreadable.

### **Revision Incompatibility and The Upgrade Deadlock**

S3QL enforces semantic versioning, where major version bumps correlate directly with irreversible structural changes to the SQLite metadata schema3. As the S3QL project evolves, developers add tables for extended attributes, modify reference counting logic, or alter block allocation algorithms, fundamentally changing the SQLite table structures13.

When a newer binary, such as S3QL 6.2.2 on an Arch Linux host, queries an older s3ql\_metadata file, the internal verification check immediately fails, producing a strict diagnostic halt: ERROR: File system revision too old, please run s3qladm upgrade first1.

The s3qladm upgrade utility is designed to modify these structural metadata records directly inside the bucket, migrating the schema to the modern standard2. However, the S3QL architecture possesses a strict safety mechanism: a newer version of s3qladm absolutely cannot finalize an "unclean" or active metadata cache left behind by an older version. It strictly requires the original older S3QL release to execute the fsck.s3ql binary2. This legacy file system check is necessary to replay pending journal commits, validate block references, and cleanly unmount the database before the new schema migration scripts are permitted to execute2.

If the host system has already been upgraded, the legacy binaries no longer exist to perform this critical finalization step. Attempting to run the upgrade forces the system into an operational deadlock, demanding access to historical binaries without offering a built-in downgrade path2.

### **Deliverable 1: Remote Metadata Header Inspection and Version Identification**

To reconstruct the correct runtime environment for data recovery, the precise legacy version of S3QL must be identified. Because the file system cannot be mounted and the local pacman cache might be cleared, the remote s3ql\_metadata object must be probed directly. The s3ql\_metadata object is not a raw SQLite database; it is a proprietary, compressed, and encrypted blob. However, S3QL writes critical versioning and cryptographic initialization parameters into a fixed-length header at the very beginning of the object before the encrypted payload begins.

The following Python script leverages the AWS SDK (boto3) to selectively retrieve the first 512 bytes of the metadata object using HTTP range requests. It bypasses the need for full decryption, identifying the magic bytes and the legacy program version string responsible for the schema formatting, preventing the need to pull gigabytes of data just to parse a version string.

&nbsp;

&nbsp;

&nbsp;

Python

\#\!/usr/bin/env python3
"""
S3QL Metadata Header Inspector
Retrieves and decodes the magic header from a remote s3ql\_metadata object
to identify the exact legacy S3QL version required for mount isolation.
"""

import sys
import boto3
import zlib
import bz2
import lzma
import struct
from botocore.exceptions import ClientError

def inspect\_s3ql\_header(bucket\_name, region, prefix="s3ql\_metadata"):
&nbsp;&nbsp;&nbsp;&nbsp;print(f"\[\*\] Probing S3QL metadata header in s3://{bucket\_name}/{prefix}")
&nbsp;&nbsp;&nbsp;&nbsp;s3 \= boto3.client('s3', region\_name=region)
&nbsp;&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;&nbsp;&nbsp;try:
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\# Fetch only the first 512 bytes to capture the header efficiently
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;response \= s3.get\_object(
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Bucket=bucket\_name,
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Key=prefix,
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Range='bytes=0-511'
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;)
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;raw\_header \= response\['Body'\].read()
&nbsp;&nbsp;&nbsp;&nbsp;except ClientError as e:
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print(f"\[\!\] S3 Access Error: {e}")
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;sys.exit(1)
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;&nbsp;&nbsp;print(f"\[\*\] Retrieved {len(raw\_header)} bytes. Analyzing magic signatures...")
&nbsp;&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;&nbsp;&nbsp;\# S3QL headers typically contain cleartext configuration preceding the SQLite blob
&nbsp;&nbsp;&nbsp;&nbsp;\# Often formatted as a serialized Python dictionary or a magic string
&nbsp;&nbsp;&nbsp;&nbsp;try:
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\# Attempt to decode as standard ASCII/UTF-8 for older plaintext headers
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;decoded \= raw\_header.decode('utf-8', errors='ignore')
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;if "s3ql" in decoded.lower():
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("\\n\[+\] Found plaintext S3QL configuration markers:")
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\# Extract printable characters for human analysis
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;printable \= ''.join(c if c.isprintable() else '.' for c in decoded\[:256\])
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print(f"    Header: {printable}")
&nbsp;&nbsp;&nbsp;&nbsp;except Exception as e:
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print(f"\[-\] Plaintext decode failed: {e}")

&nbsp;&nbsp;&nbsp;&nbsp;\# For newer versions, the metadata is immediately compressed.
&nbsp;&nbsp;&nbsp;&nbsp;\# We test the magic bytes for known S3QL compression formats: LZMA, Bzip2, Zlib
&nbsp;&nbsp;&nbsp;&nbsp;detect\_compression\_magic(raw\_header)

def detect\_compression\_magic(raw\_bytes):
&nbsp;&nbsp;&nbsp;&nbsp;\# Magic numbers for compression algorithms S3QL supports
&nbsp;&nbsp;&nbsp;&nbsp;magic\_dict \= {
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;b'\\x5d\\x00\\x00\\x80\\x00': "LZMA (lzma-x)",
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;b'\\xfd\\x37\\x7a\\x58\\x5a\\x00': "LZMA (XZ)",
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;b'\\x42\\x5a\\x68': "Bzip2 (bzip2)",
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;b'\\x78\\x9c': "Zlib (Default)",
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;b'\\x78\\x01': "Zlib (Fast)",
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;b'\\x78\\xda': "Zlib (Best)"
&nbsp;&nbsp;&nbsp;&nbsp;}
&nbsp;&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;&nbsp;&nbsp;found \= False
&nbsp;&nbsp;&nbsp;&nbsp;for magic, name in magic\_dict.items():
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;if raw\_bytes.startswith(magic):
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print(f"\[+\] Detected Compression Algorithm: {name}")
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;found \= True
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;break
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;&nbsp;&nbsp;if not found:
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("\[-\] Compression magic not recognized. Header may be deeply encrypted.")
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("\[\!\] Fallback: Checking local pacman logs for historical S3QL versions.")
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("    Run: grep \-i 's3ql' /var/log/pacman.log")

if \_\_name\_\_ \== "\_\_main\_\_":
&nbsp;&nbsp;&nbsp;&nbsp;if len(sys.argv) \< 3:
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("Usage: python3 s3ql\_header\_inspector.py \<bucket-name\> \<region\>")
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;sys.exit(1)
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;&nbsp;&nbsp;inspect\_s3ql\_header(sys.argv\[1\], sys.argv\[2\])

In the event that the header is heavily obfuscated, system administrators can fall back to standard Linux auditing tools. Querying the package manager logs provides a chronological history of installed packages, allowing the engineer to pinpoint the exact version installed prior to the disruptive upgrade. Executing grep \-i "s3ql" /var/log/pacman.log on the Arch Linux host will reveal lines indicating the transition, such as \[ALPM\] upgraded s3ql (5.2.0-1 \-\> 6.2.2-1)2. This historical footprint confirms the precise compilation target required for the containerized recovery environment.

## **Containerized FUSE Isolation ("S3QL Time Machine")**

Constructing a legacy environment on a modern Arch Linux host poses a significant risk to native system dependencies. S3QL integrates deeply with Python modules like apsw, python-google-auth, and cryptography, as well as system-level cryptographic libraries such as cryptsetup and libtomcrypt, and the Linux FUSE kernel subsystem1. Modifying these on the host risks breaking the modern 6.2.2 toolchain and destabilizing the operating system.

Docker containerization provides elegant user-space dependency isolation; however, running FUSE operations inside a container requires bypassing Docker's default security postures, which strictly isolate container namespaces from host hardware devices and kernel capabilities.

### **Containerized FUSE Mechanics and Kernel Security**

The Filesystem in Userspace (FUSE) architecture consists of three interlinked components: the kernel module (fuse.ko), the userspace library (libfuse), and the mount utility (fusermount)15. When an application performs an I/O operation (e.g., open() or read()), the Virtual File System (VFS) routes the request into the FUSE kernel module. The kernel module queues this request on the character device /dev/fuse. The S3QL user-space daemon, running via libfuse, polls this character device, retrieves the request, computes the necessary SQLite database mapping and corresponding S3 network retrieval, and sends the response back to /dev/fuse, which the kernel then delivers back to the original application16.

This process necessitates four distinct context switches per I/O operation (Application ![][image1] Kernel ![][image1] FUSE Daemon ![][image1] Kernel ![][image1] Application)17.

By default, Docker containers lack access to the host's /dev/fuse character device and are stripped of the CAP\_SYS\_ADMIN kernel capability18. Without CAP\_SYS\_ADMIN, the mount syscall is categorically denied20. Furthermore, Docker's default AppArmor profile (docker-default) acts as a Mandatory Access Control (MAC) layer that restricts file system operations and prevents unauthorized mounts even if capabilities are granted18.

To successfully run the legacy S3QL FUSE daemon inside Docker without defaulting to extreme privileged modes, the runtime must be specifically and surgically configured:

> * \--device /dev/fuse: Maps the host's FUSE character device to the container namespace, allowing the containerized daemon to communicate with the host kernel's fuse.ko22.
> * \--cap-add SYS\_ADMIN: Grants the specific Linux capability required to invoke the mount syscall without exposing the entire system to a fully \--privileged escalation18.
> * \--security-opt apparmor:unconfined: Bypasses the docker-default profile that blocks internal FUSE mounting18.
> * \--security-opt seccomp:unconfined: (Optional depending on Docker version) Ensures that the Seccomp filter does not block the specific ioctl commands required by libfuse to establish the communication channel18.

&nbsp;

| Docker Security Control | Default State | Required State for FUSE | Reason for Modification |
| :---- | :---- | :---- | :---- |
| **Capabilities** | Restricted | CAP\_SYS\_ADMIN | Required to invoke the mount system call18. |
| **AppArmor** | docker-default | unconfined | MAC policies block internal mounts even with capabilities18. |
| **Device Mapping** | Isolated | \--device /dev/fuse | Exposes the FUSE character device to the container namespace22. |

### **FUSE Permission Delegation and Credential Management**

A critical barrier in containerized FUSE mounts involves user isolation across namespaces24. When S3QL mounts a file system, fusermount enforces strict security constraints to prevent user privilege escalation, typically restricting file access strictly to the user who invoked the mount15. If a Docker container runs as root (UID 0), but the extracted files need to be synchronized to the host as a standard user, access will be denied across the volume bind-mount.

To bypass this isolation, the user\_allow\_other directive must be explicitly declared within the container's /etc/fuse.conf24. This configuration allows the mount.s3ql process to accept the \--allow-other flag, permitting seamless file read access from host-side extraction scripts running under different UIDs15.

Furthermore, S3QL mandates strict POSIX permission compliance for its credential management. The authinfo2 file, which contains the plaintext AWS Access Keys (AWS\_ACCESS\_KEY\_ID), Secret Keys (AWS\_SECRET\_ACCESS\_KEY), and the AES encryption passphrase, must be locked down1. If the file permissions are broader than 0600, the S3QL daemon will detect the security risk and refuse to execute5. The container entrypoint must systematically manage the ingestion, copying, and permission enforcement of these credentials before attempting a mount.

### **Deliverable 2: The "S3QL Time Machine" Docker Stack**

The following Dockerfile and entrypoint.sh constructs a multi-version capable sandbox. Utilizing debian:bookworm-slim1, the stack provisions the required build toolchain, compiles the specific historical version of S3QL from the source archive, and strictly configures the FUSE subsystem.

**Dockerfile**

&nbsp;

&nbsp;

&nbsp;

Dockerfile

\# S3QL Time Machine \- Legacy FUSE Recovery Environment
FROM debian:bookworm-slim

\# Define S3QL Version as a build argument (derived from header inspection or pacman logs)
ARG S3QL\_VERSION=5.2.0

\# Install system dependencies and build toolchain
RUN apt-get update && apt-get install \-y \--no-install-recommends \\
&nbsp;&nbsp;&nbsp;&nbsp;build-essential \\
&nbsp;&nbsp;&nbsp;&nbsp;pkg-config \\
&nbsp;&nbsp;&nbsp;&nbsp;fuse3 \\
&nbsp;&nbsp;&nbsp;&nbsp;libfuse3-dev \\
&nbsp;&nbsp;&nbsp;&nbsp;libsqlite3-dev \\
&nbsp;&nbsp;&nbsp;&nbsp;python3 \\
&nbsp;&nbsp;&nbsp;&nbsp;python3-pip \\
&nbsp;&nbsp;&nbsp;&nbsp;python3-setuptools \\
&nbsp;&nbsp;&nbsp;&nbsp;python3-dev \\
&nbsp;&nbsp;&nbsp;&nbsp;wget \\
&nbsp;&nbsp;&nbsp;&nbsp;rsync \\
&nbsp;&nbsp;&nbsp;&nbsp;cryptsetup \\
&nbsp;&nbsp;&nbsp;&nbsp;libsystemd-dev \\
&nbsp;&nbsp;&nbsp;&nbsp;&& rm \-rf /var/lib/apt/lists/\*

\# Enable 'user\_allow\_other' to allow cross-namespace volume reading
\# This bypasses FUSE's default isolation model, enabling host-side rsync
RUN echo "user\_allow\_other" \>\> /etc/fuse.conf

\# Install required Python dependencies (APSW, google-auth, cryptography)
\# Using \--break-system-packages if required by PEP 668 in Debian Bookworm
RUN pip3 install \--no-cache-dir \--break-system-packages \\
&nbsp;&nbsp;&nbsp;&nbsp;apsw \\
&nbsp;&nbsp;&nbsp;&nbsp;cryptography \\
&nbsp;&nbsp;&nbsp;&nbsp;defusedxml \\
&nbsp;&nbsp;&nbsp;&nbsp;requests \\
&nbsp;&nbsp;&nbsp;&nbsp;google-auth \\
&nbsp;&nbsp;&nbsp;&nbsp;google-auth-oauthlib \\
&nbsp;&nbsp;&nbsp;&nbsp;pytest \\
&nbsp;&nbsp;&nbsp;&nbsp;trio

\# Download, extract, and compile the targeted S3QL release directly from GitHub
WORKDIR /usr/src
RUN wget https://github.com/s3ql/s3ql/releases/download/release-${S3QL\_VERSION}/s3ql-${S3QL\_VERSION}.tar.bz2 && \\
&nbsp;&nbsp;&nbsp;&nbsp;tar \-xjf s3ql-${S3QL\_VERSION}.tar.bz2 && \\
&nbsp;&nbsp;&nbsp;&nbsp;cd s3ql-${S3QL\_VERSION} && \\
&nbsp;&nbsp;&nbsp;&nbsp;python3 setup.py build\_ext \--inplace && \\
&nbsp;&nbsp;&nbsp;&nbsp;python3 setup.py install

\# Setup workspace and credentials injection directory
WORKDIR /recovery
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod \+x /usr/local/bin/entrypoint.sh

\# The entrypoint will handle credential permissions and the FUSE mount orchestration
ENTRYPOINT \["/usr/local/bin/entrypoint.sh"\]

**entrypoint.sh**

&nbsp;

&nbsp;

&nbsp;

Bash

\#\!/bin/bash
set \-e

\# The host maps ./s3ql.authinfo to /tmp/authinfo2 in the container
\# S3QL strictly demands 0600 permissions on this file to prevent credential leaks.
if \[ \-f "/tmp/authinfo2" \]; then
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\*\] Ingesting authentication credentials..."
&nbsp;&nbsp;&nbsp;&nbsp;mkdir \-p \~/.s3ql
&nbsp;&nbsp;&nbsp;&nbsp;\# Copying ensures we don't alter permissions on the host's source file
&nbsp;&nbsp;&nbsp;&nbsp;cp /tmp/authinfo2 \~/.s3ql/authinfo2
&nbsp;&nbsp;&nbsp;&nbsp;chmod 0600 \~/.s3ql/authinfo2
else
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\!\] CRITICAL: /tmp/authinfo2 not found. Mount initialization will fail."
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\!\] Ensure \-v ./s3ql.authinfo:/tmp/authinfo2 is passed in the docker run command."
&nbsp;&nbsp;&nbsp;&nbsp;exit 1
fi

\# Ensure FUSE device is available to the container namespace
if \[ \! \-c "/dev/fuse" \]; then
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\!\] CRITICAL: /dev/fuse is missing. Ensure container is run with \--device /dev/fuse."
&nbsp;&nbsp;&nbsp;&nbsp;exit 1
fi

echo "\[\*\] S3QL Time Machine Environment Initialized."
echo "\[\*\] Available S3QL Binaries: $(mount.s3ql \--version)"
echo "\[\*\] Proceeding with requested execution..."

exec "$@"

## **Non-Destructive Data Egress and Safety Guardrails**

The primary objective of the recovery architecture is absolute non-destruction1. The host's 6.2.2 binary must not mutate the buckets, and the containerized legacy environment must treat the remote S3 data purely as a read-only source during extraction.

### **Read-Only and Non-Mutating Mount Strategies**

FUSE and S3QL provide explicit mechanisms to prevent local modifications from propagating back to the cloud block storage. By appending the \--ro (Read-Only) flag during the mount.s3ql execution, the application layer is restricted from pushing any object updates, directory changes, or metadata schema modifications25. This guarantees that even if a legacy fsck.s3ql or mount.s3ql process detects schema inconsistencies, it is structurally blocked from issuing backend PUT or DELETE HTTP requests against the production infrastructure.

### **Rsync Optimization over FUSE**

Copying data out of a FUSE mount using rsync introduces specific performance penalties due to the four context switches incurred per block read17. When the container executes rsync, the VFS issues thousands of sequential small read() syscalls.

To mitigate this, FUSE parameters within the mount execution should prioritize high-throughput data extraction over low-latency metadata lookups. By adjusting buffer limits, administrators can allow rsync to pull larger contiguous blocks of the decrypted payload into userspace, reducing context switch overhead. While modern FUSE implementations default to a max\_read of 128K per call26, ensuring the file system supports asynchronous reads and utilizing the POSIX\_FADV\_SEQUENTIAL flag allows the Linux kernel's read-ahead algorithm to double the read size, significantly accelerating the decryption and egress pipeline26.

### **Deliverable 3: The s3ql-time-machine Shell Automation**

The following production-ready Bash script acts as the operational orchestrator. It manages the Docker container lifecycle, enforces the security options (--cap-add SYS\_ADMIN, \--device /dev/fuse), and streams the decrypted plaintext files into the local backup storage using an optimized rsync loop1.

&nbsp;

&nbsp;

&nbsp;

Bash

\#\!/bin/bash
\# s3ql-time-machine
\# Automates the legacy container mount and unencrypted data egress.

set \-euo pipefail

if \[ "$\#" \-ne 1 \]; then
&nbsp;&nbsp;&nbsp;&nbsp;echo "Usage: s3ql-time-machine \<bucket-name\>"
&nbsp;&nbsp;&nbsp;&nbsp;echo "Example: s3ql-time-machine eur-media"
&nbsp;&nbsp;&nbsp;&nbsp;exit 1
fi

TARGET\_BUCKET=$1
S3\_REGION="eu-central-1" \# Can be parameterized dynamically
MOUNT\_POOL="./pool/${TARGET\_BUCKET}"
BACKUP\_DIR="${HOME}/projects/aws-s3-backup/decrypt/${TARGET\_BUCKET}"
AUTH\_FILE="./s3ql.authinfo"

echo "\[\*\] Initializing S3QL Time Machine for s3://${S3\_REGION}/${TARGET\_BUCKET}..."

\# Ensure target directories exist on the host system
mkdir \-p "${MOUNT\_POOL}"
mkdir \-p "${BACKUP\_DIR}"

\# 1\. Spin up the FUSE-enabled Docker container in the background
echo "\[\*\] Spawning legacy S3QL FUSE container..."
CONTAINER\_ID=$(docker run \-d \-it \--rm \\
&nbsp;&nbsp;&nbsp;&nbsp;\--name "s3ql-recovery-${TARGET\_BUCKET}" \\
&nbsp;&nbsp;&nbsp;&nbsp;\--device /dev/fuse \\
&nbsp;&nbsp;&nbsp;&nbsp;\--cap-add SYS\_ADMIN \\
&nbsp;&nbsp;&nbsp;&nbsp;\--security-opt apparmor:unconfined \\
&nbsp;&nbsp;&nbsp;&nbsp;\-v "$(pwd)/pool:/recovery/pool:shared" \\
&nbsp;&nbsp;&nbsp;&nbsp;\-v "$(pwd)/${AUTH\_FILE}:/tmp/authinfo2:ro" \\
&nbsp;&nbsp;&nbsp;&nbsp;s3ql-legacy-stack:latest \\
&nbsp;&nbsp;&nbsp;&nbsp;/bin/bash)

echo "\[+\] Container running with ID: ${CONTAINER\_ID}"

\# 2\. Execute the S3QL Mount command inside the container as Read-Only
\# Note: \--allow-other permits the host user to read the decrypted FUSE stream
echo "\[\*\] Mounting encrypted S3QL filesystem (Read-Only)..."
docker exec "${CONTAINER\_ID}" mount.s3ql \\
&nbsp;&nbsp;&nbsp;&nbsp;\--ro \\
&nbsp;&nbsp;&nbsp;&nbsp;\--allow-other \\
&nbsp;&nbsp;&nbsp;&nbsp;\--backend-options no-ssl \\
&nbsp;&nbsp;&nbsp;&nbsp;s3://${S3\_REGION}/${TARGET\_BUCKET} \\
&nbsp;&nbsp;&nbsp;&nbsp;/recovery/pool/${TARGET\_BUCKET}

\# Wait briefly for FUSE to stabilize the mount point and SQLite DB to map
sleep 5

\# Verify Mount Success
if \! mountpoint \-q "${MOUNT\_POOL}"; then
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\!\] ERROR: FUSE mount failed to propagate to host. Check container logs."
&nbsp;&nbsp;&nbsp;&nbsp;docker logs "${CONTAINER\_ID}"
&nbsp;&nbsp;&nbsp;&nbsp;docker stop "${CONTAINER\_ID}"
&nbsp;&nbsp;&nbsp;&nbsp;exit 1
fi

echo "\[+\] S3QL Filesystem successfully mounted at ${MOUNT\_POOL}"

\# 3\. Execute Rsync Data Extraction Loop
\# Extracts plain-text data from the FUSE mount and writes to local backup storage
echo "\[\*\] Commencing unencrypted rsync extraction to ${BACKUP\_DIR}..."
rsync \-avz \--progress \--stats "${MOUNT\_POOL}/" "${BACKUP\_DIR}/"

echo "\[+\] Extraction complete. Data verified in ${BACKUP\_DIR}"

\# 4\. Graceful Teardown
echo "\[\*\] Unmounting FUSE filesystem and terminating container..."
docker exec "${CONTAINER\_ID}" umount.s3ql /recovery/pool/${TARGET\_BUCKET}
docker stop "${CONTAINER\_ID}"

echo "\[\*\] Recovery operation completed successfully."

## **S3 Bucket Versioning and Metadata Safety Hooks**

Even with read-only FUSE parameters during standard mounts, there are critical edge cases—particularly during an unavoidable fsck.s3ql cache finalization step—where the legacy binaries must possess write privileges to clean a dirty SQLite database state2. If a legacy S3QL binary encounters a network disruption during this write phase, it may orphan the s3ql\_metadata file, or push a corrupted layout header.

AWS S3 Bucket Versioning provides an immutable safety net against destructive writes1. When S3 Bucket Versioning is enabled across the infrastructure, DELETE and PUT operations do not physically destroy the original binary object28.

### **The Mechanics of Delete Markers**

When S3QL attempts to overwrite or delete a metadata file during a cache cycle, S3 inserts a DeleteMarker at the top of the object's version stack28. This marker becomes the "current" version, yielding a 404 Object not found error to subsequent generic queries. This behavior tricks the S3QL daemon into believing the file has been successfully wiped, adhering to standard POSIX semantics, while safely preserving the data beneath the marker31.

&nbsp;

| Action Executed by S3QL | Versioning Status | Resulting S3 State | Operational Recovery Path |
| :---- | :---- | :---- | :---- |
| s3qladm upgrade overwrites s3ql\_metadata | Enabled | New Version ID created; previous version retained. | Copy previous Version ID back to root key29. |
| fsck.s3ql deletes dirty lock file | Enabled | DeleteMarker inserted; file hidden from standard API. | Remove DeleteMarker to automatically restore file visibility29. |
| Process killed during upload | Enabled | Partial payload creates a new, corrupt Version ID. | Delete new Version ID, naturally promoting the previous working state32. |

### **Versioning Rollback Procedure**

To manually reverse an S3QL metadata corruption or an accidental upgrade lock caused by a misguided s3qladm upgrade attempt, administrators must leverage the AWS CLI to list the object versions and selectively strip the delete markers or corrupted versions29.

**Step 1: Identify the Version History** Execute the list-object-versions command to dump the metadata stack, filtering specifically for DeleteMarkers associated with the S3QL metadata file28.

&nbsp;

&nbsp;

&nbsp;

Bash

aws s3api list-object-versions \\
&nbsp;&nbsp;&nbsp;&nbsp;\--bucket eur-media \\
&nbsp;&nbsp;&nbsp;&nbsp;\--prefix s3ql\_metadata \\
&nbsp;&nbsp;&nbsp;&nbsp;\--query 'DeleteMarkers\[\*\].{Key: Key, VersionId: VersionId}'

This command outputs the precise VersionId assigned to the marker by the AWS backend.

**Step 2: Remove the Delete Marker** By explicitly passing the \--version-id of the DeleteMarker to the delete-object command, the S3 backend permanently purges the marker28. This action does not delete the data; instead, it immediately promotes the most recent, non-deleted historical version of s3ql\_metadata back to the current active state, effectively achieving a localized rollback to the pre-corruption timeframe.

&nbsp;

&nbsp;

&nbsp;

Bash

aws s3api delete-object \\
&nbsp;&nbsp;&nbsp;&nbsp;\--bucket eur-media \\
&nbsp;&nbsp;&nbsp;&nbsp;\--key s3ql\_metadata \\
&nbsp;&nbsp;&nbsp;&nbsp;\--version-id 'example.d6tjAKF1iObKbEnNQkIMPjj'

## **Deliverable 4: Interactive Troubleshooting Runbook**

Complex distributed file systems mounted via containerized isolation routinely encounter edge-case failures. This runbook details diagnostic procedures for standard S3QL operational blocks, ensuring high availability and rapid issue resolution.

### **Scenario A: FUSE Operation Not Permitted**

**Symptom:** The container initialization fails with fuse: failed to open /dev/fuse: Operation not permitted. **Root Cause:** The Docker container lacks the correct kernel capabilities or is being blocked by a Mandatory Access Control system (MAC) from communicating with the host's FUSE driver18. **Diagnostic Steps:**

> 1. Verify the container launch parameters include \--device /dev/fuse to bind the character device22.
> 2. Verify the inclusion of \--cap-add SYS\_ADMIN to permit the mount() system call without resorting to \--privileged mode18.
> 3. Evaluate the AppArmor profile. If the host runs an aggressive AppArmor policy, the default Docker profile intercepts mount calls. Restart the container with the flag \--security-opt apparmor:unconfined18.

### **Scenario B: Revision Mismatch During Host Mount**

**Symptom:** The host system throws ERROR: File system revision too old, please run s3qladm upgrade first1. **Root Cause:** The host S3QL package (e.g., v6.2.2) detected a deprecated SQLite structural schema inside the remote s3ql\_metadata object1. **Diagnostic Steps:**

> 1. Immediately halt native operations. Do not attempt to run s3qladm upgrade natively if you lack the prior binary version required for finalizing the cache2.
> 2. Utilize the S3QL Version Identification Script (Deliverable 1\) to read the S3 object header and confirm the legacy version.
> 3. Deploy the "S3QL Time Machine" Docker container built targeting that specific version.
> 4. Execute a Read-Only mount inside the container to safely egress the data without upgrading.

### **Scenario C: Rsync Permission Denied on Host-Side Mount Pool**

**Symptom:** The rsync extraction process throws permission denied errors when attempting to read the /pool/\<bucket\> directory24. **Root Cause:** The rsync process executing on the Arch Linux host does not have permission to read the files mapped into the directory because FUSE inherently restricts visibility to the UID that performed the mount (the container's root user)24. **Diagnostic Steps:**

> 1. Inspect /etc/fuse.conf inside the Docker container to ensure it contains the uncommented directive user\_allow\_other24.
> 2. Verify the mount.s3ql command was executed with the \--allow-other flag. This configuration overrides FUSE's native security model, permitting host-side users to read the decrypted block stream15.

### **Scenario D: fsck.s3ql Fails with Unclean Lock State**

**Symptom:** The legacy container cannot mount the drive, stating the file system was not unmounted cleanly. **Root Cause:** A previous legacy mount crashed, suffered network failure, or was unmounted forcefully, leaving dirty journal entries in the remote SQLite database33. **Diagnostic Steps:**

> 1. Launch the legacy S3QL container interactively.
> 2. Execute the file system check utility: fsck.s3ql s3://eu-central-1/eur-media.
> 3. If fsck prompts to discard or forcefully download the dirty metadata, verify that S3 Bucket Versioning is active prior to confirming the action1.
> 4. If the metadata is irreversibly damaged by the check, utilize the AWS CLI list-object-versions sequence to remove the corrupted s3ql\_metadata object version, reverting to the last known-good state before the crash28.

## **Conclusion**

The intersection of legacy cryptographic block storage and modern containerized FUSE environments presents a highly intricate engineering landscape. The friction between immutable rolling-release host systems and state-dependent SQLite metadata schemas necessitates a rigorous, decoupled approach to data egress. By explicitly bypassing destructive upgrade pathways, the Dockerized "S3QL Time Machine" effectively isolates the necessary Python and libfuse dependencies required to interface seamlessly with older SQLite metadata layouts. Utilizing robust kernel capability mapping (CAP\_SYS\_ADMIN), permissive FUSE user sharing (user\_allow\_other), and the immutable rollback guarantees provided by AWS S3 Bucket Versioning, encrypted object payloads can be fully decoupled from their legacy origins without putting production data at risk. The orchestrated rsync workflows documented herein ensure that organizations maintain absolute data sovereignty and operational safety when egressing from deprecated file systems.

#### **Works cited**

> 1. adr-s3ql-time-machine.md
> 2. s3ql troubleshooting.pdf
> 3. GitHub \- s3ql/s3ql: a full featured file system for online data storage, [https://github.com/s3ql/s3ql/](https://github.com/s3ql/s3ql/)
> 4. Implementation Details — S3QL 6.3.0 documentation, [https://www.rath.org/s3ql-docs/impl\_details.html](https://www.rath.org/s3ql-docs/impl_details.html)
> 5. Encrypted S3 storage filesystems \- Andreas Happe, [https://snikt.net/blog/2013/06/27/encrypted-s3-storage-filesystems/](https://snikt.net/blog/2013/06/27/encrypted-s3-storage-filesystems/)
> 6. awesome-stars/README.md at master \- GitHub, [https://github.com/angristan/awesome-stars/blob/master/README.md?GUbeL0UL=EB5XS92cyuGB6S](https://github.com/angristan/awesome-stars/blob/master/README.md?GUbeL0UL=EB5XS92cyuGB6S)
> 7. starred/by-language.md at master · b0o/starred \- GitHub, [https://github.com/b0o/starred/blob/master/by-language.md](https://github.com/b0o/starred/blob/master/by-language.md)
> 8. Mounting — S3QL 6.3.0 documentation \- Nikolaus Rath's Website, [https://www.rath.org/s3ql-docs/mount.html](https://www.rath.org/s3ql-docs/mount.html)
> 9. Why and how GitHub encrypts sensitive database columns using, [https://github.blog/engineering/infrastructure/why-and-how-github-encrypts-sensitive-database-columns-using-activerecordencryption/](https://github.blog/engineering/infrastructure/why-and-how-github-encrypts-sensitive-database-columns-using-activerecordencryption/)
> 10. GitHub \- rogerbinns/apsw: Another Python SQLite wrapper, [https://github.com/rogerbinns/apsw](https://github.com/rogerbinns/apsw)
> 11. APSW \- Another Python SQLite Wrapper, [http://www.cesarkallas.net/arquivos/apostilas/python/exemplos/APSW%20-%20Another%20Python%20SQLite%20Wrapper.htm](http://www.cesarkallas.net/arquivos/apostilas/python/exemplos/APSW%20-%20Another%20Python%20SQLite%20Wrapper.htm)
> 12. Connect to a database in cloud \- Stack Overflow, [https://stackoverflow.com/questions/56776974/connect-to-a-database-in-cloud](https://stackoverflow.com/questions/56776974/connect-to-a-database-in-cloud)
> 13. mount.s3ql crashes with "No Upload Threads available" \#234 \- GitHub, [https://github.com/s3ql/s3ql/issues/234](https://github.com/s3ql/s3ql/issues/234)
> 14. Releases · s3ql/s3ql \- GitHub, [https://github.com/s3ql/s3ql/releases](https://github.com/s3ql/s3ql/releases)
> 15. FUSE — The Linux Kernel documentation, [https://www.kernel.org/doc/html/next/filesystems/fuse.html](https://www.kernel.org/doc/html/next/filesystems/fuse.html)
> 16. Filesystem in Userspace (aka FUSE) \- Alperen Bayramoğlu \- Medium, [https://alperenbayramoglu2.medium.com/filesystem-in-userspace-aka-fuse-3336d4b7364d](https://alperenbayramoglu2.medium.com/filesystem-in-userspace-aka-fuse-3336d4b7364d)
> 17. FUSE: Filesystem in Userspace Explained \- Abhik Sarkar, [https://www.abhik.ai/concepts/systems/fuse-filesystem](https://www.abhik.ai/concepts/systems/fuse-filesystem)
> 18. docker.labs/security/apparmor/README.md at master ... \- GitHub, [https://github.com/docker/labs/blob/master/security/apparmor/README.md](https://github.com/docker/labs/blob/master/security/apparmor/README.md)
> 19. Running containers \- Docker Docs, [https://docs.docker.com/engine/containers/run/](https://docs.docker.com/engine/containers/run/)
> 20. fuse mounts inside a container and AppArmor : r/docker \- Reddit, [https://www.reddit.com/r/docker/comments/13a1asr/fuse\_mounts\_inside\_a\_container\_and\_apparmor/](https://www.reddit.com/r/docker/comments/13a1asr/fuse_mounts_inside_a_container_and_apparmor/)
> 21. Confining Resources inside Docker Containers with AppArmor, [https://tbhaxor.com/confining-resources-inside-docker-containers-with-apparmor/](https://tbhaxor.com/confining-resources-inside-docker-containers-with-apparmor/)
> 22. FUSE inside Docker \- Stack Overflow, [https://stackoverflow.com/questions/48402218/fuse-inside-docker](https://stackoverflow.com/questions/48402218/fuse-inside-docker)
> 23. Documentation and example of CUSE ioctl restricted mode \#1263, [https://github.com/libfuse/libfuse/discussions/1263](https://github.com/libfuse/libfuse/discussions/1263)
> 24. FUSE Configuration | jzombie/sshfs-mac-docker \- DeepWiki, [https://deepwiki.com/jzombie/sshfs-mac-docker/5.2-fuse-configuration](https://deepwiki.com/jzombie/sshfs-mac-docker/5.2-fuse-configuration)
> 25. Backups and Archives, [https://wpollock.com/AUnix1/Backups.htm](https://wpollock.com/AUnix1/Backups.htm)
> 26. Support for fuse max read option · Issue \#1467 \- GitHub, [https://github.com/awslabs/mountpoint-s3/issues/1467](https://github.com/awslabs/mountpoint-s3/issues/1467)
> 27. Performance tuning best practices | Cloud Storage, [https://docs.cloud.google.com/storage/docs/cloud-storage-fuse/performance](https://docs.cloud.google.com/storage/docs/cloud-storage-fuse/performance)
> 28. Retrieve an Amazon S3 object that was deleted | AWS re:Post, [https://repost.aws/knowledge-center/s3-configuration-undelete](https://repost.aws/knowledge-center/s3-configuration-undelete)
> 29. Recover Deleted Files From DigitalOcean Spaces? \- SimpleBackups, [https://simplebackups.com/blog/digitalocean-spaces-accidental-deletion](https://simplebackups.com/blog/digitalocean-spaces-accidental-deletion)
> 30. How to Recover Deleted Objects from a Versioned S3 Bucket, [https://oneuptime.com/blog/post/2026-02-12-recover-deleted-objects-versioned-s3-bucket/view](https://oneuptime.com/blog/post/2026-02-12-recover-deleted-objects-versioned-s3-bucket/view)
> 31. How to Remove Delete Markers from Multiple Objects on Amazon, [https://stackoverflow.com/questions/32106094/how-to-remove-delete-markers-from-multiple-objects-on-amazon-s3-at-once](https://stackoverflow.com/questions/32106094/how-to-remove-delete-markers-from-multiple-objects-on-amazon-s3-at-once)
> 32. Managing versions in object storage \- RONIN BLOG, [https://blog.ronin.cloud/managing-versions-in-object-storage/](https://blog.ronin.cloud/managing-versions-in-object-storage/)
> 33. File system revision needs upgrade (or backend data is corrupted), [https://groups.google.com/g/s3ql/c/rLXKB8A30k4](https://groups.google.com/g/s3ql/c/rLXKB8A30k4)

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABUAAAAZCAYAAADe1WXtAAAAb0lEQVR4XmNgGAWjYPiCLiCWRBekFEwD4lR0QWqAJegC1AACQByCLogMuIBYggx8G4gnMeAI3zogvkIGfgPE/4H4KBAzMVAJ3Adif3RBcgHIVefRBSkFAUC8FV2QUrCMgYrehoEoBkiKGQWjAA0AAIkbF8BJdQl3AAAAAElFTkSuQmCC>
