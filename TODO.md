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
- [ ] **Decidir sobre o Python MapScript.** A release já usa a base sem Python (`ndscprm/gdal:<GDAL>-nopy`, desde 2026-10-25), e a compilação continua na `-py<PY>-devel`.
  - **Se o MapScript não entrar:** avaliar compilar numa `-devel` sem Python, se a base vier a publicar uma, e tirar o `PYTHON_VERSION`.
  - **Se entrar:** a release volta para `<GDAL>-py<PY>` (do mesmo build da `-devel`), e ainda dá para tirar `pip`, `setuptools` e `wheel` dela.
- [ ] **Sem `.dockerignore`.** Os `COPY` são específicos e nada vaza para a imagem, mas o `.git` vai junto no contexto de build.
