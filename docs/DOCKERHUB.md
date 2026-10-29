# MapServer

OCI image of [MapServer](https://mapserver.org) built from source, with **Oracle Spatial** support, running as a **FastCGI server**. Maintained by the Geological Survey of Brazil (SGB/CPRM).

- **MapServer 8.6:** WMS, WFS, WCS and OGC API Features; Oracle Spatial, PostGIS, OGR/GDAL, Shapefile and FlatGeobuf inputs.
- **GDAL 3.12** with the drivers of the base image (Oracle, PostGIS, GeoPackage, Parquet/Arrow, OpenFileGDB, KML, Elasticsearch and OGC services), Oracle Instant Client 19, PROJ 9.6 and GEOS 3.13 (Debian trixie).
- **Self-healing workers:** `multiwatch` restarts any `mapserv` process that dies.
- **Non-root:** runs as `1000:0` and accepts arbitrary UIDs, such as OpenShift's.
- **Read-only root filesystem:** only `/tmp` needs to be writable.
- **Hardened build:** compiled with stack protector, `_FORTIFY_SOURCE=3` and full RELRO.
- **amd64 and arm64**, with SBOM and provenance attestations.

Source code, examples and documentation: <https://github.com/nds-cprm/mapserver-oci>

## Tags

Each tag starts with the **MapServer version** (`<version>` in the examples below), followed by suffixes that select the image:

| Suffix | Contents |
|---|---|
| none | Final image: the FastCGI server, without Python. |
| `-mapscript` | The same FastCGI server, with Python and **Python MapScript**. |
| `-devel` | Development image: toolchain, headers and the GDAL and MapServer source code, for debugging or building against MapServer. Runs as root. |
| `-YYYYMMDD` | Appended to any of the above (`<version>-YYYYMMDD`, `<version>-mapscript-YYYYMMDD`, `<version>-devel-YYYYMMDD`): one specific build, identified by its date (UTC). Never overwritten: a second build on the same day gets `.2`, `.3`... Use it, preferably with its digest, to pin an exact image or to roll back. |

The available versions are listed in the Tags tab. The tags without a date are moving: they are rebuilt whenever the base image [`ndscprm/gdal`](https://hub.docker.com/r/ndscprm/gdal) is updated, picking up Debian security fixes. There is no `latest` tag.

## Quick start

The image speaks **FastCGI on port 8080, not HTTP**. Put a web server with FastCGI support in front of it, on the same container network, and **do not publish port 8080** (see [Security](#security-and-runtime)).

```sh
docker network create mapserver
docker run -d --name mapserver --network mapserver \
  -v /path/to/mapfiles:/var/lib/mapserver:ro \
  docker.io/ndscprm/mapserver:<version>
```

nginx, on the same network:

```nginx
upstream mapserver {
    server mapserver:8080;
}

server {
    listen 8080;

    location ~ ^/mapserver(/|$) {
        fastcgi_split_path_info ^(/mapserver)(/.*)$;
        include fastcgi_params;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_pass mapserver;
    }
}
```

The image ships a sample mapfile (Esri's "World Countries Generalized", layer `countries`), reachable through the `DEFAULT` alias:

| Service | Request |
|---|---|
| WMS | `/mapserver?map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities` |
| OGC API Features | `/mapserver/DEFAULT/ogcapi/collections/countries/items?f=json` |

A complete Compose example with nginx is in [examples/](https://github.com/nds-cprm/mapserver-oci/tree/main/examples).

## Mapfiles and configuration

Mount your mapfiles and data over the **whole** `/var/lib/mapserver` directory, **read-only** (`:ro`, `read_only`, `readOnly: true`), and request them by path: `map=/var/lib/mapserver/<file>.map`. This hides the sample data, so `map=DEFAULT` stops working unless you provide `data/default.map` or your own aliases. On Kubernetes, use a ConfigMap for small mapfiles, a Secret for mapfiles holding database credentials and a PersistentVolumeClaim for large data, combined with a `projected` volume if needed.

The image's `mapserver.conf` (`/opt/geosgb/etc/mapserver.conf`):

- only accepts mapfiles under `/var/lib/mapserver` (`MS_MAP_PATTERN`) with the `.map` extension, and rejects `//`, `/../` and `,` in `map=`;
- has no default mapfile and disables WMS context files;
- defines the `DEFAULT` and `HEALTHCHECK` aliases.

The values in the `ENV` block of `mapserver.conf` **take precedence over the container environment**. To add aliases (`MAPS`) or other options, mount your own file over it, or ship it in the mapfiles volume and point `MAPSERVER_CONFIG_FILE` at it, where relative `MAPS` paths resolve from its directory. Start from the image's file, keep the pinned options and the `HEALTHCHECK` alias. `mapserver.conf` does **not** support `INCLUDE`.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `MAPSERVER_WORKERS` | `4` | Number of `mapserv` processes. |
| `MAPSERVER_FCGI_PORT` | `8080` | FastCGI port. |
| `MAPSERVER_CONFIG_FILE` | `/opt/geosgb/etc/mapserver.conf` | MapServer configuration file. |
| `MS_ERRORFILE` | unset: container log | Where MapServer errors go: unset, `stderr` (the web server's error log) or a file path. |
| `MS_DEBUGLEVEL` | unset | MapServer debug level, 0 to 5. |
| `FCGI_WEB_SERVER_ADDRS` | unset | Comma-separated list of exact IPs allowed to connect to the FastCGI port. |

The [MapServer](https://mapserver.org/environment_variables.html), [GDAL](https://gdal.org/user/configoptions.html) and [PROJ](https://proj.org/en/stable/usage/environmentvars.html) variables are also accepted.

## Security and runtime

- **FastCGI port:** whoever talks FastCGI directly to port 8080 can set any variable per request, including GDAL options. The MapServer options that choose which file is opened are pinned in `mapserver.conf`, but GDAL options cannot be pinned one by one. Keep port 8080 reachable **only by the web server**: no `-p 8080:8080` in production and, on Kubernetes, a `NetworkPolicy`. With a fixed web server IP, `FCGI_WEB_SERVER_ADDRS` adds another layer.
- **User:** `1000:0`. Arbitrary UIDs (`--user`, `runAsUser`) work: an nss_wrapper registers any UID missing from `/etc/passwd` at runtime.
- **Read-only mapfiles:** `/var/lib/mapserver` belongs to root, with no write access for anyone else, since MapServer loads any `.map` file in it. Always mount your volume read-only.
- **Read-only root:** supported (`--read-only`, `read_only: true`, `readOnlyRootFilesystem: true`) as long as `/tmp` is writable (`--tmpfs /tmp` or an `emptyDir`).
- **Healthcheck:** the `healthcheck` command sends a FastCGI request that renders an empty 1×1 PNG, independent of your mapfiles, and fails if no worker answers within 4 seconds. This catches stuck workers, which `multiwatch` does not restart. Podman ignores `HEALTHCHECK` in OCI-format images and Kubernetes never uses it, so declare it in each runtime:

  | Runtime | Where |
  |---|---|
  | `docker run` | The image's `HEALTHCHECK` (automatic) |
  | Compose | `healthcheck: { test: ["CMD", "healthcheck"] }` |
  | Podman | `--health-cmd healthcheck --health-on-failure restart`, or `HealthCmd=healthcheck` in Quadlet |
  | Kubernetes and OpenShift | `exec` probes with `command: ["healthcheck"]` |

- **Vulnerability scanning:** every build is scanned with Trivy and Grype before it is tagged.

## Testing without a web server

The image includes the `cgi-fcgi` client:

```sh
docker run -d --name ms docker.io/ndscprm/mapserver:<version>
docker exec ms env -i REQUEST_METHOD=GET SCRIPT_NAME=/mapserver \
  QUERY_STRING="map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities" \
  cgi-fcgi -bind -connect 127.0.0.1:8080
```

## Python MapScript

The `-mapscript` tag has MapScript installed in the `/opt/geosgb/venv` virtualenv (the `python` and `pip` on the `PATH`):

```sh
docker run --rm docker.io/ndscprm/mapserver:<version>-mapscript \
  python -c "import mapscript; print(mapscript.msGetVersion())"
```

In a derived image, install your packages with the shipped constraints file, so nothing replaces GDAL, numpy or MapScript:

```dockerfile
FROM docker.io/ndscprm/mapserver:<version>-mapscript
RUN pip install --no-cache-dir -c /opt/geosgb/share/mapserver/constraints.txt my-dependency
```

The GDAL Python utilities (`gdal_calc.py`, `import osgeo`) are only in the `-mapscript` and `-devel` tags. The native ones (`gdalinfo`, `ogr2ogr`) are in all of them.

## License

MapServer is released under the MIT-style MapServer license. As with any container image, this image also contains software under other licenses (Debian, GDAL, the Oracle Instant Client and their dependencies), and it is the user's responsibility to make sure their use complies with them.
