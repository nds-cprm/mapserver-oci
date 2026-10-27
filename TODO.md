# TODO

Pendências de segurança e boas práticas levantadas na revisão do projeto.

## Prioridade média (CI e cadeia de suprimentos)

- [ ] **Workflow reutilizável por `@main`.** O CI chama o `oci-image.yml` do gdal-oci por `@main` (as actions dele já são fixadas por SHA e atualizadas pelo Dependabot de lá), então um commit no `main` do gdal-oci muda o CI daqui sem revisão. Quando o gdal-oci tiver uma tag do workflow, trocar o `uses:` por ela (ou pelo SHA, com a tag em comentário) e criar um `.github/dependabot.yml` com `package-ecosystem: github-actions` para propor as atualizações.
- [ ] **Assinatura das imagens.** SBOM e provenance (`mode=max`) já vêm do workflow reutilizável. Falta avaliar a assinatura com `cosign` (keyless, via OIDC), que seria feita lá, para todos os projetos.
- [ ] **Bases por tag, não por digest.** Os `FROM` usam tag e o build usa `pull: true`, então o mesmo commit pode gerar imagens diferentes. Avaliar a fixação por `@sha256:`, atualizada por Renovate ou Dependabot.

## Prioridade baixa (boas práticas)

- [ ] **Mapfile de exemplo na release.** O `default.map` é publicado como `DEFAULT`, com `wms_enable_request "*"` e `include_items "all"`. Documentar como remover o alias ou levar o exemplo só para a `-devel`.
- [ ] **Publicar a `release-py` (Python MapScript).** Na branch `mapscript`, o MapScript é compilado no `compile` e a `release-py` (base `<GDAL>-py<PY>`) o instala no venv, com o constraints em `/opt/geosgb/share/mapserver/constraints.txt`. Falta:
  - decidir a tag (ex.: `<versão>-py<PY>`) e acrescentar a variante no `docker-image.yml` (`target: release-py`, `scan: true`, smoke test);
  - acrescentar ao smoke test um `import mapscript` e a conferência do constraints;
  - decidir se ela substitui a `release` sem Python ou se as duas são publicadas.
- [ ] **Sem `.dockerignore`.** Os `COPY` são específicos e nada vaza para a imagem, mas o `.git` vai junto no contexto de build.
