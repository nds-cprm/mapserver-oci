# MapServer Container Image

MapServer compilado a partir do código-fonte, com suporte a **Oracle Spatial (OCI)**, executado como **servidor FastCGI**.

Autor: Carlos Eduardo Mota

A imagem é construída sobre a imagem GDAL do SGB (`docker.io/ndscprm/gdal`) e inclui:

- MapServer 8.6.6 (WMS, WFS, WCS e OGC API; entradas Oracle Spatial, PostGIS, OGR/GDAL, Shapefile e FlatGeobuf);
- GDAL 3.12 com os drivers da imagem base (OCI, PostGIS, GeoPackage, Parquet/Arrow, OpenFileGDB, KML, Elasticsearch e serviços OGC);
- Oracle Instant Client 19 (basiclite);
- PROJ 9.6 e GEOS 3.13 (Debian 13 "trixie").

A imagem final não tem Python (base `ndscprm/gdal:<versão>-nopy`): os utilitários Python do GDAL (`gdal_calc.py`, `import osgeo` etc.) só estão nas imagens `-mapscript` e `-devel`. Os utilitários nativos (`gdalinfo`, `ogr2ogr` etc.) estão em todas.

## Execução

A imagem fala **FastCGI na porta 8080**, não HTTP. Coloque na frente um servidor web ou proxy com suporte a FastCGI, apontando para `<container>:8080`, na mesma rede de containers. **Não publique a porta 8080** (veja [Porta FastCGI](#porta-fastcgi)):

```bash
docker network create mapserver
docker run -d --name mapserver --network mapserver \
  -v /caminho/dos/mapfiles:/var/lib/mapserver:ro \
  docker.io/ndscprm/mapserver:8.6.6
# o servidor web, na mesma rede, aponta para mapserver:8080
```

Um exemplo completo com o nginx na frente, em Docker Compose, está em [examples/](examples/README.md).

Os workers do MapServer são gerenciados pelo `multiwatch` (atrás do `spawn-fcgi`): se um processo `mapserv` morrer, outro é iniciado automaticamente.

### Porta FastCGI

No FastCGI, o ambiente que o MapServer e o GDAL leem em cada requisição é o conjunto de **parâmetros FastCGI** daquela requisição. O servidor web só envia os parâmetros do `fastcgi_params` e os cabeçalhos HTTP como `HTTP_*`, então um cliente HTTP não consegue mudar opções. Mas quem fala FastCGI direto com a porta 8080 pode mandar qualquer variável, como `MS_MAP_BAD_PATTERN`, `MS_MAPFILE` ou opções do GDAL (`GDAL_HTTP_PROXY` etc.).

- As opções do MapServer que decidem qual arquivo é aberto estão fixadas no bloco `ENV` do `mapserver.conf` (veja [Mapfiles e configuração](#mapfiles-e-configuração)), que tem prioridade sobre o ambiente.
- As opções do GDAL não podem ser fixadas uma a uma. Por isso a porta 8080 deve ficar acessível **só ao servidor web**: sem `-p 8080:8080` (ou `ports:` no Compose) em produção, e, no Kubernetes, com uma `NetworkPolicy` que só libere o pod do servidor web.
- Quando o servidor web tem IP fixo, a variável `FCGI_WEB_SERVER_ADDRS` (da `libfcgi`) limita as conexões aceitas a uma lista de IPs, separados por vírgula: `-e FCGI_WEB_SERVER_ADDRS=10.0.0.5,10.0.0.6`. Conexões de outros endereços são fechadas sem resposta. A lista aceita só IPs exatos, sem faixas, então não serve quando o IP do servidor web muda a cada início.

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
- **Alias `HEALTHCHECK`**: usado pelo [healthcheck](#healthcheck) (um PNG vazio de 1×1, sem dados).
- **Opções fixadas contra parâmetros FastCGI** (veja [Porta FastCGI](#porta-fastcgi)), com os valores padrão do MapServer quando ele tem um:
  - `MS_MAP_BAD_PATTERN`: recusa `//`, `/../` e `,` no `map=`;
  - `MS_MAPFILE_PATTERN "\.map$"`: só abre arquivos `.map`;
  - `MS_MAPFILE ""`: não há mapfile padrão; um pedido sem `map=` falha com `Filename validation failed`;
  - `MS_CONTEXT_PATTERN "^$"` e `MS_CONTEXT_BAD_PATTERN`: o parâmetro `context=` (arquivos de contexto WMS) fica desligado.

Monte seus mapfiles e dados em `/var/lib/mapserver` (veja [Seus mapfiles](#seus-mapfiles-volume-configmap-ou-secret)).

Os valores do bloco `ENV` do `mapserver.conf` **têm prioridade sobre as variáveis de ambiente do container**. Para mudar o padrão de caminhos, criar aliases (`MAPS`) ou definir outras opções, monte o seu próprio arquivo:

```bash
docker run ... -v ./mapserver.conf:/opt/geosgb/etc/mapserver.conf:ro docker.io/ndscprm/mapserver:8.6.6
```

Parta do arquivo da imagem e mantenha as opções fixadas contra parâmetros FastCGI. Nas expressões regulares, o leitor do `mapserver.conf` converte `\\` em `\` e mantém uma `\` seguida de outro caractere. Como o MapServer usa PCRE2, onde `[/\]` é uma classe não fechada, escreva `\\\\` para uma barra invertida dentro de `[...]` (como no `MS_MAP_BAD_PATTERN` da imagem) e `\.` para um ponto literal. Um padrão inválido não dá erro na inicialização: todo pedido com `map=` passa a falhar com `fails to validate`.

O `mapserver.conf` **não aceita `INCLUDE`**, nem dentro de `MAPS`. O MapServer não dá erro: `INCLUDE "arquivo"` vira um alias chamado `INCLUDE`, e o conteúdo do arquivo é ignorado. O `INCLUDE` só funciona dentro dos mapfiles. Para manter os aliases junto dos mapfiles, use o [`mapserver.conf` no volume](#mapserverconf-no-volume).

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

Esse mapfile é só uma demonstração, para a imagem responder logo ao subir. Em produção, o `/var/lib/mapserver` inteiro é substituído pelos seus mapfiles, o que esconde o exemplo.

### Seus mapfiles (volume, ConfigMap ou Secret)

Monte um volume, ConfigMap ou Secret sobre o diretório **inteiro** `/var/lib/mapserver`, **somente leitura**:

- Os mapfiles são pedidos por caminho: `map=/var/lib/mapserver/<arquivo>.map`. Os caminhos relativos do mapfile (`SHAPEPATH`, `INCLUDE`, `FONTSET`, `SYMBOLSET`) partem do diretório dele.
- O exemplo (`data/`) fica escondido. O `map=DEFAULT` passa a falhar (`msLoadMap(): Unable to access file. (/var/lib/mapserver/data/default.map)`), a menos que você ponha um mapfile em `data/default.map` ou defina seus aliases num `mapserver.conf` próprio. O `fonts.txt` e o `symbols.sym` do exemplo também somem: traga os seus, se o mapfile usar fontes ou símbolos. As fontes Liberation estão instaladas em `/usr/share/fonts/truetype/liberation/`.
- O healthcheck não depende desse diretório (o mapfile dele fica em `/opt/geosgb/etc`).
- O `HOME` continua sendo `/var/lib/mapserver`, sem escrita. Nada na imagem precisa gravar nele.
- **Monte sempre somente leitura** (`:ro`, `read_only`, `readOnly: true`): o MapServer carrega qualquer `.map` dentro de `/var/lib/mapserver`, então o processo dele não pode conseguir gravar ali. A imagem não dá essa escrita, mas um volume gravável daria. Por exemplo, um diretório do host do usuário de UID 1000, o mesmo UID do container.

Com Docker ou Compose:

```bash
docker run ... -v ./mapserver:/var/lib/mapserver:ro docker.io/ndscprm/mapserver:8.6.6
```

No Kubernetes:

- **ConfigMap**: mapfiles e arquivos de texto pequenos, até 1 MiB no total. Subdiretórios são criados com `items[].path`, ex.: `path: data/default.map`.
- **Secret**: mapfiles com credenciais, como o `CONNECTION` de uma camada Oracle ou PostGIS.
- **PersistentVolumeClaim**: dados grandes (shapefiles, rasters), montado com `readOnly: true`.

ConfigMaps e Secrets são sempre montados somente leitura. Para juntar mais de um no mesmo diretório, use um volume `projected`:

```yaml
spec:
  containers:
    - name: mapserver
      image: docker.io/ndscprm/mapserver:8.6.6
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
      volumeMounts:
        - name: mapfiles
          mountPath: /var/lib/mapserver
          readOnly: true
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: mapfiles
      projected:
        sources:
          # kubectl create configmap mapserver-mapfiles --from-file=maps/
          - configMap:
              name: mapserver-mapfiles
          # mapfile com o CONNECTION (usuário e senha) do Oracle
          - secret:
              name: mapserver-oracle
              items:
                - key: oracle.map
                  path: oracle.map
    - name: tmp
      emptyDir: {}
```

#### `mapserver.conf` no volume

O `mapserver.conf` pode ir no mesmo volume, ConfigMap ou Secret dos mapfiles, apontado pela variável `MAPSERVER_CONFIG_FILE`. Em `MAPS`, um caminho relativo parte do diretório do `mapserver.conf`. Assim, os aliases ficam junto dos mapfiles e o volume fica autocontido:

```
/var/lib/mapserver/
├── mapserver.conf
└── geologia/
    └── geologia.map          # map=GEOLOGIA
```

```bash
docker run ... -v ./mapserver:/var/lib/mapserver:ro \
  -e MAPSERVER_CONFIG_FILE=/var/lib/mapserver/mapserver.conf \
  docker.io/ndscprm/mapserver:8.6.6
```

No Kubernetes, é uma variável `env` do container: `name: MAPSERVER_CONFIG_FILE`, `value: /var/lib/mapserver/mapserver.conf`.

O `mapserver.conf` é lido uma vez, quando cada worker inicia. Depois de mudá-lo, reinicie o container. Um cliente FastCGI não consegue trocá-lo por parâmetro: o caminho lido na inicialização tem prioridade sobre o ambiente de cada requisição.

Parta desta cópia comentada do [etc/mapserver.conf](etc/mapserver.conf) da imagem:

```
#
# mapserver.conf para o volume /var/lib/mapserver, usado com
# MAPSERVER_CONFIG_FILE=/var/lib/mapserver/mapserver.conf
# Referência: https://mapserver.org/mapfile/config.html
#
# Strings: o leitor deste arquivo converte \\ em \ e mantém uma \ seguida de
# outro caractere. As regex são PCRE2, onde [/\] é uma classe não fechada:
# escreva \\\\ para uma barra invertida dentro de [...] e \. para um ponto.
# Um padrão inválido não dá erro na inicialização: todo map= passa a falhar.
#
# Não há INCLUDE neste arquivo: ele seria lido como um alias de MAPS.
#
CONFIG
  ENV
    #
    # Opções fixadas contra parâmetros FastCGI: no FastCGI, o ambiente que o
    # MapServer lê a cada requisição são os parâmetros dela, então um cliente
    # que fale FastCGI direto com a porta 8080 define qualquer opção que não
    # esteja aqui. Os valores daqui têm prioridade. Não remova nenhuma.
    #

    # map= por caminho só dentro de /var/lib/mapserver (ex.: map=/var/lib/mapserver/geologia/geologia.map)
    MS_MAP_PATTERN "^/var/lib/mapserver/"
    # padrão do MapServer: recusa "//", "/../" e "," no map=
    MS_MAP_BAD_PATTERN "[/\\\\]{2}|[/\\\\]?\.+[/\\\\]|,"
    # só abre arquivos .map
    MS_MAPFILE_PATTERN "\.map$"
    # sem mapfile padrão: um pedido sem map= falha ("Filename validation failed").
    # Sem esta linha, um cliente poderia escolher qualquer arquivo como MS_MAPFILE
    MS_MAPFILE ""
    # arquivos de contexto WMS (context=) desligados: nada casa com "^$"
    MS_CONTEXT_PATTERN "^$"
    MS_CONTEXT_BAD_PATTERN "[/\\\\]{2}|[/\\\\]?\.+[/\\\\]|,"

    # templates HTML da OGC API (f=html)
    OGCAPI_HTML_TEMPLATE_DIRECTORY "/opt/geosgb/share/mapserver/ogcapi/templates/html-bootstrap/"

    #
    # Suas opções do MapServer, do GDAL ou do PROJ: valem para todos os
    # mapfiles e não podem ser trocadas por variável de ambiente do container.
    # Por isso, opções que devem poder mudar por -e ficam fora daqui, como
    # MS_DEBUGLEVEL e MS_ERRORFILE (aqui, ele também tiraria os erros do log
    # do container, que a imagem configura quando ele não está definido).
    #
  END

  MAPS
    # map=<NOME> (e /mapserver/<NOME>/ogcapi na OGC API). Um caminho relativo
    # parte do diretório deste arquivo (/var/lib/mapserver). Troque pelos seus
    GEOLOGIA "geologia/geologia.map"

    # obrigatório: usado pelo healthcheck da imagem (um PNG vazio de 1x1),
    # com caminho absoluto, fora do volume
    HEALTHCHECK "/opt/geosgb/etc/healthcheck.map"
  END
END
```

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
- **`/var/lib/mapserver` somente leitura:** o diretório (`HOME`) e os dados de exemplo pertencem ao root, sem escrita para mais ninguém, nem para o grupo 0. É ali que os mapfiles são procurados (`MS_MAP_PATTERN`), então o processo do MapServer não pode gravar um mapfile. Ele continua sendo o `HOME` de qualquer usuário, também no passwd virtual do `nss_wrapper`, mesmo sem escrita: o MapServer não grava no `HOME`, e o que precisa de escrita fica no `/tmp`.
- **Sistema de arquivos raiz somente leitura** (`--read-only`, `read_only: true`, `readOnlyRootFilesystem: true`): suportado, desde que `/tmp` seja gravável (`--tmpfs /tmp`; no Kubernetes, um `emptyDir`). O `nss_wrapper` grava ali o usuário virtual, e o `start.sh`, o FIFO do log de erros. Sem `/tmp` gravável, o container não inicia quando a UID não existe no `/etc/passwd`.

## Healthcheck

A imagem traz o comando [`healthcheck`](docker/healthcheck) (em `/usr/local/bin`). Ele faz um pedido FastCGI à porta local (com o `cgi-fcgi`, que vem na imagem) para o alias `HEALTHCHECK` do `mapserver.conf`, que desenha um PNG vazio de 1×1 a partir de [`etc/healthcheck.map`](etc/healthcheck.map). Falha se nenhum worker responder em 4 segundos. O pedido não depende dos seus mapfiles e não grava nada no log. Um `mapserver.conf` próprio precisa manter o alias `HEALTHCHECK`.

O `HEALTHCHECK` do Dockerfile não é suportado por todos os runtimes: o Podman o ignora em imagens no formato OCI, como as publicadas, e o Kubernetes nunca o usa. Por isso o comando é o mesmo em todos, mas cada runtime precisa declarar o seu:

| Runtime | Onde declarar | Quando o check falha |
|---|---|---|
| `docker run` | `HEALTHCHECK` da imagem (automático) | só marca `unhealthy` |
| Docker Compose / `podman compose` | `healthcheck:` no Compose, como no [exemplo](examples/README.md) | só marca `unhealthy` (Docker) |
| Podman | `--health-cmd` ou Quadlet | pode reiniciar com `--health-on-failure` / `HealthOnFailure=` |
| Kubernetes / OpenShift | probes `exec` | a liveness reinicia o container; a readiness tira o pod do Service |

O Docker e o Compose **não reiniciam** containers `unhealthy`. Um worker que morre é substituído pelo `multiwatch`, mas um worker travado (por exemplo, num GetMap de uma fonte que não responde) não: quando todos travam, só o healthcheck percebe.

- **Podman:**
  ```sh
  podman run -d --health-cmd healthcheck --health-interval 30s \
    --health-start-period 15s --health-on-failure restart ndscprm/mapserver:8.6.6
  ```
  No Quadlet (`.container`):
  ```ini
  [Container]
  HealthCmd=healthcheck
  HealthInterval=30s
  HealthTimeout=5s
  HealthStartPeriod=15s
  HealthRetries=3
  HealthOnFailure=restart
  ```
- **Kubernetes / OpenShift:**
  ```yaml
  startupProbe:
    exec:
      command: ["healthcheck"]
    periodSeconds: 5
    failureThreshold: 6
  livenessProbe:
    exec:
      command: ["healthcheck"]
    periodSeconds: 30
    timeoutSeconds: 5
  readinessProbe:
    exec:
      command: ["healthcheck"]
    periodSeconds: 10
    timeoutSeconds: 5
  ```
  Uma probe `tcpSocket` na 8080 também funciona, mas só confere que o `spawn-fcgi` abriu a porta, não que um worker responde.

## Testando sem servidor web

A imagem traz o cliente `cgi-fcgi`, então dá para fazer um pedido FastCGI de dentro do container:

```bash
docker run -d --name ms docker.io/ndscprm/mapserver:8.6.6
docker exec ms env -i REQUEST_METHOD=GET SCRIPT_NAME=/mapserver \
  QUERY_STRING="map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities" \
  cgi-fcgi -bind -connect 127.0.0.1:8080
```

Para a OGC API, a rota vai no `PATH_INFO` (ex.: `PATH_INFO=/DEFAULT/ogcapi/collections/countries/items` com `QUERY_STRING="f=json&limit=2"`). Para testar com HTTP, use o [exemplo com nginx](examples/README.md).

## Build

São publicadas três tags por versão:
- `ndscprm/mapserver:<versão>`: imagem final, sem Python;
- `ndscprm/mapserver:<versão>-mapscript`: o mesmo servidor FastCGI, com Python e o Python MapScript (veja abaixo);
- `ndscprm/mapserver:<versão>-devel`: imagem de desenvolvimento, para depurar ou compilar código que dependa do MapServer.

Essas tags são móveis: cada build as atualiza. Cada build também cria tags datadas, que nunca são sobrescritas, para fixar uma versão ou voltar a uma anterior: `<versão>-<AAAAMMDD>`, `<versão>-mapscript-<AAAAMMDD>` e `<versão>-devel-<AAAAMMDD>` (ex.: `8.6.6-20261026`; um segundo build no mesmo dia recebe `.2`, `.3`...). As imagens publicadas têm attestations de SBOM e de provenance (`docker buildx imagetools inspect docker.io/ndscprm/mapserver:8.6.6 --format '{{ json .SBOM }}'`).

Para conferir uma imagem construída localmente com o mesmo teste do CI: `sh .github/scripts/smoke-test.sh <imagem>` (com Podman: `DOCKER=podman sh .github/scripts/smoke-test.sh <imagem>`). Na `-mapscript`, rode também `sh .github/scripts/mapscript-test.sh <imagem>`.

A imagem `-devel` também roda o MapServer como FastCGI, com o mesmo `start.sh`, a mesma configuração e os mesmos dados de exemplo, mas com 1 worker por padrão. O comando padrão continua `python3`, então é preciso passar `/start.sh`:

```bash
# porta publicada só no host local, para depuração (veja Porta FastCGI)
docker run -d --name mapserver-devel -p 127.0.0.1:8080:8080 \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  docker.io/ndscprm/mapserver:8.6.6-devel /start.sh
# depurar o worker com gdb (a imagem base não traz o gdb: instale na hora, como root)
docker exec -u 0 mapserver-devel sh -c 'apt-get update && apt-get install -y gdb'
docker exec -it mapserver-devel sh -c 'gdb -p $(pgrep -f "^/opt/geosgb/bin/mapserv")'
```

A `-devel` publicada tem o código-fonte do MapServer em `/opt/geosgb/src`, mas não os símbolos de debug, nem do MapServer nem do GDAL da imagem base: o backtrace mostra só nomes de função. Para ter arquivo e linha no MapServer, construa a `-devel` localmente com `--build-arg MAPSERVER_BUILD_TYPE=RelWithDebInfo` (`docker build --target build --build-arg MAPSERVER_BUILD_TYPE=RelWithDebInfo -t mapserver:debug .`). Para depurar também dentro do GDAL, construa localmente a `devel` da base com `GDAL_BUILD_TYPE=RelWithDebInfo` (README do gdal-oci, "Depuração com gdb"), marque-a com a tag que o `FROM` usa (`docker tag <imagem> docker.io/ndscprm/gdal:3.12.4-py3.12-devel`) e construa a `-devel` daqui sem `--pull`.

As duas tags são multiplataforma (`linux/amd64` e `linux/arm64`). O Docker escolhe sozinho a variante da máquina. Para construir uma arquitetura específica localmente, use `docker buildx build --platform linux/arm64 ...`; para isso, a imagem base também precisa existir nessa arquitetura.

```bash
# imagem final (FastCGI)
docker build -t docker.io/ndscprm/mapserver:8.6.6 .
# imagem final com Python MapScript (base ndscprm/gdal com Python)
docker build --target release-mapscript -t mapserver:8.6.6-mapscript .
# imagem de desenvolvimento: toolchain, headers e código-fonte do GDAL e do MapServer, com o MapScript no venv
docker build --target build -t docker.io/ndscprm/mapserver:8.6.6-devel .
```

### Python MapScript (`release-mapscript`)

O estágio `release-mapscript` tem o mesmo servidor FastCGI da imagem final, sobre a `ndscprm/gdal` com Python, e o **Python MapScript** instalado no virtualenv `/opt/geosgb/venv` (o `python` e o `pip` do `PATH`). É publicado como `ndscprm/mapserver:<versão>-mapscript`.

Como o `HOME` (`/var/lib/mapserver`) é somente leitura, a imagem aponta o `XDG_CACHE_HOME` para um diretório novo no `/tmp` ao iniciar, então o pip e outras ferramentas que usam esse cache funcionam sem aviso. Um `-e XDG_CACHE_HOME=...` próprio é mantido. Isso não vale para comandos rodados com `docker exec`, que não passam pelo entrypoint. Ferramentas que gravam em `~/.config` precisam de um diretório próprio (ex.: `MPLCONFIGDIR=/tmp/matplotlib`). No build de uma imagem derivada, como root, não há essa restrição.

```bash
docker run --rm docker.io/ndscprm/mapserver:8.6.6-mapscript python -c "import mapscript; print(mapscript.msGetVersion())"
```

O arquivo `/opt/geosgb/share/mapserver/constraints.txt` lista as versões de todos os pacotes do venv (os da imagem base, como GDAL, numpy e pyarrow, e o `mapscript`). Numa imagem derivada, use-o para que nenhuma instalação os troque:

```dockerfile
FROM docker.io/ndscprm/mapserver:8.6.6-mapscript
RUN pip install --no-cache-dir -c /opt/geosgb/share/mapserver/constraints.txt minha-dependencia
```

A `-devel` também tem o MapScript no venv e guarda o wheel em `/wheels` (`mapscript-<versão>-cp<PY>-cp<PY>-linux_<arch>.whl`), para instalá-lo num venv próprio, por exemplo numa imagem derivada da `-devel`. O wheel não traz o MapServer: ele linka a `/opt/geosgb/lib/libmapserver.so`, então só funciona onde esse mesmo build do MapServer estiver instalado.

### Build args

| Arg | Padrão | Descrição |
|-----|--------|-----------|
| `GDAL_VERSION` | `3.12.4` | Versão da imagem base `ndscprm/gdal` |
| `PYTHON_VERSION` | `3.12` | Versão do Python da imagem base de compilação (`-devel`) e da `release-mapscript`; a imagem final não tem Python |
| `MAPSERVER_VERSION` | `8.6.6` | Versão do MapServer |
| `MAPSERVER_SHA256` | SHA256 do `mapserver-8.6.6.tar.gz` | Atualizar junto com `MAPSERVER_VERSION` |
| `MAPSERVER_BUILD_TYPE` | `Release` | `Release` (sem símbolos de debug) ou `RelWithDebInfo` (acrescenta os símbolos à `-devel`, para depurar com o gdb). O código-fonte fica na `-devel` nos dois casos, e a release sai igual |
| `HARDENING_CFLAGS` / `HARDENING_LDFLAGS` | `-fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=3` / `-Wl,-z,relro,-z,now` | Proteções de compilação do MapServer, as mesmas da base `ndscprm/gdal` (o gcc do Debian não as liga por padrão) |

As tags `ndscprm/gdal:<GDAL_VERSION>-py<PYTHON_VERSION>-devel` (build e imagem `-devel`) e `ndscprm/gdal:<GDAL_VERSION>-nopy` (imagem final, sem Python) precisam existir.

O código-fonte do MapServer é baixado da release no GitHub e verificado contra `MAPSERVER_SHA256`. Para obter o hash de uma nova versão:

```bash
curl -s https://api.github.com/repos/MapServer/MapServer/releases/tags/rel-8-6-6 \
  | jq -r '.assets[] | select(.name == "mapserver-8.6.6.tar.gz") | .digest'
```
