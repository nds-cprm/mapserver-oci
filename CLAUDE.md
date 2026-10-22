# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) ao trabalhar neste repositório.

## Visão geral

Imagem de contêiner do **MapServer compilado a partir do código-fonte com suporte a Oracle Spatial (OCI)**, mantida pelo SGB/CPRM (`docker.io/ndscprm/mapserver`). Não há código de aplicação, testes nem linters.

O [Dockerfile](Dockerfile) tem **um único estágio ativo** (`build`): parte da imagem `docker.io/ndscprm/gdal:<GDAL>-py<PYTHON>-devel` e compila e instala o MapServer 8.6.6 em `/opt/geosgb`. Os blocos comentados no fim do arquivo (`RELEASE-FCGI`, `RELEASE-NGINX`) são restos do build antigo e não fazem parte da imagem; ignore-os, a não ser que a tarefa seja reativá-los.

Arquivos do repositório que **não são usados** pelo Dockerfile ativo (pertencem ao build antigo, MapServer 7.6.5, ainda no `HEAD`):
- [data/](data/): mapfile de exemplo (`default.map`, WMS "World Countries Generalized"), shapefile, `fonts.txt` e `symbols.sym`.
- [nginx/](nginx/): `99-spawn-mapserver.sh` (`spawn-fcgi` no socket `/tmp/mapserver.socket`) e `conf/default.conf` (`location /mapserver` → FastCGI).
- [fcgi/start.sh](fcgi/start.sh): `spawn-fcgi -p 8080 -n` em primeiro plano.
- [README.md](README.md): descreve o build antigo (bookworm, `PREFIX=/usr/local`, GEOS/PROJ/GDAL compilados, tags `7.6.5*`).
- [.github/workflows/docker-image.yml](.github/workflows/docker-image.yml) (só `workflow_dispatch`): faz build de `--target RELEASE-NGINX`, que não existe no Dockerfile ativo, então **o CI está quebrado**. Publica a tag fixa `ndscprm/mapserver:7.6.5-auto`, roda Docker Scout e envia o SARIF.

## Build

```bash
docker build -t ndscprm/mapserver:testing .
docker run --rm ndscprm/mapserver:testing mapserv -v
# esperado: MapServer version 8.6.6 PROJ version 9.6 GDAL version 3.12 ... SUPPORTS=FASTCGI ... INPUT=ORACLESPATIAL ...
```

A imagem resultante é a própria imagem de desenvolvimento (cerca de 2,7 GB, com toolchain, headers e código-fonte). Ela herda o `CMD ["python3"]` da base e não tem `EXPOSE`, servidor FastCGI nem mapfile.

## Dockerfile (estágio `build`)

1. `ARG` globais: `GDAL_VERSION=3.12.4`, `PYTHON_VERSION=3.12`, `BASE_DIR=/opt/geosgb`. `GDAL_VERSION` e `PYTHON_VERSION` montam a tag da base no `FROM` (`gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel`) e precisam corresponder a uma tag publicada.
2. `SHELL` com `bash -o pipefail` durante o build, voltando para `/bin/sh -c` no final.
3. apt: instala `libfreetype-dev` e `libfcgi-dev`. Os demais headers (libpng, libjpeg, libpq, libxml2, PROJ, GEOS) já vêm da base.
4. MapServer:
   - baixa `mapserver-${MAPSERVER_VERSION}.tar.gz` da release do GitHub (tag `rel-X-Y-Z`, derivada com `${MAPSERVER_VERSION//./-}`, por isso o `RUN` precisa do bash), verifica com `sha256sum -c` contra `MAPSERVER_SHA256` e extrai em `${BASE_DIR}/src` (mesma convenção da base de manter o código-fonte);
   - `ORACLE_HOME` é uma variável local do `RUN`, descoberta com `echo ${BASE_DIR}/oracle/instantclient_*` (o build falha se não for um diretório) e passada só para o `cmake`. O MapServer lê essa variável apenas na configuração (`$ENV{ORACLE_HOME}` no `FindORACLE.cmake`); em runtime as bibliotecas do Oracle são encontradas pelo `ld.so.conf.d` da base, então não é preciso `ENV` na imagem;
   - compila com CMake (`Release`) num subshell `( cd build && ... )` e instala em `${BASE_DIR}`; depois remove só o diretório `build/` (o código-fonte fica) e roda `ldconfig`. O `mapserv` também tem `RUNPATH=/opt/geosgb/lib`;
   - fica **sem** cURL, Cairo/SVG-Cairo, HarfBuzz, FriBiDi, GIF, SOS, Protobuf-c e clientes WMS/WFS;
   - fica **com** libxml2 e Oracle Spatial.

**Ao trocar `MAPSERVER_VERSION`, atualize `MAPSERVER_SHA256`.** O MapServer não publica checksums nem assinaturas. O valor vem do `digest` que o GitHub calcula para o asset da release. Para conferir, compare com o mesmo arquivo no espelho oficial `download.osgeo.org`:

```bash
curl -s https://api.github.com/repos/MapServer/MapServer/releases/tags/rel-8-6-6 | jq -r '.assets[] | select(.name == "mapserver-8.6.6.tar.gz") | .digest'
curl -sL https://download.osgeo.org/mapserver/mapserver-8.6.6.tar.gz | sha256sum
```
## Imagem base (`ndscprm/gdal:*-devel`)

Fatos verificados na tag `3.12.4-py3.12-devel` que afetam este projeto:

- `python:3.12-trixie` (**Debian 13**): os pacotes de runtime seguem a transição `t64` (ex.: `libpng16-16t64`).
- `/opt/geosgb` contém `bin`, `include`, `lib`, `share`, `src/gdal-3.12.4`, `venv` (bindings Python do GDAL) e `oracle/instantclient_19_32` (basiclite + SDK). Só a variante `-devel` tem headers e o SDK do Oracle, por isso o build parte dela.
- Só o GDAL é compilado. PROJ 9.6 e GEOS 3.13 vêm dos pacotes do Debian.
- Bibliotecas sem RPATH: `/opt/geosgb/lib` e o diretório do Oracle estão em `/etc/ld.so.conf.d/`.
- `ENV`: `GDAL_DATA=/opt/geosgb/share/gdal`, `VIRTUAL_ENV=/opt/geosgb/venv` e `PATH` com `/opt/geosgb/venv/bin` e `/opt/geosgb/bin` na frente.
- A imagem não tem `ENTRYPOINT` e tem `CMD ["python3"]`. Versões mais novas da base podem trazer `/docker-entrypoint.sh` + `/docker-entrypoint.d/`, que colidem com os caminhos de mesmo nome da `nginx-unprivileged`.
- Para usar o `gdb`: `docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined ...`.

## Convenções

- Versões como `ARG` globais no topo, re-declarados no estágio que os usa.
- Cada `RUN` com apt faz `update`, `install --no-install-recommends --no-install-suggests`, `autoremove` e `rm -rf /var/lib/apt/lists/*`.
- Comentários no Dockerfile em inglês; documentação em português.
