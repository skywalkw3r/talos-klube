# Harbor registry

Harbor (chart `harbor` from https://helm.goharbor.io, pinned in
[values.yaml](../app/charts/root-app/values.yaml) `versions.harbor`) gives
the cluster a local registry: a home for lab images, Trivy scanning, and
pull-through caches for docker.io / ghcr.io / quay.io.

One Argo Application, `harbor`
([templates/harbor.yaml](../app/charts/root-app/templates/harbor.yaml)),
with two sources rendered into the `harbor` namespace:

| Source | What it brings |
|---|---|
| upstream `harbor` chart | core, portal, registry, jobservice, Trivy, internal Postgres + Redis, Harbor's nginx (`expose.type: clusterIP`, plain HTTP) |
| [app/charts/harbor-extras](../app/charts/harbor-extras) | `Gateway` (class `cilium`, HTTPS, cert from `internal-ca`), the `HTTPRoute` to nginx, and the token-signing certificate |

Storage is Rook-Ceph: the registry on `ceph-filesystem` (RWX, 100Gi
default, `harbor.registrySize`), the database, Redis, Trivy and job-log
volumes on `ceph-block`. The registry PVC carries
`argocd.argoproj.io/sync-options: Delete=false,Prune=false`, so disabling
or deleting the app leaves the images behind.

Harbor ships no CRDs, so nothing is added to the headlamp-viewer
`crdGroups`.

## Why it is wired this way

- **Own HTTPRoute instead of `expose.type: route`.** The chart's route has
  no `timeouts`, and with none set Cilium keeps Envoy's 15s route timeout,
  which runs from the end of the request to the end of the response, so
  any layer pull longer than 15s is cut off. Our route sets
  `timeouts.request: 0s`. nginx's 900s proxy timeouts and Envoy's
  stream-idle timeout still stop stuck transfers.
- **Every generated secret is supplied.** The chart fills unset secrets
  with `randAlphaNum`/`genCA`/`htpasswd` on each render. Argo CD
  re-renders on every sync, so those would change on every sync and the
  app would never settle. All of them come from one out-of-band Secret
  (below), except the token-signing cert, which cert-manager issues once
  (10y, self-signed, like the chart's own).
- **`updateStrategy: Recreate`.** The job-log PVC is RWO `ceph-block` and
  can't attach on a second node during a rolling update.

## Before enabling

`apps.harbor` defaults to `false`. Two things must exist first.

### 1. The `harbor-secrets` Secret (never committed)

```sh
kubectl create namespace harbor
REG_PW=$(openssl rand -hex 16)
kubectl -n harbor create secret generic harbor-secrets \
  --from-literal=HARBOR_ADMIN_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=secretKey="$(openssl rand -hex 8)" \
  --from-literal=secret="$(openssl rand -hex 8)" \
  --from-literal=CSRF_KEY="$(openssl rand -hex 16)" \
  --from-literal=JOBSERVICE_SECRET="$(openssl rand -hex 8)" \
  --from-literal=REGISTRY_HTTP_SECRET="$(openssl rand -hex 8)" \
  --from-literal=REGISTRY_PASSWD="$REG_PW" \
  --from-literal=REGISTRY_HTPASSWD="$(htpasswd -nbB harbor_registry_user "$REG_PW" | tr -d '\n')"
```

`secretKey`, `secret`, `JOBSERVICE_SECRET` and `REGISTRY_HTTP_SECRET` must
be exactly 16 characters; `CSRF_KEY` 32. `htpasswd` is in macOS's base
system (`apache2-utils` on Debian). With OpenBao wired up, an
`ExternalSecret` producing the same keys works just as well.

The admin password is only applied on first start. After that, change it
in the portal and keep this Secret in step.

### 2. A per-site hostname

`harbor.hostname` is the placeholder `harbor.example.internal`. It drives
`externalURL`, the Gateway listener and its certificate, so it must be the
name clients actually use. Set it, and `apps.harbor: true`, in the
cluster overlay (`values-proxmox.yaml`) **only if the name is safe to
publish**: a `.internal` name that doesn't identify the site. Otherwise
keep the overlay on a private fork or branch. (`argocd app set root-app -p …`
does not stick: root-app manages its own spec, and selfHeal reverts the
change.)

Then point DNS at the Gateway's address:

```sh
kubectl -n harbor get gateway harbor -o jsonpath='{.status.addresses[0].value}'
```

## Trusting the certificate

The serving cert comes from `internal-ca`. Docker/Podman/containerd
clients must trust that CA. Export it (see
[issuers values](../app/charts/issuers/values.yaml)) and install it per
client, e.g. Docker: `/etc/docker/certs.d/<hostname>/ca.crt`.

## Pull-through cache projects (post-install)

The chart doesn't create registries or projects. Once the portal is up,
create one registry endpoint and one proxy-cache project per upstream.
In the portal: **Registries → New Endpoint**, then **Projects → New
Project** with *Proxy Cache* on. Or with the API:

```sh
H=https://harbor.example.internal          # your site's hostname
A="admin:$(kubectl -n harbor get secret harbor-secrets \
  -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)"
api() { curl -fsS --cacert internal-ca.crt -u "$A" \
  -H 'Content-Type: application/json' "$@"; }

# endpoint-name  adapter-type  upstream-url            project
while read -r name type url project; do
  api -X POST "$H/api/v2.0/registries" \
    -d "{\"name\":\"$name\",\"type\":\"$type\",\"url\":\"$url\"}"
  id=$(api "$H/api/v2.0/registries?q=name%3D$name" | jq '.[0].id')
  api -X POST "$H/api/v2.0/projects" \
    -d "{\"project_name\":\"$project\",\"registry_id\":$id,\"metadata\":{\"public\":\"true\"}}"
done <<'EOF'
docker-hub   docker-hub   https://hub.docker.com  dockerhub
ghcr         github-ghcr  https://ghcr.io         ghcr
quay         quay         https://quay.io         quay
EOF
```

Pull through the cache by prefixing the project. Docker Hub official
images need `library/`:

```sh
docker pull harbor.example.internal/dockerhub/library/nginx:1.29
docker pull harbor.example.internal/quay/cilium/cilium:v1.20.4
```

Anonymous Docker Hub pulls are rate-limited per source IP, and the whole
cluster shares one. Adding Docker Hub credentials to the `docker-hub`
endpoint (portal → Registries → Edit) lifts the limit.

## Not done yet

- **Talos `RegistryMirrorConfig`.** Pointing the nodes' containerd at
  these mirrors (and trusting `internal-ca` on the nodes) is a follow-up.
  Talos config is now generated by OpenTofu (`tofu/talos.tf`). Because
  the hostname is site-specific, the mirror patch belongs there as a
  generated patch driven by a site variable, not in the committed
  `talos/patches/cluster.yaml`.
- **Internal Postgres password.** The chart has no `existingSecret` for
  its internal database, so it uses the chart default. The database is a
  ClusterIP Service reachable only from inside the cluster. Moving to an
  external database (e.g. CloudNativePG) with `database.external.existingSecret`
  would fix it.
