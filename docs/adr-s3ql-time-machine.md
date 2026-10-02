# S3QL Time Machine

**Background:**
A long time ago, and before I knew about the caveats that came with s3ql, I deployed a s3ql-formatted filesystem on AWS S3, intending to use it as a networked filesystem, and securely mount files in the cloud.
Now, I am trying to exit my data on AWS S3, because of costs. I no longer use the networking filesystem capabilities, but wish to recover my data.

I have all the credentials to access my AWS S3 buckets. I also have all the encryption credentials and passphrases for the s3ql encryption capabilities.
```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

I have all the credentials for AWS S3 and the S3QL Encryption Passphrases in the s3ql auth info file.
```
$ cat ./s3ql.authinfo
```

These are our target S3 buckets:
- s3://eu-central-1/eur-media
- s3://us-west-1/us-west-media
- s3://us-east-2/video-mount

An rsync backup of these buckets exist on the filesystem:
- /home/mwalther/projects/aws-s3-backup/eur-media
- /home/mwalther/projects/aws-s3-backup/us-west-media
- /home/mwalther/projects/aws-s3-backup/video-mount

S3FS is available on the system:
```
$ s3fs --version
Amazon Simple Storage Service File System V1.97 with OpenSSL
Copyright (C) 2010 Randy Rizun <rrizun@gmail.com>
License GPL2: GNU GPL version 2 <https://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
```

AWS CLI is available on the system:
```
$ aws --version
aws-cli/2.34.32 Python/3.14.7 Linux/7.2.4-arch1-2 source/x86_64.arch
```

S3QL is available natively on the system:
```
$ mount.s3ql --version
S3QL 6.2.2
```

Docker is available on the system:
```
$ docker --version
Docker version 29.8.1, build 4a63305d74
```

I made my rsync backup, and began attempting to mount the s3ql filesystem on AWS S3.

When I ran my mount command, it produced a filesystem revision error:
```
$ mount.s3ql s3://eu-central-1/eur-media /mnt/s3ql/eur-media/
Enter backend login:
Enter backend password:
Using 10 upload threads.
Autodetected 524160 file descriptors available for cache entries
Enter file system encryption passphrase:
ERROR: File system revision too old, please run `s3qladm upgrade` first.
```

I did some investigation of the filesystem revision error, and I found the layout metadata stored inside the S3 bucket was formatted using an older, incompatible version of S3QL.

I want to be careful and safe about the data I am recovering, so I enabled S3 Bucket Versioning on all buckets.

When I attempted to upgrade the S3QL filesystem, I was also blocked because I did not have a copy of the old S3QL binaries available.
```
$ s3qladm upgrade s3://eu-central-1/eur-media
Enter backend login:
Enter backend password:
Using 10 upload threads.
Enter file system encryption passphrase:
To upgrade the filesystem, first download file system metadata using the previous
version of S3QL (eg. by running fsck.s3ql)
```

I can not determine what the original version of s3ql that I used. When I attempt to download the read the s3ql metadata, the file is binary data and does not give me a hint of the version string.
```
$ aws s3 cp s3://eur-media/s3ql_metadata - --region eu-central-1 > /tmp/header.txt
$ cat /tmp/header.txt # outputs binary data, omitted for brevity
```

I am still interested in recovering this data in spite of the problems. I think if we spin up an isolated docker container using an older version of s3ql we can mount the old s3ql filesystem, inspect the data, and back it up.
```
$ docker run -it \
    --device /dev/fuse \
    -v ./pool:/pool \
    -v ./s3ql.authinfo:~/.s3ql/authinfo2 \
    --cap-add SYS_ADMIN \
    debian:bookworm-slim bash
# Inside the container, install s3ql, and using the authinfo2 credentials, run `mount.s3ql s3://eu-central-1/eur-media /pool/eur-media/`
# Exit the container and run `ls -la ./pool/eur-media/`
```

I think this operation can be easily encapsulated in a bash script, so that I can personally run the command:
```
$ s3ql-time-machine eur-media # mount the s3ql filesystem under ./pool
$ rsync -avz --progress ./pool/eur-media ~/projects/aws-s3-backup/decrypt/eur-media
```

**Objective:**
- Positively identify the correct s3ql version for the encrypted filesystems
- Recover the s3ql data in AWS S3 by mounting `eur-media`
- Non-destructive changes to the S3QL filesystem are crucial

**Related documents:**
- Environment Variables `./.env`
- s3ql git repository/source code `./s3ql-src`

**Goals:**
- Run a docker container that has the correct version of s3ql installed to mount the encrypted filesystem
- Document your container operations with the bare necessary system tools: bash scripts, Dockerfiles, environment variables, text files, etc.
- Read the unencrypted objects in the s3ql filesystem "in pain text"

**Non-Goals:**
- Installing a downgraded version of s3ql on the host system.
- Mutating the S3 data into an unrecoverable state.

**Scenarios:**


