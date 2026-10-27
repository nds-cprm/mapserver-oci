# Exemplo com Docker Compose

A imagem fala **FastCGI** (não HTTP) na porta 8080. O exemplo [`nginx/`](nginx/) põe o nginx na frente: ele recebe HTTP na porta 8080 do host e repassa os pedidos de `/mapserver` ao MapServer com `fastcgi_pass`.

| Serviço | Imagem | Papel |
|---|---|---|
| `mapserver` | `ndscprm/mapserver` | FastCGI na porta 8080, **sem porta publicada**, raiz somente leitura com `tmpfs` em `/tmp` (usuário virtual do `nss_wrapper` e FIFO do log de erros) |
| `nginx` | `nginxinc/nginx-unprivileged` | HTTP na porta 8080 do host, sem root e com raiz somente leitura; configuração em [`nginx/conf/nginx/nginx.conf`](nginx/conf/nginx/nginx.conf) |

O nginx só sobe depois que o [healthcheck](../README.md#healthcheck) do MapServer passa. O healthcheck é declarado no Compose de propósito: o Podman ignora o `HEALTHCHECK` de imagens no formato OCI.

A porta 8080 do MapServer fica só na rede do Compose. Quem fala FastCGI direto com ela pode definir opções do MapServer e do GDAL em cada pedido (veja [Porta FastCGI](../README.md#porta-fastcgi)), então não acrescente `ports:` ao serviço `mapserver`.

## Uso

```sh
cd examples/nginx
docker compose up -d
curl 'http://localhost:8080/mapserver?map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities'
```

Para testar uma imagem construída localmente: `MAPSERVER_IMAGE=mapserver-oci docker compose up -d`. Com o Podman, `podman compose` funciona igual. A primeira subida leva cerca de 30 s, porque o nginx espera o primeiro healthcheck do MapServer.

Com o mapfile de exemplo da imagem (`map=DEFAULT`, camada `countries`):

| Serviço | URL |
|---|---|
| WMS GetCapabilities | `http://localhost:8080/mapserver?map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities` |
| WMS GetMap | `http://localhost:8080/mapserver?map=DEFAULT&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=countries&STYLES=&CRS=EPSG:4326&BBOX=-90,-180,90,180&WIDTH=800&HEIGHT=400&FORMAT=image/png` |
| OGC API (HTML) | `http://localhost:8080/mapserver/DEFAULT/ogcapi?f=html` |
| OGC API Features (GeoJSON) | `http://localhost:8080/mapserver/DEFAULT/ogcapi/collections/countries/items?f=json&limit=10` |

## Mapfiles próprios

Descomente o `volumes:` do serviço `mapserver` e ponha os mapfiles e os dados em `nginx/mapserver/`. Eles substituem o `/var/lib/mapserver` inteiro e são pedidos por caminho: `map=/var/lib/mapserver/<arquivo>.map`. O mapfile de demonstração fica escondido, e o `map=DEFAULT` deixa de funcionar. Para um nome curto (`map=<NOME>`), monte um `mapserver.conf` próprio com um alias em `MAPS`, a partir do da imagem, e mantenha as opções fixadas e o alias `HEALTHCHECK` (veja [Mapfiles e configuração](../README.md#mapfiles-e-configuração)).

Monte os mapfiles somente leitura (`:ro`): o MapServer carrega qualquer `.map` em `/var/lib/mapserver`, então o processo dele não deve conseguir gravar ali. A imagem não dá escrita nesse diretório a ninguém além do root, mas um volume gravável montado nele daria. Volume, ConfigMap e Secret no Kubernetes: [Seus mapfiles](../README.md#seus-mapfiles-volume-configmap-ou-secret).

## O `nginx.conf`

- `fastcgi_split_path_info ^(/mapserver)(/.*)$` separa o caminho da OGC API (`/mapserver/DEFAULT/ogcapi/...`) no `PATH_INFO`, que o MapServer usa para achar o mapa e a rota. Pedidos a `/mapserver?map=...` (WMS, WFS, WCS) não têm `PATH_INFO`.
- O `include fastcgi_params` fica dentro do `location`: qualquer `fastcgi_param` num bloco cancela os herdados do nível de cima.
- Os links da OGC API e o `OnlineResource` do WMS vêm do mapfile (`oga_onlineresource` e `ows_onlineresource`). No `default.map` eles são relativos (`/mapserver/DEFAULT/ogcapi` e `/mapserver`), então funcionam com este `location`. Para publicar em outro caminho, mude os dois juntos.
- `fastcgi_read_timeout 60s`: o MapServer não tem um tempo limite de pedido próprio. Um GetMap numa fonte lenta prende um worker (4 por padrão, `MAPSERVER_WORKERS`) até terminar, mesmo depois de o nginx desistir.
- `fastcgi_buffer_size` e `fastcgi_buffers` guardam respostas grandes (imagens de GetMap, GeoJSON) na memória do nginx, para liberar o worker logo.
- Fora de `/mapserver` e `/mapserver/...`, o nginx responde 404. O `location` é uma regex (`^/mapserver(/|$)`), e não o prefixo `/mapserver`, que mandaria também `/mapserverfoo` para o MapServer.

Verificado em 26/10/2026 com o Podman (`podman compose`): WMS GetCapabilities, GetMap e GetFeatureInfo, OGC API em JSON e HTML com os links certos, gzip e o healthcheck, que não grava nada no log. O teste de fumaça do CI ([`.github/scripts/smoke-test.sh`](../.github/scripts/smoke-test.sh)) usa este `nginx.conf`, então uma mudança nele é testada a cada build.
