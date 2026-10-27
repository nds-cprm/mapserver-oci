# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) ao trabalhar neste repositório.

## Visão geral

Imagem de contêiner do **MapServer compilado a partir do código-fonte com suporte a Oracle Spatial (OCI)**, rodando como **servidor FastCGI**. É mantida pelo SGB/CPRM (`docker.io/ndscprm/mapserver`). Não há código de aplicação, testes nem linters.

O projeto é uma camada sobre a imagem base GDAL do SGB (`docker.io/ndscprm/gdal`). Usa duas variantes do mesmo GDAL:
- **`<GDAL>-py<PY>-devel`**, usada para compilar (e base da imagem `-devel` deste projeto);
- **`<GDAL>-nopy`** (release sem Python), usada como base da imagem final `release`, que não usa Python;
- **`<GDAL>-py<PY>`** (release com Python), base do estágio `release-py`: a mesma imagem FastCGI mais o Python MapScript no venv (branch `mapscript`; ainda não publicada pelo CI).

Os dois `FROM` precisam ter o mesmo `GDAL_VERSION`. Como as tags não têm data, confira que são do mesmo build do GDAL: em 2026-10-25, a `libgdal.so.38.3.12.4` da `3.12.4-nopy` era idêntica (md5) à da `3.12.4-py3.12`.

- [Dockerfile](Dockerfile): quatro estágios. `compile` (compilação) dá origem a `build` (imagem `-devel`) e a `staging` (descartável); a `release` usa os dois. A `release` é o alvo padrão.
- [etc/mapserver.conf](etc/mapserver.conf): arquivo de configuração do MapServer 8, instalado em `/opt/geosgb/etc/mapserver.conf`.
- [etc/healthcheck.map](etc/healthcheck.map): mapfile do healthcheck (um PNG vazio de 1×1, sem camadas nem dados), instalado em `/opt/geosgb/etc/healthcheck.map` e publicado pelo alias `HEALTHCHECK` do `mapserver.conf`.
- [docker/healthcheck](docker/healthcheck) → `/usr/local/bin/healthcheck` (modo 755): comando de healthcheck único, usado pelo `HEALTHCHECK` da release, pelo Compose do exemplo e pelas probes. Faz, com o `cgi-fcgi` (pacote `libfcgi-bin`) e `timeout 4`, um pedido FastCGI `map=HEALTHCHECK&mode=map` a `127.0.0.1:${MAPSERVER_FCGI_PORT:-8080}` e exige `Content-Type: image/png` na resposta. Falha (código 1) se nenhum worker responder em 4 s (testado parando os workers com `SIGSTOP`) ou se a porta estiver errada.
  - **Por que um mapfile próprio:** qualquer pedido sem um mapfile válido (sem `map=`, `map=` vazio, `PATH_INFO=/`) responde, mas grava uma linha de erro no log pelo FIFO, o que a cada 30 s poluiria o `docker logs`. O `mode=map` do `healthcheck.map` não grava nada. Também não depende dos mapfiles montados em `/var/lib/mapserver` nem do `DEFAULT`.
  - O alias não passa pelo `MS_MAP_PATTERN` (só caminhos vindos do `map=` passam; `msConfigGetMap`), então o arquivo pode ficar em `/opt/geosgb/etc`. Um `mapserver.conf` próprio precisa manter o alias, senão o healthcheck falha. O `MS_MAPFILE ""` fixado impede o atalho de mandar o mapfile como parâmetro FastCGI.
- [fcgi/start.sh](fcgi/start.sh): `CMD` da release, que sobe o `spawn-fcgi` + `multiwatch`.
- [examples/](examples/README.md): exemplo com Compose (`examples/nginx/`): `mapserver` (raiz somente leitura, `tmpfs` em `/tmp`, **sem `ports:`**, healthcheck declarado no Compose) e `nginx-unprivileged` (HTTP :8080 → FastCGI `mapserver:8080`, `conf/nginx/nginx.conf` por bind mount). O `nginx.conf` separa o `PATH_INFO` com `fastcgi_split_path_info ^(/mapserver)(/.*)$` (OGC API em `/mapserver/<mapa>/ogcapi/...`) e responde 404 fora de `/mapserver`. O teste de fumaça usa esse `nginx.conf`, então uma mudança nele é testada a cada build.
- [data/](data/): mapfile de exemplo (`default.map`, WMS "World Countries Generalized" com shapefile da Esri, `fonts.txt`, `symbols.sym`, `mapfile.d/outputformat.inc.map`), copiado para `/var/lib/mapserver/data`.

- [README.md](README.md): documentação para quem usa a imagem (execução, variáveis, configuração, logs, build). Mantenha em sincronia com o Dockerfile.

- [.github/workflows/docker-image.yml](.github/workflows/docker-image.yml): CI. Roda por `workflow_dispatch`, que é também disparado pelo CI do gdal-oci (job `dispatch`) depois que ele publica tags novas da `ndscprm/gdal`, com as versões delas nas entradas `gdal_version`/`python_version`. O workflow as repassa em `build-args` como `GDAL_VERSION`/`PYTHON_VERSION`, então a imagem sai sobre as tags recém-publicadas; vazias (disparo manual), valem os `ARG` do Dockerfile. Não há build agendado: o disparo vem com a base nova, que invalida todas as camadas, então o `apt-get install` da release pega os pacotes atuais. Chama o **workflow reutilizável** [`nds-cprm/gdal-oci/.github/workflows/oci-image.yml@main`](https://github.com/nds-cprm/gdal-oci/blob/main/.github/workflows/oci-image.yml), documentado no README do gdal-oci ("Workflow reutilizável"). Aqui ficam só os gatilhos, as permissões e as entradas:
  - `image: docker.io/ndscprm/mapserver` e `version-arg: MAPSERVER_VERSION`: a versão é o `ARG MAPSERVER_VERSION=` do Dockerfile, que precisa ficar numa linha própria, no começo da linha (o workflow lê com `sed` e valida como `X.Y.Z`). Não há tag escrita no workflow: ao mudar a versão, as tags acompanham.
  - Duas variantes: `devel` (`target: build`, tag `<versão>-devel`) e `release` (`target: release`, tag `<versão>`). As duas saem de **uma única chamada do Bake** por arquitetura, então compartilham o estágio `compile` (a `-devel` e a release têm o mesmo MapServer compilado). A `release` grava o cache (`cache-to`), porque passa por todos os estágios (`COPY --from=build` e `--from=staging`).
  - Fluxo (no workflow reutilizável): build por arquitetura em runner nativo (amd64 e arm64, sem QEMU), push só por digest com SBOM e provenance, testes no runner, scan (Docker Scout e Grype, SARIF `docker-scout-release-<arch>` e `grype-release-<arch>`) só da `release` e, depois de tudo passar nas duas arquiteturas, as tags multiplataforma `<versão>` e `<versão>-devel`, mais as datadas `<versão>-<AAAAMMDD>` e `<versão>-devel-<AAAAMMDD>` (`.2`, `.3`... no mesmo dia; nunca sobrescritas).
  - **Testes:** a `devel` roda [.github/scripts/devel-test.sh](.github/scripts/devel-test.sh) (`mapserv -v` com FastCGI e, com o `readelf` da `-devel`, as proteções de `HARDENING_CFLAGS`/`LDFLAGS` no `mapserv`, na `libmapserver.so` e no `_mapscript*.so` do venv: `BIND_NOW`, `__stack_chk_fail` e funções `*_chk`; depois um `import mapscript`. A release tem os mesmos binários, sem `readelf`); a `release` roda [.github/scripts/smoke-test.sh](.github/scripts/smoke-test.sh), que também roda local (`DOCKER=podman sh .github/scripts/smoke-test.sh <imagem>`). Ele confere as opções de build do `mapserv -v` (FastCGI, Oracle Spatial, OGR, OGC API), o `User` `1000:0` da imagem, WMS GetCapabilities e GetMap, OGC API items e o bloqueio de `map=/etc/passwd` com o `mapserv` em modo CGI (`docker run -e QUERY_STRING=... mapserv`, sem servidor web). Depois sobe o FastCGI como em produção (`--user 12345:0 --read-only --tmpfs /tmp`, alias de rede `mapserver`), espera o `healthcheck` passar e confere que ele não grava no log, confere os 4 workers com esse UID e sobe o nginx com o [examples/nginx/conf/nginx/nginx.conf](examples/nginx/conf/nginx/nginx.conf), esperando até 15 s que ele responda (o 404 de `/`). Pelo nginx (`wget` no container dele), faz GetCapabilities, GetMap, OGC API items (o `PATH_INFO` separado pelo nginx) e o `map=/etc/passwd`, cujo erro precisa chegar ao `docker logs` pelo FIFO. Por fim, com o `cgi-fcgi` da própria imagem (`docker exec`), faz um `map=` por caminho (pega um `MS_MAP_BAD_PATTERN` com escape errado) e repete os overrides por parâmetro FastCGI que funcionavam antes da correção (`MS_MAP_BAD_PATTERN`/`MS_MAPFILE_PATTERN`, `MS_MAPFILE`, `MS_CONTEXT_PATTERN`), que precisam ser recusados. Usa `LC_ALL=C`, para o `grep` do macOS não falhar nos bytes do PNG. Leva cerca de 10 s.
  - **Decisão do projeto:** vulnerabilidades não bloqueiam a publicação (não há `fail-on-severity`); ficam no Code Scanning (SARIF) e no resumo do job. Já uma **falha** do teste ou do scan (ex.: erro do Scout, do login ou do upload do SARIF) bloqueia: nenhuma tag é criada para uma imagem que não foi testada e analisada.
  - **Permissões do `GITHUB_TOKEN`:** `contents: read` no workflow. O job que chama o reutilizável concede também `security-events: write` (upload do SARIF) e `actions: read` (exigido em repositório privado), que o job `scan` de lá pede. Os secrets `DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN` são passados explicitamente.
  - **Depende da base multiplataforma:** as tags `ndscprm/gdal:<GDAL>-py<PY>-devel` e `ndscprm/gdal:<GDAL>-nopy` precisam ter variantes amd64 e arm64 (a `3.12.4-py3.12-devel` e a `3.12.4-nopy` já têm). Sem elas, o job arm64 falha no `FROM`. Confira com `docker buildx imagetools inspect docker.io/ndscprm/gdal:<tag>`.
  - **Dockerfile independente de arquitetura:** não deve ter nada preso a uma arquitetura. Hoje não tem: o Oracle é encontrado por glob `instantclient_*`, os pacotes vêm do `ldd` + `dpkg -S` e o `libaio` vem da base.
  - Validar alterações com `actionlint`, por exemplo `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.7 .github/workflows/docker-image.yml`. Mudanças no fluxo em si (jobs, scan, tags) são feitas no gdal-oci e valem para todos os projetos que o chamam.

## Build e teste

```bash
docker build -t ndscprm/mapserver:8.6.6 .                     # release (~447 MB: base GDAL -nopy ~427 MB + MapServer)
docker build --target build -t ndscprm/mapserver:8.6.6-devel . # devel (~2,7 GB, toolchain + fontes + FastCGI)
docker run --rm ndscprm/mapserver:8.6.6 mapserv -v             # deve listar SUPPORTS=FASTCGI e INPUT=ORACLESPATIAL
```

A release fala **FastCGI na porta 8080**, não HTTP: `curl` direto não funciona. Para testar com HTTP, suba o exemplo (`cd examples/nginx && MAPSERVER_IMAGE=ndscprm/mapserver:8.6.6 docker compose up -d` e `curl 'localhost:8080/mapserver?map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities'`). Sem servidor web, use o `cgi-fcgi` que vem na imagem:

```bash
docker run -d --name ms ndscprm/mapserver:8.6.6
docker exec ms env -i REQUEST_METHOD=GET SCRIPT_NAME=/mapserver \
  QUERY_STRING="map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities" \
  cgi-fcgi -bind -connect 127.0.0.1:8080
docker exec ms healthcheck && echo healthy
DOCKER=podman sh .github/scripts/smoke-test.sh ndscprm/mapserver:8.6.6   # o mesmo teste do CI
DOCKER=podman sh .github/scripts/devel-test.sh ndscprm/mapserver:8.6.6-devel   # teste da -devel (hardening)
```

Para a OGC API, a rota vem no `PATH_INFO` (ex.: `PATH_INFO=/DEFAULT/ogcapi`). O `default.map` de exemplo publica a camada `countries` como coleção (ex.: `PATH_INFO=/DEFAULT/ogcapi/collections/countries/items`, `QUERY_STRING=f=json&limit=2`). Pegadinhas da OGC API Features que apareceram ao configurá-lo:
- **Links:** sem `oga_onlineresource`, eles usam o `ows_onlineresource` e saem sem `/DEFAULT/ogcapi`.
- **Coleções:** sem `TEMPLATE`, a camada não aparece em `collections`.
- **Itens:** sem `gml_featureid`, a rota `items` falha com "Missing required featureid metadata".
- **Atributos:** os itens só usam `gml_include_items`, sem cair no `ows_`; o WMS GetFeatureInfo precisa de `ows_`/`wms_include_items`. Por isso o mapfile tem os dois.
- **Descrição:** sem `ows_abstract`, a coleção sai com o aviso "unable to set the collection description". Teste também com UID arbitrário (`--user 12345:0`): o entrypoint da base cria o usuário virtual via `nss_wrapper`.

## Estágios do Dockerfile

`ARG` globais: `GDAL_VERSION=3.12.4`, `PYTHON_VERSION=3.12`, `BASE_DIR=/opt/geosgb`, `MAPSERVER_VERSION=8.6.6` e `MAPSERVER_SHA256`. `GDAL_VERSION` e `PYTHON_VERSION` montam a tag da `-devel`; a release usa só o `GDAL_VERSION` (`<GDAL>-nopy`).

### `compile` (`ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel`)
- apt: `libfreetype-dev` e `libfcgi-dev`. Os demais headers (libpng, libjpeg, libpq, libxml2, PROJ, GEOS) já vêm da base.
- Download do MapServer:
  - baixa da release do GitHub (tag `rel-X-Y-Z`, derivada com `${MAPSERVER_VERSION//./-}`, por isso o `RUN` usa bash);
  - verifica com `sha256sum -c` contra `MAPSERVER_SHA256`;
  - extrai em `${BASE_DIR}/src` (o código-fonte fica, como na base).
- `ORACLE_HOME` é uma variável local do `RUN`:
  - é descoberta com `echo ${BASE_DIR}/oracle/instantclient_*` (o build falha se não for diretório);
  - é passada só para o `cmake`, que é o único lugar onde é lida (`FindORACLE.cmake`). Não existe `ENV ORACLE_HOME`.
- Compilação:
  - CMake com `CMAKE_BUILD_TYPE=${MAPSERVER_BUILD_TYPE}` (como o `GDAL_BUILD_TYPE` da base; outro valor aborta o build), num subshell `( cd build && ... )`, com instalação em `${BASE_DIR}`. O padrão `Release` (`-O3 -DNDEBUG`) é o da `-devel` publicada, sem símbolos de debug (`libmapserver` com cerca de 4 MB, como na release). `RelWithDebInfo` (`CMAKE_{C,CXX}_FLAGS_RELWITHDEBINFO="-O3 -g -DNDEBUG"`, a mesma otimização, porque o padrão dele seria `-O2`) só acrescenta os símbolos (`libmapserver` com cerca de 29 MB), para uma `-devel` construída localmente para depurar. O código-fonte fica em `${BASE_DIR}/src` nos dois casos, e o `staging` remove os símbolos da release, que sai igual;
  - proteções de compilação `HARDENING_CFLAGS`/`HARDENING_LDFLAGS` (`ARG` do estágio, com os mesmos padrões da base, porque `ARG` não é herdado da imagem base) em `CMAKE_{C,CXX}_FLAGS` e `CMAKE_{SHARED,EXE,MODULE}_LINKER_FLAGS`: o gcc do Debian não liga stack protector, `_FORTIFY_SOURCE` nem RELRO completo por padrão, e o `mapserv` processa requisições não confiáveis. Ao mudar as flags na base, mudar aqui também. Build paralelo com `--parallel "$(nproc)"`;
  - o `install_manifest.txt` é copiado para `${BASE_DIR}/share/mapserver/install_manifest.txt` (o `staging` depende dele); depois vêm `rm -rf build/` e `ldconfig`;
  - `-DMAPSERVER_CONFIG_FILE=${BASE_DIR}/etc/mapserver.conf` é obrigatório: sem ele, o `GNUInstallDirs` compila um caminho em `/etc/opt/...` (prefixo em `/opt`) e todo request falha com `msLoadConfig(): Unable to access file`;
  - fica **sem** cURL, Cairo/SVG-Cairo, HarfBuzz, FriBiDi, GIF, SOS, Protobuf-c e clientes WMS/WFS, e **com** libxml2, Oracle Spatial e Python MapScript.
- **Python MapScript** (`-DWITH_PYTHON=ON`, `-DPython_EXECUTABLE=${BASE_DIR}/venv/bin/python`):
  - o CMake gera o módulo `_mapscript` com o SWIG da base (4.3), com as mesmas flags (hardening e build type), e um `setup.py` que só empacota esse `.so` (não compila nada);
  - o wheel (`mapscript-<versão>-cp<PY>-cp<PY>-linux_<arch>.whl`, cerca de 400 KB) sai com `pip wheel --no-build-isolation --no-deps -w /wheels` em `build/src/mapscript/python`: offline, com o setuptools e o wheel fixados com hash pela base. O `/wheels` fica na `-devel` de propósito: o `staging` o reempacota para a `release-py`, e ele pode ser instalado num venv próprio onde estiver esse build do MapServer (linka a `${BASE_DIR}/lib/libmapserver.so`; documentado no README);
  - o target `install` também roda `pip install --prefix=${BASE_DIR}`, que põe o MapScript em `${BASE_DIR}/lib/python3.*`, fora do venv e fora do `install_manifest.txt`. O build falha se esse diretório já existir na base (hoje não existe), para nunca apagar algo dela; depois do `install`, ele é apagado e o wheel é instalado no venv (`--no-index --no-deps`), então a `-devel` também tem o MapScript; o `RUN` termina com um `import mapscript`;
  - o target `pythonmapscript-wheel` do CMake (venv próprio, `pip install -r requirements-dev.txt` da internet, testes) **não** é usado.

### `build` (imagem `-devel`, `FROM compile`)
- Acrescenta à compilação o mesmo ambiente FastCGI da release, para rodar e depurar o MapServer na imagem de desenvolvimento:
  - apt: `fonts-liberation`, `libfcgi-bin` (`cgi-fcgi`, do healthcheck), `multiwatch` e `spawn-fcgi`;
  - `etc/mapserver.conf` e `etc/healthcheck.map` → `${BASE_DIR}/etc/`, `fcgi/start.sh` → `/start.sh`, `docker/healthcheck` → `/usr/local/bin/healthcheck` e `data/` → `/var/lib/mapserver/data`;
  - sem `HEALTHCHECK` (o `CMD` continua o `python3` da base), mas com o comando `healthcheck` para quem roda o `/start.sh`;
  - `ENV MAPSERVER_FCGI_PORT=8080` e `MAPSERVER_WORKERS=1` (um worker só facilita o `gdb -p`) e `EXPOSE 8080`.
- Não muda `CMD`, `WORKDIR` nem `HOME` herdados da base (`CMD ["python3"]`), para não alterar o comportamento de quem usa a `-devel` como base. Para subir o FastCGI: `docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined ... ndscprm/mapserver:<versão>-devel /start.sh`.
- Ajusta os modos de `/var/lib/mapserver`: diretórios `775` e arquivos `664`, sem bit de execução e com escrita para o grupo 0. Assim os modos não dependem do `umask` do checkout (no CI, `644`/`755`). A release copia `/var/lib/mapserver` daqui.
- Fica separado do `compile` para que mudanças no `start.sh`, na configuração ou nos dados não refaçam o `staging` (extração e `ldd`).

### `staging` (descartável, `FROM compile`)
- Copia **só os arquivos do MapServer** para `/tmp/mapserver`, com os caminhos absolutos preservados: `tar` com `--files-from` lendo o `install_manifest.txt` e `--transform` para mudar o destino. Fica tudo que está no manifesto, como `bin/mapserv` e utilitários, `lib/libmapserver.so*`, `share/mapserver/ogcapi` e `etc/mapserver-sample.conf`. O GDAL e o Oracle não são copiados, porque já estão na release da base.
- Remove `include`, `lib/pkgconfig` e `share/mapserver/cmake`, e faz `strip --strip-debug` nos ELF, o que tira os símbolos de debug quando `MAPSERVER_BUILD_TYPE=RelWithDebInfo` (com `Release`, não há o que tirar).
- Gera `/tmp/runtime-packages.txt`:
  1. roda `ldd` nos ELF do MapServer;
  2. resolve os caminhos com `realpath`, descartando o que está em `${BASE_DIR}`;
  3. mapeia cada biblioteca para um pacote com `dpkg -S` (tenta também o caminho sem `/usr`).
- O `ldd` também lista as dependências indiretas (via GDAL), então a lista é longa, mas o `apt` só instala o que falta. Hoje isso é `libfcgi0t64`, `libfreetype6` e `libpcre2-posix3`.
- O build **falha** se algum `ldd` der `not found` ou se uma biblioteca não pertencer a nenhum pacote (ex.: algo em `/usr/local`).
- Gera `/tmp/wheels` para a `release-py`: o wheel do MapScript desempacotado (`python -m wheel unpack`), com `strip --strip-debug` no `.so` e empacotado de novo (`wheel pack` reescreve os hashes do `RECORD`). Só faz diferença com `RelWithDebInfo`. O `_mapscript` não entra no `ldd` acima: ele linka a `libpython` de `/usr/local`, que não é de pacote Debian; as dependências dele são as da `libmapserver`, e a `release-py` confere com um `import mapscript`.
- Ao adicionar uma dependência no `build`, não é preciso mexer na release.

### `release-py` (`ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}`)
- Mesmo texto da `release` (pacotes do `staging`, arquivos do MapServer, configuração, `start.sh`, healthcheck, dados, `ENV`, `USER 1000:0`, `HEALTHCHECK` e `CMD`), mas sobre a base com Python, do mesmo build do GDAL da `-devel`. Fica **antes** da `release`, que continua sendo o último estágio (alvo padrão).
- Instala o wheel do `staging` (bind mount de `/tmp/wheels`) no venv da base com `--no-index --no-deps` (sem dependências, nada da base muda), depois `pip check` e `import mapscript`.
- **Constraints**: grava `${BASE_DIR}/share/mapserver/constraints.txt` com os pacotes do venv depois da instalação (os da base mais o `mapscript`), para imagens derivadas: `pip install -c /opt/geosgb/share/mapserver/constraints.txt ...` não troca nenhum deles. Usa `pip list --format=freeze`, e não `pip freeze`, porque pacotes instalados de wheel local (o `pyarrow` da base e o `mapscript`) sairiam como `nome @ file:///tmp/...`, caminho que não existe em outra imagem. O build falha se o `mapscript==` não estiver no arquivo. Não define `PIP_CONSTRAINT`: o uso fica a critério da imagem derivada.
- Testada com o `smoke-test.sh` da release (o mesmo FastCGI) e com `import mapscript` como UID arbitrário e `--read-only`. Tamanho: cerca de 620 MB (a `release` tem cerca de 450 MB).

### `release` (`ndscprm/gdal:${GDAL_VERSION}-nopy`)
- **Herdado da base**:
  - GDAL, Oracle basiclite, `ld.so.conf.d`, symlink `libaio.so.1`, `ca-certificates` e o `nss_wrapper`;
  - `ENV` `PATH` (sem venv) e `GDAL_DATA`;
  - `ENTRYPOINT ["/docker-entrypoint.sh"]`.
  - Não tem Python, venv nem o repositório apt do Arrow. As bibliotecas do Arrow já vêm instaladas; o `staging` (que roda na `-devel`, com o repositório) as lista, e o `apt` só registra que já estão na versão mais nova. Se uma versão nova da base exigir um pacote do Arrow que a `-nopy` não tenha, o `apt` da release falha.
- **apt**: instala os pacotes do `staging` (por bind mount) e os que não são linkados: `fonts-liberation` (usado por `data/fonts.txt`), `libfcgi-bin` (o `cgi-fcgi` do healthcheck, 68 KB; a biblioteca `libfcgi0t64` já vem da lista do `staging`), `multiwatch` e `spawn-fcgi`.
- **Ordem**:
  1. `RUN` do apt;
  2. `COPY --from=staging /tmp/mapserver/ /`;
  3. `etc/mapserver.conf` e `etc/healthcheck.map` → `${BASE_DIR}/etc/`, `fcgi/start.sh` → `/start.sh` e `docker/healthcheck` → `/usr/local/bin/healthcheck` (os dois com `--chmod=755`);
  4. `RUN` com `ldconfig`, que registra o `libmapserver` no cache do `ld.so` (os ELF do MapServer também têm `RUNPATH=/opt/geosgb/lib`), e `install -d -m 775 /var/lib/mapserver`. O caminho é fixo, porque também está escrito no `start.sh`, no `mapserver.conf` e no `default.map`. O diretório precisa existir antes do `COPY` seguinte: se o `COPY` o criasse, ele nasceria com `755`, porque o `--chmod` só vale para o conteúdo copiado;
  5. `COPY --from=build /var/lib/mapserver/ /var/lib/mapserver/`: traz o `data/` com os modos ajustados no `build` (dono root, grupo 0 com escrita). A cópia é do diretório **pai**: o `COPY` de um diretório copia só o conteúdo e cria o destino com `755`, então copiar o pai faz o próprio `data/` manter o modo. O `COPY --chmod` não é usado porque daria o mesmo modo a arquivos e diretórios.
  6. `WORKDIR /var/lib/mapserver`.
  - O MapServer e esses arquivos ficam depois do apt para que mudá-los não invalide o cache dos pacotes. O `RUN` do apt já é refeito quando o `staging` muda, por causa do bind mount.
- **Usuário**: `USER 1000:0`, o último passo antes do `EXPOSE`, igual nos projetos irmãos (`mapproxy-oci`, `pygeoapi-oci`). A `-devel` continua como root.
  - O UID 1000 não está no `/etc/passwd` de propósito: o `nss_wrapper` da base cria o usuário virtual com o nome padrão `sgb` (`USER_NAME`, não definido na imagem), como faz com qualquer UID arbitrário (`--user <uid>:0`, OpenShift).
  - Esse usuário roda com **GID 0** (padrão do `docker run --user <uid>`, do Kubernetes sem `runAsGroup` e do OpenShift). Por causa do `g=u`, ele pode escrever em `/var/lib/mapserver` e o `HOME` continua sendo `/var/lib/mapserver`.
  - Com um GID diferente de 0 (ex.: `--user 12345:12345`), o diretório não é gravável, mas o `HOME` continua `/var/lib/mapserver`, no ambiente e no passwd virtual (`sgb:x:12345:12345:App User:/var/lib/mapserver:/bin/false`); o script da base **não** troca para `/tmp`. Não quebra nada, porque nada na imagem grava no `HOME` (verificado em 2026-10-25: WMS, OGC API e o log pelo FIFO funcionam).
- **ENV**: `MAPSERVER_FCGI_PORT=8080`, `MAPSERVER_WORKERS=4` e `HOME=/var/lib/mapserver`. O `MS_ERRORFILE` fica sem valor de propósito (veja Logs, abaixo).
- **Inicialização**: `EXPOSE 8080`, `HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD ["healthcheck"]` e `CMD ["/start.sh"]`. O `ENTRYPOINT` é o da base e não deve ser trocado, porque é ele que roda o `nss_wrapper`. O `HEALTHCHECK` só vale no Docker: o Podman o ignora nas imagens OCI publicadas (verificado com o `ndscprm/mapproxy:7.0.0`) e o Kubernetes nunca o usa, então o Compose do exemplo, o Quadlet e as probes chamam o mesmo `healthcheck`. Os intervalos (30s/5s/15s/3) se repetem no Dockerfile, no Compose e no README, como no mapproxy-oci.

## Execução FastCGI

Árvore de processos: `/docker-entrypoint.sh` → `exec /start.sh` → `exec spawn-fcgi` → `exec multiwatch` (PID 1) → N × `mapserv`.

- [fcgi/start.sh](fcgi/start.sh) roda `mapserv -v` e faz `exec spawn-fcgi -n -a 0.0.0.0 -p $MAPSERVER_FCGI_PORT -d /var/lib/mapserver -- multiwatch -f $MAPSERVER_WORKERS -- mapserv`.
- Com `-n`, o `spawn-fcgi` só abre o socket e dá `exec` no `multiwatch`.
- O `multiwatch` mantém os workers vivos e sobe outro quando um `mapserv` morre:
  - registra `Child[N] died, respawn`;
  - se o worker morreu logo depois de iniciar, registra `Spawning child[N] failed, next try` e sobe outro após um intervalo.
- Como PID 1, o `multiwatch` trata o SIGTERM: o `docker stop` leva cerca de 0,3 s e termina com código 0, sem precisar de `tini`.
- **Logs**: por padrão, os erros do MapServer vão para o `docker logs`.
  - **Por que não `stderr` nem `/dev/stderr`:** no `mapserv` com FastCGI, `MS_ERRORFILE=stderr` aponta para o stream de erro do **protocolo FastCGI** (vai para o servidor web), e `/dev/stderr` não pode ser aberto por usuário não root, porque o pipe do container pertence ao root.
  - **Como funciona:** quando `MS_ERRORFILE` não está definida, o `start.sh`:
    1. cria o FIFO `errors.fifo` (modo 600, do próprio usuário) num diretório novo criado com `mktemp -d` (`${TMPDIR:-/tmp}/mapserver.XXXXXX`, 0700), nunca num caminho fixo do `/tmp`, que poderia ter sido plantado antes (mesmo cuidado do nss_wrapper da base);
    2. abre o FIFO em leitura e escrita no **fd 3** (`exec 3<>`), herdado por `spawn-fcgi`, `multiwatch` (PID 1) e workers;
    3. sobe o leitor `( while :; do cat <&3 >&2 || :; sleep 1; done ) &`;
    4. exporta `MS_ERRORFILE` apontando para o FIFO.
  - **Por que o fd 3:** os workers abrem o FIFO ao **iniciar**. Sem um leitor, esse `fopen` trava para sempre: o processo fica em `S`, no `wait_for_partner`, sem aceitar conexões, e o `multiwatch` não percebe, porque só reage quando o worker termina. Com o fd 3 aberto no `multiwatch`, sempre existe um leitor, então o `fopen` nunca trava e o `cat` nunca recebe EOF.
  - **Leitor:** se o `cat` morrer, o laço o reinicia em 1 s, e as mensagens esperam no buffer de 64 KB do pipe. O `|| :` é necessário porque, sem ele, o `set -e` encerraria o laço junto com o `cat`. Para parar de registrar logs seria preciso matar o `cat` e o laço; mesmo assim, os workers só travam (na escrita) depois de encher 64 KB.
  - **Patch no `build`:** em arquivo ou FIFO, o MapServer usa `fopen` com buffer completo (4 KB) e não faz `flush` por mensagem. Isso atrasa e perde mensagens, e pode misturar linhas de workers diferentes. O `build` aplica com `sed` um `setvbuf(debuginfo->fp, NULL, _IOLBF, 0)` logo depois de `debug_mode = MS_DEBUGMODE_FILE` em `src/mapdebug.c`, e um `grep -q` faz o build falhar se o trecho mudar numa versão nova. Com gravação linha a linha, cada mensagem tem menos de `PIPE_BUF`, então a escrita no FIFO é atômica: 200 requisições simultâneas geraram 200 linhas íntegras.
  - **Alternativas:** `-e MS_ERRORFILE=stderr` manda os erros para o servidor web, e um caminho de arquivo grava num arquivo.

## Configuração do MapServer 8 ([etc/mapserver.conf](etc/mapserver.conf))

- O MapServer 8 **exige** o arquivo de configuração (caminho compilado `/opt/geosgb/etc/mapserver.conf`, que pode ser trocado pela variável `MAPSERVER_CONFIG_FILE`).
- Os valores do bloco `ENV` são aplicados com `CPLSetConfigOption` e **têm prioridade sobre o ambiente do container**: o que estiver ali não pode ser sobrescrito com `docker run -e`.
- **Parâmetros FastCGI viram ambiente.** O `FCGI_Accept` troca o `environ` pelos parâmetros de cada requisição, e o `CPLGetConfigOption` (MapServer e GDAL) recorre ao `getenv()` quando a opção não está no `ENV`. Um cliente que fale FastCGI direto com a porta 8080 define, então, qualquer opção ausente do `ENV`. Verificado em 2026-10-26 com `cgi-fcgi` na 8.6.6, antes da correção: `MS_MAP_BAD_PATTERN=^$` com `MS_MAPFILE_PATTERN=.` deixava passar `map=/var/lib/mapserver/../../etc/passwd` até a abertura do arquivo, e `MS_MAPFILE=/etc/passwd` com `MS_MAPFILE_PATTERN=.` fazia o `msLoadMap` interpretar o `/etc/passwd`. O `MS_MAPFILE` do ambiente não passa pelo `MS_MAP_PATTERN` (`ms_mapfile_tainted = MS_FALSE` no `msCGILoadMap`); só o `MS_MAPFILE_PATTERN` do `msLoadMap` o valida.
- Por isso o `ENV` fixa todas as opções que decidem qual arquivo é aberto, lidas por requisição no `msCGILoadMap` e no `msLoadMap` (`src/mapservutil.c` e `src/mapfile.c`):
  - `MS_MAP_PATTERN "^/var/lib/mapserver/"`: obrigatório para usar `map=/caminho`; bloqueia caminhos fora do diretório (ex.: `map=/etc/passwd` → "fails to validate");
  - `MS_MAP_BAD_PATTERN` e `MS_MAPFILE_PATTERN "\.map$"`, com os valores padrão do MapServer;
  - `MS_MAPFILE ""`: sem mapfile padrão. Um pedido sem `map=` falha com "Filename validation failed" em vez de "CGI variable \"map\" is not set";
  - `MS_CONTEXT_PATTERN "^$"` (nunca casa: o `context=` vazio é ignorado antes) e `MS_CONTEXT_BAD_PATTERN`: arquivos de contexto desligados, como sem a opção;
  - `OGCAPI_HTML_TEMPLATE_DIRECTORY`, apontando para `share/mapserver/ogcapi/templates/html-bootstrap/`.
- Ficam de fora as que só mudam a resposta do próprio cliente (`MS_ERROR_URL`, `MS_EMPTY_URL`, `MS_MODE`, `MS_MAP_NO_PATH`, `MS_NO_POST`...). `MS_ERRORFILE` e `MS_DEBUGLEVEL` são lidos uma vez, no `msSetup` da inicialização, não por requisição. As opções do GDAL não podem ser fixadas uma a uma: a defesa é a porta 8080 ficar acessível só ao servidor web (seção "Porta FastCGI" do README, com `FCGI_WEB_SERVER_ADDRS`, testado: só os IPs da lista são atendidos).
- **Escape nas strings do `mapserver.conf`:** o lexer (`maplexer.l`) converte `\\` em `\`, `\"` em `"` e mantém uma `\` seguida de outro caractere. As regex são PCRE2, onde `[/\]` é uma classe não fechada (o `\]` escapa o colchete) e a validação falha para todo caminho, sem erro na inicialização. Para o regex `[/\\]` do padrão do MapServer, o arquivo tem `[/\\\\]`; `\.` fica como está. O teste de fumaça pede um `map=` com caminho, então pega esse erro.
- O alias `MAPS { DEFAULT ... }` permite `map=DEFAULT`.
- Configurações que devem poder ser alteradas por ambiente (ex.: `MS_ERRORFILE`) não podem ficar no `mapserver.conf`; ficam em `ENV` no Dockerfile ou no `start.sh`.

## Atualizar versões

- **MapServer**: ao trocar `MAPSERVER_VERSION`, atualize `MAPSERVER_SHA256`. O MapServer não publica checksums nem assinaturas; o valor vem do `digest` que o GitHub calcula para o asset da release. Confira contra o espelho oficial:

  ```bash
  curl -s https://api.github.com/repos/MapServer/MapServer/releases/tags/rel-8-6-6 | jq -r '.assets[] | select(.name == "mapserver-8.6.6.tar.gz") | .digest'
  curl -sL https://download.osgeo.org/mapserver/mapserver-8.6.6.tar.gz | sha256sum
  ```

- **GDAL/Python**: só os `ARG`. As duas tags (`<GDAL>-py<PY>-devel` e `<GDAL>-nopy`) precisam existir e ser do mesmo build do GDAL.

## Imagem base (`ndscprm/gdal`)

Fatos verificados nas tags `3.12.4-py3.12-devel`, `3.12.4-py3.12` e `3.12.4-nopy`:

- Base `python:3.12-trixie` / `python:3.12-slim-trixie` (**Debian 13**): os pacotes seguem a transição `t64`, e as fontes Liberation ficam em `/usr/share/fonts/truetype/liberation/` (`fonts-liberation2` virou pacote de transição).
- `-devel`: `/opt/geosgb` com `bin`, `include`, `lib`, `share`, `src/gdal-3.12.4`, `venv` e `oracle/instantclient_19_32` (basiclite + SDK). Só ela tem headers e o SDK do Oracle.
- Release:
  - `/opt/geosgb` com `bin`, `lib`, `share`, `venv` e `oracle` (sem SDK), com o GDAL sem símbolos de debug;
  - `ENTRYPOINT ["/docker-entrypoint.sh"]` (estilo Postgres: em `/docker-entrypoint.d/`, `*.sh` com `+x` é executado e sem `+x` é carregado com `.`) e `CMD ["python3"]`;
  - `10-enable-nss-wrapper.sh` cria o usuário virtual para UID sem entrada no `/etc/passwd`;
  - a `-nopy` (usada aqui) é a mesma release sem Python, venv e repositório do Arrow: base `debian:trixie`, `CMD ["bash"]`, cerca de 427 MB contra 598 MB da `-py3.12`;
  - o usuário padrão é root.
- Só o GDAL é compilado; PROJ 9.6 e GEOS 3.13 vêm do Debian.
- O GDAL tem os drivers OCI, Arrow/Parquet, PostGIS, GPKG, OpenFileGDB, KML, Elasticsearch e WMS/WFS/WCS/OGC API, mais os drivers núcleo (Shapefile etc.).
- Bibliotecas sem RPATH: `/opt/geosgb/lib` e o diretório do Oracle estão em `/etc/ld.so.conf.d/`. O `mapserv` tem `RUNPATH=/opt/geosgb/lib`.
- Para usar o `gdb` na imagem `-devel`: `docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined ...` e instalar o `gdb` na hora, como root (`apt-get update && apt-get install -y gdb`): a base `ndscprm/gdal` não o traz mais, nem os símbolos do GDAL (o padrão dela é `GDAL_BUILD_TYPE=Release`). A `-devel` publicada (`MAPSERVER_BUILD_TYPE=Release`) não tem símbolos: o backtrace mostra só nomes de função. Com uma `-devel` construída com `--build-arg MAPSERVER_BUILD_TYPE=RelWithDebInfo`, o código-fonte em `${BASE_DIR}/src` dá arquivo e linha no MapServer (ex.: `main (...) at .../src/apps/mapserv.c:276`); os quadros do GDAL só têm o nome da função, a menos que a base também seja construída com `GDAL_BUILD_TYPE=RelWithDebInfo`. Com `-O3`, algumas variáveis aparecem como `<optimized out>`.

## Convenções

- Versões como `ARG` globais no topo, re-declarados no estágio que os usa.
- Cada `RUN` com apt faz `update`, `install --no-install-recommends --no-install-suggests`, `autoremove` e `rm -rf /var/lib/apt/lists/*`.
- `SHELL` com `bash -o pipefail` em `compile` e `staging`, voltando para `/bin/sh -c` no fim de cada um.
- Todo download externo é verificado contra um SHA256 fixado no Dockerfile.
- Comentários no Dockerfile em inglês; documentação em português.
- `release-py` e `release` são mantidas com o mesmo texto, a não ser pelo `FROM`, pelo `LABEL` de descrição e pelo `RUN` do MapScript: uma mudança em uma vai também para a outra. Confira com `diff <(sed -n '/AS release-py$/,/^CMD/p' Dockerfile) <(sed -n '/AS release$/,/^CMD/p' Dockerfile)`, que só deve mostrar essas três diferenças.
