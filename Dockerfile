ARG GDAL_VERSION=3.12.4
ARG PYTHON_VERSION=3.12
# ARG DEBIAN_VERSION=trixie

ARG BASE_DIR=/opt/geosgb


FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel AS build

SHELL [ "/bin/bash", "-o", "pipefail", "-c" ]

ARG MAPSERVER_VERSION=8.6.6
# SHA256 of mapserver-${MAPSERVER_VERSION}.tar.gz, from the "digest" of the GitHub release asset
ARG MAPSERVER_SHA256=e908e76b65541042042e9c5e4ae16a131f064cf6d3c76e9542c89b25158968c9
ARG BASE_DIR

# Install deps
RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        # libpng-dev \
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
    # ORACLE_HOME is only read by cmake (WITH_ORACLESPATIAL); use the Instant Client shipped by the base image
    ORACLE_HOME=$(echo "${BASE_DIR}"/oracle/instantclient_*) && \
    test -d "$ORACLE_HOME" && \
    ( cd "$MAPSERVER_DIR/build" && \
    ORACLE_HOME="$ORACLE_HOME" cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${BASE_DIR} \
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
    cmake --build . --target install ) && \
    rm -rf "$MAPSERVER_DIR/build" && \
    ldconfig

SHELL [ "/bin/sh", "-c" ]

# WORKDIR /var/lib/mapserver

# COPY ./data ./data

# RUN chmod -R g=u .


# # Create FCGI version
# ARG DEBIAN_VERSION

# FROM docker.io/library/debian:${DEBIAN_VERSION}-slim AS RELEASE-FCGI

# ARG PREFIX
# ARG MAPSERVER_VERSION

# LABEL org.opencontainers.image.title "MapServer SGB/CPRM"
# LABEL org.opencontainers.image.description "Build de mapserver a partir do código fonte"
# LABEL org.opencontainers.image.vendor "SGB/CPRM"
# LABEL org.opencontainers.image.version "${MAPSERVER_VERSION}"
# LABEL org.opencontainers.image.source "https://github.com/nds-cprm/mapserver-oci"
# LABEL org.opencontainers.image.authors "Carlos Eduardo Mota <carlos.mota@sgb.gov.br>"

# COPY fcgi/start.sh /

# COPY --from=BUILD-OSGEO ${PREFIX}/bin ${PREFIX}/bin
# COPY --from=BUILD-OSGEO ${PREFIX}/lib ${PREFIX}/lib
# COPY --from=BUILD-OSGEO ${PREFIX}/share ${PREFIX}/share

# VOLUME [ "/var/lib/mapserver" ]

# # https://linux.die.net/man/1/spawn-fcgi
# RUN apt-get -y update && \
#     apt-get install -y --no-install-recommends --no-install-suggests \
#         # proj + gdal
#         sqlite3 \
#         libcurl4 \
#         # Mapserver
#         libpng16-16 \
#         libfreetype6 \
#         libjpeg62-turbo \
#         libpq5 \
#         libfcgi0ldbl \
#         libxml2 \
#         fonts-liberation2 \
#         # FCGI 
#         spawn-fcgi \
#         tini && \
#     apt-get -y autoremove && \
#     rm -rf /var/lib/apt/lists/* && \
#     chmod +x /start.sh && \
#     ldconfig

# WORKDIR /var/lib/mapserver

# COPY --from=BUILD-OSGEO /var/lib/mapserver .

# ENV GDAL_DATA=${PREFIX}/share/gdal \
#     PROJ_LIB=${PREFIX}/share/proj \
#     MS_ERRORFILE=stderr

# EXPOSE 8080

# ENTRYPOINT [ "tini", "--" ]

# CMD [ "/start.sh" ]



# # Create Nginx version
# ARG NGINX_VERSION
# ARG DEBIAN_VERSION

# FROM docker.io/nginxinc/nginx-unprivileged:${NGINX_VERSION}-${DEBIAN_VERSION} AS RELEASE-NGINX

# ARG PREFIX
# ARG MAPSERVER_VERSION

# LABEL org.opencontainers.image.title "MapServer SGB/CPRM"
# LABEL org.opencontainers.image.description "Build de mapserver a partir do código fonte"
# LABEL org.opencontainers.image.vendor "SGB/CPRM"
# LABEL org.opencontainers.image.version "${MAPSERVER_VERSION}"
# LABEL org.opencontainers.image.source "https://github.com/nds-cprm/mapserver-oci"
# LABEL org.opencontainers.image.authors "Carlos Eduardo Mota <carlos.mota@sgb.gov.br>"

# USER root

# COPY nginx/99-spawn-mapserver.sh /docker-entrypoint.d/
# COPY nginx/conf/default.conf /etc/nginx/conf.d/

# COPY --from=BUILD-OSGEO ${PREFIX}/bin ${PREFIX}/bin
# COPY --from=BUILD-OSGEO ${PREFIX}/lib ${PREFIX}/lib
# COPY --from=BUILD-OSGEO ${PREFIX}/share ${PREFIX}/share

# VOLUME [ "/var/lib/mapserver" ]

# # https://linux.die.net/man/1/spawn-fcgi
# RUN apt-get -y update && \
#     apt-get install -y --no-install-recommends --no-install-suggests \
#         # proj + gdal
#         sqlite3 \
#         libcurl4 \
#         # Mapserver
#         libpng16-16 \
#         libfreetype6 \
#         libjpeg62-turbo \
#         libpq5 \
#         libfcgi0ldbl \
#         libxml2 \
#         fonts-liberation2 \
#         # FCGI 
#         spawn-fcgi && \
#     apt-get -y autoremove && \
#     rm -rf /var/lib/apt/lists/* && \
#     chmod +x /docker-entrypoint.d/99-spawn-mapserver.sh && \
#     ldconfig

# WORKDIR /var/lib/mapserver

# COPY --from=BUILD-OSGEO /var/lib/mapserver .

# USER nginx

# ENV GDAL_DATA=${PREFIX}/share/gdal \
#     PROJ_LIB=${PREFIX}/share/proj \
#     MS_ERRORFILE=stderr
