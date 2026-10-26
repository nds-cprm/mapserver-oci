# TODO

Pendências de segurança e boas práticas levantadas na revisão do projeto.

## Prioridade alta

- [ ] **Dados graváveis pelo processo.** O estágio `build` dá modo `775`/`664` a `/var/lib/mapserver/data`, com escrita para o grupo 0. Com `--user <uid>:0`, o `mapserv` pode reescrever o `default.map`, o `fonts.txt` e os shapefiles; rodando como root (`--user 0`), pode reescrever qualquer coisa. Somado ao `MS_MAP_PATTERN "^/var/lib/mapserver/"`, um arquivo gravado ali pode ser carregado como mapfile.
  - Manter `775` só em `/var/lib/mapserver` (necessário para o `HOME` e o `nss_wrapper`) e deixar `data/` com `755`/`644`.
  - Restringir o padrão, por exemplo `MS_MAP_PATTERN "^/var/lib/mapserver/data/.*\.map$"`.

- [ ] **Opções de segurança sobrescritas por parâmetros FastCGI.** O `msCGILoadMap` lê `MS_MAP_BAD_PATTERN`, `MS_MAP_NO_PATH` e `MS_MAPFILE` com `CPLGetConfigOption`. Quando a opção não está no `ENV` do `mapserver.conf`, essa função recorre ao `getenv()`, e o `FCGI_Accept` troca o `environ` pelos parâmetros de cada requisição. Quem falar FastCGI direto com a porta 8080 pode enviar `MS_MAP_BAD_PATTERN=^$`, o que desliga o bloqueio de `..` e libera `map=/var/lib/mapserver/../../...`. Essa conclusão vem da leitura do código (`src/mapservutil.c`, 8.6.6) e ainda não foi testada.
  - Fixar no bloco `ENV` do `mapserver.conf` o `MS_MAP_BAD_PATTERN` com o valor padrão (`[/\\]{2}|[/\\]?\.+[/\\]|,`).
  - Avaliar `MS_MAP_NO_PATH "1"`, que só aceita os aliases de `MAPS`.
  - Documentar no README que a porta 8080 nunca deve ficar acessível fora da rede do servidor web (NetworkPolicy; nada de `-p 8080:8080` em produção).
  - Reproduzir com `cgi-fcgi` antes e depois da correção.

## Prioridade média (CI e cadeia de suprimentos)

- [ ] **Actions fixadas por tag mutável** (`@v7`, `@v4`, `@v1` etc.) em jobs que recebem o `DOCKERHUB_TOKEN`. Fixar por SHA de commit, com a versão num comentário, e manter atualizadas com Dependabot (`package-ecosystem: github-actions`).
- [ ] **Sem SBOM e com proveniência mínima.** Adicionar `sbom: true` e `provenance: mode=max` nos builds; o `imagetools create` preserva as atestações. Depois, avaliar a assinatura com `cosign` (keyless, via OIDC).
- [ ] **Bases por tag, não por digest.** Os `FROM` usam tag e o build usa `pull: true`, então o mesmo commit pode gerar imagens diferentes. Avaliar a fixação por `@sha256:`, atualizada por Renovate ou Dependabot.

## Prioridade baixa (boas práticas)

- [ ] **Sistema de arquivos somente leitura.** Testado em 2026-10-25 no Podman, em modo Docker (`--read-only --read-only-tmpfs=false --tmpfs /tmp --passwd=false`): o `nss_wrapper` cria o usuário em `/tmp`, e WMS, OGC API e o log pelo FIFO funcionam. Falta documentar no README `--read-only --tmpfs /tmp` (no Kubernetes, `readOnlyRootFilesystem: true` com um `emptyDir` em `/tmp`).
- [ ] **Healthcheck.** Documentar uma probe `tcpSocket` na 8080 para Kubernetes. Ela não detecta worker travado.
- [ ] **Mapfile de exemplo na release.** O `default.map` é publicado como `DEFAULT`, com `wms_enable_request "*"` e `include_items "all"`. Documentar como remover o alias ou levar o exemplo só para a `-devel`.
- [ ] **Python herdado da base na release.** A release traz o venv e o CPython da base, que o MapServer não usa (não há Python mapscript) e que aparecem no relatório do Scout.
  - **Em espera:** depende de decidir se o Python MapScript entra nesta imagem. Se entrar, a release precisa do Python e do venv (as opções abaixo deixam de valer, mas ainda daria para tirar `pip`, `setuptools` e `wheel`). Se não entrar, seguir a recomendação abaixo.
  - **Verificado em `ndscprm/gdal:3.12.4-py3.12`:**
    - nenhuma biblioteca em `/opt/geosgb/lib` ou `/usr/lib`, nem binário em `/opt/geosgb/bin`, é linkado ao `libpython`;
    - o entrypoint e o `10-enable-nss-wrapper.sh` são `sh`;
    - os utilitários Python do GDAL (`gdal_calc.py`, `gdal2tiles.py`, `ogrmerge.py` etc.) ficam só em `/opt/geosgb/venv/bin`, e o `/opt/geosgb/bin` tem só binários nativos;
    - o venv ocupa cerca de 99 MB (numpy, pip, setuptools, wheel e os bindings `osgeo`); o CPython em `/usr/local` (de `python:3.12-slim-trixie`), cerca de 34 MB mais os executáveis, e nada disso é pacote do `dpkg`.
  - **Opções:**
    1. **Apagar na release:** `rm -rf` do venv e do Python em `/usr/local`, redefinindo `PATH` e esvaziando `VIRTUAL_ENV`. Tira a superfície de ataque do sistema de arquivos final, mas **não reduz o tamanho**, porque as camadas da base continuam lá. É uma mudança pequena e mantém a herança da base.
    2. **Release a partir de `debian:trixie-slim`,** copiando da base só `/opt/geosgb/{bin,lib,share,oracle}`, `ld.so.conf.d`, o entrypoint, o `nss_wrapper` e o symlink do `libaio`, e estendendo o `ldd` + `dpkg -S` do `staging` às bibliotecas do GDAL. Reduz uns 130 a 150 MB, mas acopla esta imagem a detalhes internos da base.
    3. **Variante da base sem Python** (ex.: `ndscprm/gdal:3.12.4` ou `-slim`, sobre `debian:trixie-slim`), publicada pelo repositório da base; aqui só muda o `FROM` da release. É a mais limpa e beneficia outras imagens, mas depende de mudar o outro repositório.
  - **Recomendação:** opção 3; enquanto ela não sai, a opção 1.
  - **Efeito colateral:** quem usa a release para rodar `gdal_calc.py` ou `import osgeo` perde isso. Os utilitários nativos e a `-devel` continuam completos.
  - **Testes:** `mapserv -v`, uma requisição FastCGI e `--user 12345:0`.
- [ ] **Sem `.dockerignore`.** Os `COPY` são específicos e nada vaza para a imagem, mas o `.git` vai junto no contexto de build.
