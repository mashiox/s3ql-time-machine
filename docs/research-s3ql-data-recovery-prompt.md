# Master Research Prompt: S3QL Encrypted Filesystem Architecture & Dockerized Legacy Data Recovery

**Subject:** S3QL Filesystem Internals, Encrypted AWS S3 Storage Architecture, and Non-Destructive Containerized Recovery ("S3QL Time Machine")

**Role:** You are a Senior Cloud Storage Architect, Linux FUSE Subsystem Engineer, and Data Recovery Specialist with deep expertise in S3QL, SQLite metadata schemas, AES-encrypted object storage, and containerized system administration.

**Context & Portfolio Integration:**
You are being provided with two core portfolio documents detailing a real-world S3QL recovery operation:

1. `s3ql troubleshooting.pdf`: Diagnostic logs and root-cause analysis of S3QL metadata version mismatches (`ERROR: File system revision too old`), `s3qladm upgrade` prerequisite blocks, and version-downgrade paths.
2. `adr-s3ql-time-machine.md`: An Architectural Decision Record (ADR) outlining an egress strategy to recover encrypted data from AWS S3 buckets (`s3://eu-central-1/eur-media`, `s3://us-west-1/us-west-media`, `s3://us-east-2/video-mount`) without upgrading the remote metadata or modifying the Arch Linux host system (running S3QL 6.2.2, Docker 29.8.1, AWS CLI 2.34).

---

### **Research & Technical Mastery Pillars**

#### **1. S3QL Architecture & Metadata Schema Evolution**

* **Object Mapping & Encryption:** Analyze how S3QL breaks files into compressed, deduplicated, and AES-encrypted block objects in S3, paired with a central SQLite metadata database (`s3ql_metadata`).
* **Revision Incompatibility:** Map the structural schema changes across S3QL releases (e.g., v2.x through v6.x). Explain why a newer `mount.s3ql` (e.g., 6.2.2) refuses to mount older metadata layouts and why `s3qladm upgrade` requires an older `fsck.s3ql` binary to "finalize" and clean the metadata prior to schema migration.
* **Header Inspection & Version Identification:** Develop Python and shell techniques to decompress/decrypt and inspect raw `s3ql_metadata` header objects directly from S3 when `aws s3 cp` outputs raw binary data, successfully extracting the exact legacy S3QL version string that formatted the bucket.

#### **2. Dockerized FUSE Isolation ("S3QL Time Machine")**

* **Containerized FUSE Mechanics:** Detail the security and kernel constraints for running FUSE inside Docker containers, specifically requiring `--device /dev/fuse` and `--cap-add SYS_ADMIN`.
* **Legacy Runtime Environment Construction:** Architect Dockerfiles (using base images like `debian:bookworm-slim`, `ubuntu`, or older Arch archives) that build or install specific historical versions of S3QL, its Python dependencies (`python-google-auth`, `python-requests`, `apsw`), and `cryptsetup`/`libtomcrypt` bindings.
* **Credential & Session Management:** Formulate secure mounts for host auth files (`~/.s3ql/authinfo2`) with strict permission enforcement (`0600`), mapping environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), and setting up local target mount pools (`./pool/<bucket>`).

#### **3. Non-Destructive Data Egress & Safety Guardrails**

* **S3 Bucket Versioning & Safety Hooks:** Document the procedure for verifying and leveraging AWS S3 Bucket Versioning to ensure all metadata operations remain 100% reversible in the event of an accidental write or unclean unmount.
* **Read-Only / Non-Mutating Mount Strategies:** Evaluate `mount.s3ql` flags and Docker volume bind-mount strategies to guarantee the recovery container treats the remote S3 bucket as a read-only source during the `rsync` extraction phase.
* **Data Verification & Integrity:** Formulate `rsync` and checksum verification pipelines (`rsync -avz --progress`) to copy unencrypted plain-text files from the FUSE mount point `./pool/<bucket>` to local backup storage (`~/projects/aws-s3-backup/decrypt/<bucket>`).

---

### **Strict Operational Constraints & Non-Goals**

> **EXCLUDED ACTIONS (Non-Goals):**
> * Do NOT downgrade or alter the host system's native S3QL package (Arch Linux running S3QL 6.2.2).
> * Do NOT execute destructive `s3qladm upgrade` commands directly against production buckets without an isolated containerized validation run and confirmed S3 versioning fallbacks.
> * Do NOT alter or mutate remote S3 objects into an unrecoverable or un-encrypted state on the live bucket.
>
>

---

### **Required Deliverables**

1. **S3QL Version Identification Script:** A lightweight script/command sequence to pull, decompress, and read the version header from an `s3ql_metadata` object stored in AWS S3.
2. **The "S3QL Time Machine" Docker Stack:**
* A clean, multi-version capable `Dockerfile` configured with FUSE support and S3QL legacy dependencies.
* A container entrypoint configuration that securely ingests `authinfo2` credentials and executes `mount.s3ql` or `fsck.s3ql`.


3. **The `s3ql-time-machine` Shell Automation:** A production-ready Bash script that:
* Takes a target bucket name (e.g., `eur-media`) as an argument.
* Spins up the FUSE-enabled Docker container.
* Mounts the encrypted S3QL filesystem to a local directory (`./pool/<bucket>`).
* Provides status output for running an unencrypted `rsync` extraction loop.


4. **Interactive Troubleshooting Runbook:** Step-by-step diagnostic procedures for handling lock files, unclean metadata states, FUSE permission errors inside Docker, and S3 versioning rollbacks.
