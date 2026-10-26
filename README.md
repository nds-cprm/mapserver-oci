# MapServer Container Image

MapServer compilado a partir do código-fonte, com suporte a **Oracle Spatial (OCI)**, executado como **servidor FastCGI**.

Autor: Carlos Eduardo Mota

A imagem é construída sobre a imagem GDAL do SGB (`docker.io/ndscprm/gdal`) e inclui:

- MapServer 8.6.6 (WMS, WFS, WCS e OGC API; entradas Oracle Spatial, PostGIS, OGR/GDAL, Shapefile e FlatGeobuf);
- GDAL 3.12 com os drivers da imagem base (OCI, PostGIS, GeoPackage, Parquet/Arrow, OpenFileGDB, KML, Elasticsearch e serviços OGC);
- Oracle Instant Client 19 (basiclite);
- PROJ 9.6 e GEOS 3.13 (Debian 13 "trixie").

## Execução

A imagem fala **FastCGI na porta 8080**, não HTTP. Coloque na frente um servidor web ou proxy com suporte a FastCGI, apontando para `<container>:8080`.

```bash
docker run -d --name mapserver -p 8080:8080 \
  -v /caminho/dos/mapfiles:/var/lib/mapserver/maps:ro \
  docker.io/ndscprm/mapserver:8.6.6
```

Os workers do MapServer são gerenciados pelo `multiwatch` (atrás do `spawn-fcgi`): se um processo `mapserv` morrer, outro é iniciado automaticamente.

### Variáveis de ambiente

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `MAPSERVER_WORKERS` | `4` | Número de processos `mapserv` |
| `MAPSERVER_FCGI_PORT` | `8080` | Porta FastCGI |
| `MS_ERRORFILE` | (não definida: log do container) | Destino dos erros do MapServer (veja [Logs](#logs)) |
| `MAPSERVER_CONFIG_FILE` | `/opt/geosgb/etc/mapserver.conf` | Arquivo de configuração do MapServer |

Outras variáveis aceitas:
- MapServer: <https://mapserver.org/environment_variables.html>
- GDAL: <https://gdal.org/user/configoptions.html>
- PROJ: <https://proj.org/en/stable/usage/environmentvars.html>

## Mapfiles e configuração

O MapServer 8 exige um arquivo de configuração. O arquivo da imagem ([etc/mapserver.conf](etc/mapserver.conf)) define:

- **`MS_MAP_PATTERN "^/var/lib/mapserver/"`**: só são aceitos mapfiles dentro de `/var/lib/mapserver`, informados como `map=/var/lib/mapserver/...`.
- **Alias `DEFAULT`**: aponta para o mapfile de exemplo (`map=DEFAULT`).

Monte seus mapfiles e dados em `/var/lib/mapserver`, como no exemplo acima.

Os valores do bloco `ENV` do `mapserver.conf` **têm prioridade sobre as variáveis de ambiente do container**. Para mudar o padrão de caminhos, criar aliases (`MAPS`) ou definir outras opções, monte o seu próprio arquivo:

```bash
docker run ... -v ./mapserver.conf:/opt/geosgb/etc/mapserver.conf:ro docker.io/ndscprm/mapserver:8.6.6
```

Para a OGC API, a rota vai no caminho da URL (ex.: `/mapserver/DEFAULT/ogcapi`). O mapfile precisa ter:
- `oga_enable_request` e `oga_onlineresource` (a URL base usada nos links) no `WEB METADATA`;
- em cada camada publicada como coleção do OGC API Features: `TEMPLATE` (camada consultável), `gml_featureid` (campo identificador) e `gml_include_items` (atributos retornados).

### Exemplo incluído

Em `/var/lib/mapserver/data` há um mapfile de exemplo (`default.map`) com o shapefile "World Countries Generalized" da Esri (camada `countries`). Ele é publicado por:

| Serviço | Requisição |
|---------|------------|
| WMS (GetCapabilities, GetMap e GetFeatureInfo) | `/mapserver?map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities` |
| OGC API Features (JSON/GeoJSON e HTML) | `/mapserver/DEFAULT/ogcapi/collections/countries/items?f=json` |

As rotas consideram um proxy que encaminha `/mapserver` para o FastCGI.

## Logs

Destino dos erros do MapServer, conforme `MS_ERRORFILE`:

| `MS_ERRORFILE` | Destino |
|----------------|---------|
| não definida (padrão) | log do container (`docker logs`), uma linha por mensagem |
| `stderr` | stream de erro do protocolo FastCGI, gravado pelo servidor web na frente no log de erros dele |
| caminho de arquivo | o arquivo indicado |

O `docker logs` também mostra a inicialização e os eventos do `multiwatch` (ex.: worker reiniciado).
- Para mais detalhes, use `MS_DEBUGLEVEL` (0 a 5).

## Usuário e permissões

- **Usuário padrão:** a imagem roda como `1000:0`, sem privilégios. A imagem `-devel` continua como root.
- **UID arbitrário:** `docker run --user <uid>`, `runAsUser` no Kubernetes e OpenShift são suportados. Quando a UID não existe no `/etc/passwd` (caso do 1000), o entrypoint da imagem base cria um usuário virtual (`sgb`, variável `USER_NAME`) via `nss_wrapper`.
- **Escrita em `/var/lib/mapserver`:** o diretório (`HOME`) é gravável pelo grupo 0. Usuários com GID 0, que é o padrão nesses ambientes, podem escrever nele. Com outro GID, o `HOME` passa a ser `/tmp`.

## Testando sem servidor web

Use o cliente `cgi-fcgi` (pacote `libfcgi-bin`) a partir de outro container na mesma rede:

```bash
docker network create mstest
docker run -d --name ms --network mstest docker.io/ndscprm/mapserver:8.6.6
docker run --rm --network mstest debian:trixie-slim bash -c '
  apt-get -qq update && apt-get -qq install -y libfcgi-bin >/dev/null
  env -i REQUEST_METHOD=GET SCRIPT_NAME=/mapserver \
    QUERY_STRING="map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities" \
    cgi-fcgi -bind -connect ms:8080'
```

## Build

São publicadas duas tags por versão, como na imagem base GDAL:
- `ndscprm/mapserver:<versão>`: imagem final;
- `ndscprm/mapserver:<versão>-devel`: imagem de desenvolvimento, para depurar ou compilar código que dependa do MapServer.

A imagem `-devel` também roda o MapServer como FastCGI, com o mesmo `start.sh`, a mesma configuração e os mesmos dados de exemplo, mas com 1 worker por padrão. O comando padrão continua `python3`, então é preciso passar `/start.sh`:

```bash
docker run -d --name mapserver-devel -p 8080:8080 \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  docker.io/ndscprm/mapserver:8.6.6-devel /start.sh
# depurar o worker com gdb
docker exec -it mapserver-devel sh -c 'gdb -p $(pgrep -f "^/opt/geosgb/bin/mapserv")'
```

As duas tags são multiplataforma (`linux/amd64` e `linux/arm64`). O Docker escolhe sozinho a variante da máquina. Para construir uma arquitetura específica localmente, use `docker buildx build --platform linux/arm64 ...`; para isso, a imagem base também precisa existir nessa arquitetura.

```bash
# imagem final (FastCGI)
docker build -t docker.io/ndscprm/mapserver:8.6.6 .
# imagem de desenvolvimento: toolchain, headers e código-fonte do GDAL e do MapServer
docker build --target build -t docker.io/ndscprm/mapserver:8.6.6-devel .
```

### Build args

| Arg | Padrão | Descrição |
|-----|--------|-----------|
| `GDAL_VERSION` | `3.12.4` | Versão da imagem base `ndscprm/gdal` |
| `PYTHON_VERSION` | `3.12` | Versão do Python da imagem base |
| `MAPSERVER_VERSION` | `8.6.6` | Versão do MapServer |
| `MAPSERVER_SHA256` | SHA256 do `mapserver-8.6.6.tar.gz` | Atualizar junto com `MAPSERVER_VERSION` |

As tags `ndscprm/gdal:<GDAL_VERSION>-py<PYTHON_VERSION>-devel` (build) e `ndscprm/gdal:<GDAL_VERSION>-py<PYTHON_VERSION>` (release) precisam existir.

O código-fonte do MapServer é baixado da release no GitHub e verificado contra `MAPSERVER_SHA256`. Para obter o hash de uma nova versão:

```bash
curl -s https://api.github.com/repos/MapServer/MapServer/releases/tags/rel-8-6-6 \
  | jq -r '.assets[] | select(.name == "mapserver-8.6.6.tar.gz") | .digest'
```
