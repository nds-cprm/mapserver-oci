ARG GDAL_VERSION=3.12.4
ARG PYTHON_VERSION=3.12

ARG BASE_DIR=/opt/geosgb

ARG MAPSERVER_VERSION=8.6.6
# SHA256 of mapserver-${MAPSERVER_VERSION}.tar.gz, from the "digest" of the GitHub release asset
ARG MAPSERVER_SHA256=e908e76b65541042042e9c5e4ae16a131f064cf6d3c76e9542c89b25158968c9


FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel AS build

SHELL [ "/bin/bash", "-o", "pipefail", "-c" ]

ARG MAPSERVER_VERSION
ARG MAPSERVER_SHA256
ARG BASE_DIR

# Install deps
RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        libfreetype-dev \
        libfcgi-dev && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# Compile and install Mapserver
RUN MAPSERVER_URL=https://github.com/MapServer/MapServer/releases/download/rel-${MAPSERVER_VERSION//./-}/mapserver-${MAPSERVER_VERSION}.tar.gz && \
    wget -q "${MAPSERVER_URL}" && \
    echo "${MAPSERVER_SHA256}  mapserver-${MAPSERVER_VERSION}.tar.gz" | sha256sum -c - && \
    # keep the source tree in the image for debugging and building GDAL-dependent code
    mkdir -p "${BASE_DIR}/src" && \
    tar -zxf "mapserver-${MAPSERVER_VERSION}.tar.gz" -C "${BASE_DIR}/src" && \
    rm "mapserver-${MAPSERVER_VERSION}.tar.gz" && \
    MAPSERVER_DIR=${BASE_DIR}/src/mapserver-${MAPSERVER_VERSION} && \
    mkdir -p "$MAPSERVER_DIR/build" && \
    # line-buffer MS_ERRORFILE when it is a file/FIFO (fully buffered by default), so each message is
    # written at once and messages from concurrent workers don't interleave (see fcgi/start.sh)
    sed -i 's|^\( *\)debuginfo->debug_mode = MS_DEBUGMODE_FILE;|&\n\1setvbuf(debuginfo->fp, NULL, _IOLBF, 0);|' "$MAPSERVER_DIR/src/mapdebug.c" && \
    grep -q "setvbuf(debuginfo->fp, NULL, _IOLBF, 0);" "$MAPSERVER_DIR/src/mapdebug.c" && \
    # ORACLE_HOME is only read by cmake (WITH_ORACLESPATIAL); use the Instant Client shipped by the base image
    ORACLE_HOME=$(echo "${BASE_DIR}"/oracle/instantclient_*) && \
    test -d "$ORACLE_HOME" && \
    ( cd "$MAPSERVER_DIR/build" && \
    ORACLE_HOME="$ORACLE_HOME" cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${BASE_DIR} \
        # GNUInstallDirs would default to /etc/opt/... for an /opt prefix
        -DMAPSERVER_CONFIG_FILE=${BASE_DIR}/etc/mapserver.conf \
        -DWITH_CLIENT_WFS=OFF \
        -DWITH_CLIENT_WMS=OFF \
        -DWITH_CURL=OFF \
        -DWITH_SOS=OFF \
        -DWITH_SVGCAIRO=OFF \
        -DWITH_PROTOBUFC=OFF \
        -DWITH_FRIBIDI=OFF \
        -DWITH_HARFBUZZ=OFF \
        -DWITH_CAIRO=OFF \
        -DWITH_LIBXML2=ON \
        -DWITH_ORACLESPATIAL=ON \
        -DWITH_GIF=OFF \
        -Wno-dev \
    .. && \
    cmake --build . --target install && \
    # list of installed files, used by the staging stage to pick MapServer out of ${BASE_DIR}
    cp install_manifest.txt "${BASE_DIR}/share/mapserver/install_manifest.txt" ) && \
    rm -rf "$MAPSERVER_DIR/build" && \
    ldconfig

SHELL [ "/bin/sh", "-c" ]


# Throwaway stage: MapServer files only (GDAL and Oracle come with the release base image),
# stripped, plus the Debian packages they link against
FROM build AS staging

SHELL [ "/bin/bash", "-o", "pipefail", "-c" ]

ARG BASE_DIR

# Copy the files listed in the cmake install manifest to /tmp/mapserver, dropping build-only files
RUN mkdir /tmp/mapserver && \
    tar -cf - -P --files-from="${BASE_DIR}/share/mapserver/install_manifest.txt" | tar -xf - -P --transform 's|^/|/tmp/mapserver/|' && \
    rm -rf \
        "/tmp/mapserver${BASE_DIR}/include" \
        "/tmp/mapserver${BASE_DIR}/lib/pkgconfig" \
        "/tmp/mapserver${BASE_DIR}/share/mapserver/cmake" && \
    find /tmp/mapserver -type f \
        -exec sh -c 'file -b "$1" | grep -q "^ELF"' _ {} \; \
        -exec strip --strip-debug {} +

# Runtime packages: every shared library linked by MapServer outside ${BASE_DIR}, resolved to its real
# path and mapped to the Debian package that owns it (most of them are already in the release image).
# Fails if a library is missing or not owned by any package (e.g. something under /usr/local).
RUN find /tmp/mapserver -type f \
        -exec sh -c 'file -b "$1" | grep -q "^ELF"' _ {} \; -print0 | \
        xargs -0 -n1 ldd > /tmp/ldd.txt && \
    if grep 'not found' /tmp/ldd.txt; then exit 1; fi && \
    awk '$2 == "=>" && $3 ~ /^\// { print $3 }' /tmp/ldd.txt | xargs realpath | sort -u | \
        grep -v "^${BASE_DIR}/" > /tmp/runtime-libs.txt && \
    while read -r lib; do \
        dpkg -S "$lib" 2>/dev/null || dpkg -S "${lib#/usr}" || { echo "No package owns $lib" >&2; exit 1; }; \
    done < /tmp/runtime-libs.txt | sed 's/: .*//' | sort -u > /tmp/runtime-packages.txt && \
    cat /tmp/runtime-packages.txt

# Sample data with deterministic modes (group-writable, nothing executable), regardless of the checkout umask
# (copied as /tmp/mapserver-home/data so that data/ itself is part of the content and keeps its mode)
COPY data /tmp/mapserver-home/data
RUN find /tmp/mapserver-home -type d -exec chmod 775 {} + && \
    find /tmp/mapserver-home -type f -exec chmod 664 {} +

SHELL [ "/bin/sh", "-c" ]


# MapServer as a FastCGI server (multiwatch-managed workers behind spawn-fcgi)
FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION} AS release

ARG BASE_DIR
ARG MAPSERVER_VERSION

LABEL org.opencontainers.image.title="MapServer SGB/CPRM" \
      org.opencontainers.image.description="MapServer FastCGI compilado a partir do código fonte, com suporte a Oracle Spatial" \
      org.opencontainers.image.vendor="SGB/CPRM" \
      org.opencontainers.image.version="${MAPSERVER_VERSION}" \
      org.opencontainers.image.source="https://github.com/nds-cprm/mapserver-oci" \
      org.opencontainers.image.authors="Carlos Eduardo Mota <carlos.mota@sgb.gov.br>"

RUN --mount=type=bind,from=staging,source=/tmp/runtime-packages.txt,target=/tmp/runtime-packages.txt \
    apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        $(cat /tmp/runtime-packages.txt) \
        # used by data/fonts.txt
        fonts-liberation \
        multiwatch \
        spawn-fcgi && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

COPY --from=staging /tmp/mapserver/ /
COPY etc/mapserver.conf ${BASE_DIR}/etc/mapserver.conf
COPY --chmod=755 fcgi/start.sh /start.sh

# non-root users created at startup (arbitrary UID, nss_wrapper) run with GID 0: let them write to HOME
RUN ldconfig && \
    install -d -m 775 /var/lib/mapserver

COPY --from=staging /tmp/mapserver-home/ /var/lib/mapserver/

WORKDIR /var/lib/mapserver

# MS_ERRORFILE is left unset: fcgi/start.sh then sends MapServer errors to the container log
ENV MAPSERVER_FCGI_PORT=8080 \
    MAPSERVER_WORKERS=4 \
    HOME=/var/lib/mapserver

EXPOSE 8080

# ENTRYPOINT (/docker-entrypoint.sh) is inherited from the base image
CMD [ "/start.sh" ]
