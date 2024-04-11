# https://libgeos.org/usage/download/
ARG DEBIAN_VERSION=bookworm
ARG PREFIX=/usr/local

# GEOS
ARG GEOS_VERSION=3.11.3
ARG GEOS_DOWNLOAD_URL="https://download.osgeo.org/geos/geos-${GEOS_VERSION}.tar.bz2"

# Proj
ARG PROJ_VERSION=9.1.1
ARG PROJ_DOWNLOAD_URL="https://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz"

# GDAL
ARG GDAL_VERSION=3.4.3
ARG GDAL_DOWNLOAD_URL=https://download.osgeo.org/gdal/${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.gz

# MapServer
ARG MAPSERVER_VERSION=7.6.5
ARG MAPSERVER_DOWNLOAD_URL=https://download.osgeo.org/mapserver/mapserver-${MAPSERVER_VERSION}.tar.gz

# Build mapserver and main dependencies (GEOS, PROJ, GDAL)
FROM docker.io/library/debian:${DEBIAN_VERSION} AS BUILD-OSGEO

ARG PREFIX

WORKDIR /tmp/geos

ARG GEOS_VERSION
ARG GEOS_DOWNLOAD_URL

# Basics
RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        build-essential \
        ca-certificates \
        cmake \
        wget \
        libcurl4-openssl-dev \
        libsqlite3-dev \
        sqlite3 && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# GEOS
RUN wget -q -O- ${GEOS_DOWNLOAD_URL} | tar jxvf - --directory ${PREFIX}/src && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DBUILD_DOCUMENTATION=OFF \
    ${PREFIX}/src/geos-${GEOS_VERSION} && \
    cmake --build . --target install && \
    ctest --output-on-failure

# Proj4
WORKDIR /tmp/proj

ARG PROJ_VERSION
ARG PROJ_DOWNLOAD_URL

# Proj4: https://proj.org/install.html#compilation-and-installation-from-source-code
# TODO: Why this image is soooo big?
RUN set -xe && wget -q --no-check-certificate -O- ${PROJ_DOWNLOAD_URL} | tar zxvf - --directory ${PREFIX}/src && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DBUILD_APPS=ON \
        -DBUILD_TESTING=OFF \
        -DENABLE_TIFF=OFF \
    ${PREFIX}/src/proj-${PROJ_VERSION} && \
    cmake --build . --target install && \
    rm -rf /tmp/*

# GDAL
WORKDIR /tmp/gdal

ARG GDAL_VERSION
ARG GDAL_DOWNLOAD_URL

# TODO: use a decision to check gdal version to build
RUN wget -q -O- ${GDAL_DOWNLOAD_URL} | tar -zxvf - && \
    cd gdal-${GDAL_VERSION} && \
    # Only GDAL3
    ./configure \
        --prefix=${PREFIX} \ 
        --disable-all-optional-drivers \
        --enable-driver-shape \
        --with-geos \
        --with-geotiff=internal \
        --with-hide-internal-symbols \
        --with-libtiff=internal \
        --with-libz=internal \
        --with-threads \
        --enable-static=NO \
        --without-java && \    
    make && \
    make install

# MapServer
ARG MAPSERVER_VERSION
ARG MAPSERVER_DOWNLOAD_URL

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        libpng-dev \
        libfreetype-dev \
        libjpeg-dev \
        libpq-dev \
        libfcgi-dev \
        libxml2-dev \
        pkg-config && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

SHELL [ "/bin/bash", "-o", "pipefail", "-c" ]

RUN wget -q -O- ${MAPSERVER_DOWNLOAD_URL} | tar zxvf - --directory ${PREFIX}/src && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
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
        -DWITH_GIF=OFF \
        -Wno-dev \
    ${PREFIX}/src/mapserver-${MAPSERVER_VERSION} && \
    cmake --build . --target install

SHELL [ "/bin/sh", "-c" ]

WORKDIR /var/lib/mapserver

COPY ./data ./data

RUN chmod -R g=u .


# Create FCGI version
ARG DEBIAN_VERSION

FROM docker.io/library/debian:${DEBIAN_VERSION}-slim AS RELEASE-FCGI

ARG PREFIX

COPY fcgi/start.sh /

COPY --from=BUILD-OSGEO ${PREFIX}/bin ${PREFIX}/bin
COPY --from=BUILD-OSGEO ${PREFIX}/lib ${PREFIX}/lib
COPY --from=BUILD-OSGEO ${PREFIX}/share ${PREFIX}/share

VOLUME [ "/var/lib/mapserver" ]

# https://linux.die.net/man/1/spawn-fcgi
RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        # proj + gdal
        sqlite3 \
        libcurl4 \
        # Mapserver
        libpng16-16 \
        libfreetype6 \
        libjpeg62-turbo \
        libpq5 \
        libfcgi0ldbl \
        libxml2 \
        fonts-liberation2 \
        # FCGI 
        spawn-fcgi \
        tini && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/* && \
    chmod +x /start.sh && \
    ldconfig

WORKDIR /var/lib/mapserver

COPY --from=BUILD-OSGEO /var/lib/mapserver .

ENV GDAL_DATA=${PREFIX}/share/gdal \
    PROJ_LIB=${PREFIX}/share/proj \
    MS_ERRORFILE=stderr

EXPOSE 8000

ENTRYPOINT [ "tini", "--" ]

CMD [ "/start.sh" ]



# Create Nginx version
ARG NGINX_VERSION=1.25.4
ARG DEBIAN_VERSION

FROM docker.io/nginxinc/nginx-unprivileged:${NGINX_VERSION}-${DEBIAN_VERSION} AS RELEASE-NGINX

ARG PREFIX

USER root

COPY nginx/99-spawn-mapserver.sh /docker-entrypoint.d/
COPY nginx/conf/default.conf /etc/nginx/conf.d/

COPY --from=BUILD-OSGEO ${PREFIX}/bin ${PREFIX}/bin
COPY --from=BUILD-OSGEO ${PREFIX}/lib ${PREFIX}/lib
COPY --from=BUILD-OSGEO ${PREFIX}/share ${PREFIX}/share

VOLUME [ "/var/lib/mapserver" ]

# https://linux.die.net/man/1/spawn-fcgi
RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        # proj + gdal
        sqlite3 \
        libcurl4 \
        # Mapserver
        libpng16-16 \
        libfreetype6 \
        libjpeg62-turbo \
        libpq5 \
        libfcgi0ldbl \
        libxml2 \
        fonts-liberation2 \
        # FCGI 
        spawn-fcgi && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/* && \
    chmod +x /docker-entrypoint.d/99-spawn-mapserver.sh && \
    ldconfig

WORKDIR /var/lib/mapserver

COPY --from=BUILD-OSGEO /var/lib/mapserver .

USER nginx

ENV GDAL_DATA=${PREFIX}/share/gdal \
    PROJ_LIB=${PREFIX}/share/proj \
    MS_ERRORFILE=stderr
