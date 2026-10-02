# Dockerfile for S3QL Time Machine
# Uses a stable Ubuntu 20.04 base where legacy dependencies (Python 3.8) can be built.
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies required for FUSE, legacy S3QL, and SQLite
RUN apt-get update && apt-get install -y \
    fuse3 \
    libfuse3-dev \
    cython3 \
    python3 \
    python3-pip \
    python3-dev \
    python3-setuptools \
    pkg-config \
    libsqlite3-dev \
    build-essential \
    libffi-dev \
    rsync \
    wget \
    curl \
    sqlite3 \
    cryptsetup \
    libcryptsetup-dev \
    psmisc \
    && rm -rf /var/lib/apt/lists/*

# Install specific older version of S3QL
# Defaults to 3.8.1 (Revision 24), but can be changed via build argument.
ARG S3QL_VERSION=3.8.1

# Install Python dependencies typically needed by legacy S3QL versions
RUN pip3 install --no-cache-dir apsw requests google-auth google-auth-oauthlib defusedxml cryptography pyfuse3 cython dugong

# Download and install the target legacy S3QL version
RUN curl -L -o s3ql-release-${S3QL_VERSION}.tar.gz https://github.com/s3ql/s3ql/archive/refs/tags/release-${S3QL_VERSION}.tar.gz \
    && tar -xzf s3ql-release-${S3QL_VERSION}.tar.gz \
    && cd s3ql-release-${S3QL_VERSION} \
    && python3 setup.py build_cython \
    && python3 setup.py install

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
