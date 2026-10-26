# TODO

Pendências de segurança e boas práticas levantadas na revisão do projeto.

## Prioridade alta

- [ ] **Dados graváveis pelo processo.** O estágio `build` dá modo `775`/`664` a `/var/lib/mapserver/data`, com escrita para o grupo 0. Com `--user <uid>:0`, o `mapserv` pode reescrever o `default.map`, o `fonts.txt` e os shapefiles; rodando como root (`--user 0`), pode reescrever qualquer coisa. Somado ao `MS_MAP_PATTERN "^/var/lib/mapserver/"`, um arquivo `.map` gravado ali pode ser carregado como mapfile.
  - Manter `775` só em `/var/lib/mapserver` (necessário para o `HOME` e o `nss_wrapper`) e deixar `data/` com `755`/`644`.
  - Restringir o padrão, por exemplo `MS_MAP_PATTERN "^/var/lib/mapserver/data/.*\.map$"`.

## Prioridade média (CI e cadeia de suprimentos)

- [ ] **Workflow reutilizável por `@main`.** O CI chama o `oci-image.yml` do gdal-oci por `@main` (as actions dele já são fixadas por SHA e atualizadas pelo Dependabot de lá), então um commit no `main` do gdal-oci muda o CI daqui sem revisão. Quando o gdal-oci tiver uma tag do workflow, trocar o `uses:` por ela (ou pelo SHA, com a tag em comentário) e criar um `.github/dependabot.yml` com `package-ecosystem: github-actions` para propor as atualizações.
- [ ] **Assinatura das imagens.** SBOM e provenance (`mode=max`) já vêm do workflow reutilizável. Falta avaliar a assinatura com `cosign` (keyless, via OIDC), que seria feita lá, para todos os projetos.
- [ ] **Bases por tag, não por digest.** Os `FROM` usam tag e o build usa `pull: true`, então o mesmo commit pode gerar imagens diferentes. Avaliar a fixação por `@sha256:`, atualizada por Renovate ou Dependabot.

## Prioridade baixa (boas práticas)

- [ ] **Mapfile de exemplo na release.** O `default.map` é publicado como `DEFAULT`, com `wms_enable_request "*"` e `include_items "all"`. Documentar como remover o alias ou levar o exemplo só para a `-devel`.
- [ ] **Decidir sobre o Python MapScript.** A release já usa a base sem Python (`ndscprm/gdal:<GDAL>-nopy`, desde 2026-10-25), e a compilação continua na `-py<PY>-devel`.
  - **Se o MapScript não entrar:** avaliar compilar numa `-devel` sem Python, se a base vier a publicar uma, e tirar o `PYTHON_VERSION`.
  - **Se entrar:** a release volta para `<GDAL>-py<PY>` (do mesmo build da `-devel`), e ainda dá para tirar `pip`, `setuptools` e `wheel` dela.
- [ ] **Sem `.dockerignore`.** Os `COPY` são específicos e nada vaza para a imagem, mas o `.git` vai junto no contexto de build.
