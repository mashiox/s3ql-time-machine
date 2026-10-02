# S3QL Time Machine: Troubleshooting Runbook

## 1. FUSE Permission Errors in Docker
**Symptom:** `mount.s3ql` fails with `fusermount: mount failed: Operation not permitted` or `/dev/fuse: Operation not permitted`.
**Resolution:**
- Ensure the container is run with `--device /dev/fuse`.
- Ensure `--cap-add SYS_ADMIN` is passed.
- Ensure Docker volume mounts for the mount point use `:shared` propagation (e.g. `-v $(pwd)/pool:/pool:shared`).
- If you are on an OS with AppArmor (like Ubuntu), ensure `--security-opt apparmor:unconfined` is applied.

## 2. Unclean File System State (Lock Found)
**Symptom:** `mount.s3ql` refuses to mount because it detects an existing lock from an unclean unmount.
**Resolution:**
- **CRITICAL:** DO NOT run `fsck.s3ql` on your Arch Linux host running modern S3QL. It will attempt to update the metadata format and might corrupt it.
- Spin up the S3QL Time Machine container via the `s3ql-time-machine.sh` script (it will stay asleep).
- Execute the legacy fsck inside the container:
  `docker exec -it s3ql_mount_<bucket> fsck.s3ql s3://<bucket_name>`
- Once `fsck` has successfully repaired and cleaned the filesystem state, retry the mount process.

## 3. Metadata Revision Mismatches (File System Revision Too Old)
**Symptom:** `ERROR: File system revision too old`
**Resolution:**
- You are trying to mount a legacy bucket using a newer version of S3QL than what formatted it.
- Run `python3 s3ql_version_id.py <bucket_name>` to attempt identifying the revision via AWS S3 object headers.
- If the script cannot decrypt the exact revision, observe the revision number in the `ERROR:` output. 
- Map the revision to the required S3QL version (e.g., Revision 24 = 3.8.1, Revision 25 = 4.0.0).
- Pass the correct version as the second argument to the shell automation script: `./s3ql-time-machine.sh eur-media 3.8.1`.

## 4. Accidental Remote Mutation & S3 Versioning Fallback
**Symptom:** You accidentally ran a newer `fsck.s3ql` or `s3qladm upgrade` against the bucket and corrupted the metadata.
**Resolution:**
- All S3QL operations interact with the object store. If AWS S3 Bucket Versioning was enabled (which is strongly recommended):
  1. Access the AWS Console or use the AWS CLI.
  2. Locate the `s3ql_metadata` object (and `s3ql_params` if applicable).
  3. Find the previous version ID of these objects corresponding to the timestamp *before* the mutation.
  4. Restore the older version of the object (copy the older version over the current version).
  5. Repeat the mount attempt strictly using the Time Machine legacy container.
