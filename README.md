# Mapserver Container Image

Uma implementação personalizada do Mapserver, compilado diretamente do código fonte

Autor: Carlos Eduardo Mota

## Flavours:
- 7.6.5, 7.6.5-nginx: Mapserver embedded on Nginx
- 7.6.5-fcgi: Mapserver standalone running with spawn-fcgi

## Build Args
- DEBIAN_VERSION=bookworm
- PREFIX=/usr/local

### GEOS
- GEOS_VERSION=3.11.2
- GEOS_DOWNLOAD_URL="https://download.osgeo.org/geos/geos-${GEOS_VERSION}.tar.bz2"

### Proj
- PROJ_VERSION=9.1.1
- PROJ_DOWNLOAD_URL="https://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz"

### GDAL
- GDAL_VERSION=3.4.3
- GDAL_DOWNLOAD_URL=https://download.osgeo.org/gdal/${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.gz

### MapServer
- MAPSERVER_VERSION=7.6.5
- MAPSERVER_DOWNLOAD_URL=https://download.osgeo.org/mapserver/mapserver-${MAPSERVER_VERSION}.tar.gz


## Environment Variables
- PROJ: see https://proj.org/en/9.1/usage/environmentvars.html
- GDAL: see https://gdal.org/user/configoptions.html
- Mapserver: see https://mapserver.org/environment_variables.html


