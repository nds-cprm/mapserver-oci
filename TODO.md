# TODO

Pendências de segurança e boas práticas levantadas na revisão do projeto.

## Prioridade média (CI e cadeia de suprimentos)

- [ ] **Workflow reutilizável por `@main`.** O CI chama o `reusable-publish-image.yml` do gdal-oci por `@main` (as actions dele já são fixadas por SHA e atualizadas pelo Dependabot de lá), então um commit no `main` do gdal-oci muda o CI daqui sem revisão. Quando o gdal-oci tiver uma tag do workflow, trocar o `uses:` por ela (ou pelo SHA, com a tag em comentário) e criar um `.github/dependabot.yml` com `package-ecosystem: github-actions` para propor as atualizações.
- [ ] **Assinatura das imagens.** SBOM e provenance (`mode=max`) já vêm do workflow reutilizável. Falta avaliar a assinatura com `cosign` (keyless, via OIDC), que seria feita lá, para todos os projetos.
- [ ] **Bases por tag, não por digest.** Os `FROM` usam tag e o build usa `pull: true`, então o mesmo commit pode gerar imagens diferentes. Avaliar a fixação por `@sha256:`, atualizada por Renovate ou Dependabot.
