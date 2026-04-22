ARG VARIANT=ubuntu-24.04
FROM mcr.microsoft.com/devcontainers/base:${VARIANT}

ARG JULIA_VERSION=1.12.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tar \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
        amd64) julia_arch="x64" ;; \
        arm64) julia_arch="aarch64" ;; \
        *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
       esac \
    && major_minor="$(printf '%s' "${JULIA_VERSION}" | cut -d. -f1-2)" \
    && curl -fsSL "https://julialang-s3.julialang.org/bin/linux/${julia_arch}/${major_minor}/julia-${JULIA_VERSION}-linux-${julia_arch}.tar.gz" \
        -o /tmp/julia.tar.gz \
    && tar -xzf /tmp/julia.tar.gz -C /opt \
    && ln -s "/opt/julia-${JULIA_VERSION}/bin/julia" /usr/local/bin/julia \
    && rm /tmp/julia.tar.gz
