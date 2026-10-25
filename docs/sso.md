# Single sign-on (Keycloak)

Keycloak is the cluster's identity provider. Argo CD and `kubectl` log in
through it, and Keycloak groups decide what you can do in each. The
admin kubeconfig and Argo CD's local `admin` stay as break-glass access.

| Piece | Where | What it does |
|---|---|---|
| `cloudnative-pg` app | [templates/cloudnative-pg.yaml](../app/charts/root-app/templates/cloudnative-pg.yaml) | CloudNativePG operator (`cnpg-system`) |
| `keycloak` app | [templates/keycloak.yaml](../app/charts/root-app/templates/keycloak.yaml) | upstream `keycloakx` chart in production mode (`start`) on Postgres |
| `keycloak-extras` app | [app/charts/keycloak-extras](../app/charts/keycloak-extras) | Postgres `Cluster` `keycloak-db`, `Gateway` + `HTTPRoute` (cert from `internal-ca`), realm import |
| `argo-cd` app | [app/charts/argo-cd](../app/charts/argo-cd), [templates/argo-cd.yaml](../app/charts/root-app/templates/argo-cd.yaml) | Argo CD's own `Gateway` + `HTTPRoute`, `oidc.config`, group → role mapping |
| `rbac` app | [templates/oidc-groups.yaml](../app/charts/rbac/templates/oidc-groups.yaml) | ClusterRoleBindings for the Keycloak groups |
| Talos | `oidc` in [tofu/talos.tf](../tofu/talos.tf) (or `OIDC_*` in [gen-config.sh](../talos/gen-config.sh)) | kube-apiserver trusts Keycloak tokens (`KubeAuthenticationConfig`) |

`apps.keycloak` switches the first three and Argo CD's SSO together.

## Identity model

The realm `klube` is imported on Keycloak's first start
([realm.yaml](../app/charts/keycloak-extras/templates/realm.yaml)). It
has two groups and two clients. Both clients are public and use PKCE, so
there is no client secret anywhere.

| Keycloak group | Kubernetes | Argo CD |
|---|---|---|
| `klube-admins` | `cluster-admin` | `role:admin` |
| `klube-viewers` | `view` + `headlamp-viewer-cluster-read` (no Secrets) | `role:readonly` |
| anyone else | nothing | nothing |

| Client | Used by | Redirect URIs |
|---|---|---|
| `kubernetes` | kubectl via [kubelogin](https://github.com/int128/kubelogin); also the kube-apiserver audience | `http://localhost:8000`, `http://localhost:18000` |
| `argocd` | Argo CD UI and `argocd login --sso` | `https://<argocd>/pkce/verify`, `http://localhost:8085/auth/callback` |

kube-apiserver sees a Keycloak user as `oidc:<username>` and its groups
as `oidc:<group>`. The prefix keeps a Keycloak name from ever matching a
built-in user or group such as `system:masters`.

The OIDC issuer is `https://<keycloak.hostname>/auth/realms/klube`.

## Setting it up

### 1. Hostnames and DNS

`keycloak.hostname` and `argoCd.hostname` in
[values.yaml](../app/charts/root-app/values.yaml) are placeholders
(`*.example.internal`). Each one drives a Gateway listener and its
certificate, and the Keycloak name is part of the issuer every client
checks. Set both in the cluster overlay (`values-proxmox.yaml`) **only if
the names are safe to publish**, the same rule as for Harbor
([docs/harbor.md](harbor.md#2-a-per-site-hostname)). Otherwise keep the
overlay on a private fork or branch.

Point DNS at the two Gateways:

```sh
kubectl -n keycloak get gateway keycloak -o jsonpath='{.status.addresses[0].value}'
kubectl -n argo-cd get gateway argocd -o jsonpath='{.status.addresses[0].value}'
```

The records must live in the DNS servers the nodes use (`dns_servers`),
not only on your workstation: kube-apiserver and Argo CD resolve the
Keycloak name themselves.

### 2. The `keycloak-admin` Secret (never committed)

This password is used once, to create the master-realm `admin` on an empty
database:

```sh
kubectl create namespace keycloak
kubectl -n keycloak create secret generic keycloak-admin \
  --from-literal=password="$(openssl rand -base64 24)"
```

The database credentials need nothing from you. CloudNativePG generates
them into `keycloak-db-app`.

### 3. Trust `internal-ca` on your workstation

Export it as in the [issuers values](../app/charts/issuers/values.yaml)
and add it to your OS or browser trust store:

```sh
kubectl -n cert-manager get secret internal-ca-root \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > internal-ca.crt   # gitignored
```

### 4. Users

Open `https://<keycloak>/auth/admin`, sign in as `admin` (password from
step 2), switch to the **klube** realm, then **Users → Add user**. Set a
temporary password under **Credentials**, and add the user to
`klube-admins` or `klube-viewers` under **Groups**.

### 5. Argo CD

`https://<argocd>` now shows **Log in via Keycloak**. On the CLI, through
the Gateway:

```sh
argocd login <argocd> --sso --grpc-web
```

### 6. kubectl (kube-apiserver OIDC)

This is a second `tofu apply`, because the CA that kube-apiserver must
trust for Keycloak is created inside the cluster. With Keycloak up and
`internal-ca.crt` exported (step 3), set `oidc` in
`tofu/site.auto.tfvars`:

```hcl
oidc = {
  issuer_url = "https://keycloak.example.internal/auth/realms/klube"
  ca_file    = "../internal-ca.crt"   # relative to tofu/
}
```

Then run `tofu -chdir=tofu apply`. It updates the running nodes and
kube-apiserver restarts without a reboot. On the shell path, set
`OIDC_ISSUER_URL` and `OIDC_CA_FILE` in `talos/env`, re-run
`talos/gen-config.sh` and `talosctl apply-config` each node.

Install kubelogin (`kubectl krew install oidc-login`; other methods in its
README) and add a user to your kubeconfig:

```sh
kubectl config set-credentials keycloak \
  --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login \
  --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://keycloak.example.internal/auth/realms/klube \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--certificate-authority="$PWD/internal-ca.crt"
kubectl config set-context keycloak --cluster=klube-pmx --user=keycloak
kubectl --context=keycloak auth whoami    # oidc:<you>, groups oidc:klube-…
```

`--cluster` is the cluster entry in the admin kubeconfig (`kubectl config
get-clusters`). kubelogin opens a browser for the login and caches the
token.

## Why it is wired this way

- **Production mode on CloudNativePG.** `start-dev` kept the realm in
  embedded H2, which was lost on every restart. The `keycloak-db` cluster
  has two instances (primary + streaming replica) on `ceph-block`, and the
  `Cluster` carries `Delete=false,Prune=false`, so disabling the app
  keeps the data.
- **The realm is imported once.** `--import-realm` skips a realm that
  already exists, so edits to `realm.yaml` only reach a fresh database.
  Change a live realm in the admin console, including the Argo CD
  redirect URIs if `argoCd.hostname` changes.
- **The groups mapper is on each client, not in a client scope.** Listing
  `clientScopes` in a realm import replaces Keycloak's built-in scopes
  (`basic`, `profile`, `email`, …) instead of adding to them.
- **`KubeAuthenticationConfig`, not `KubeAPIServerConfig`.** Talos always
  runs kube-apiserver with `--authentication-config` and rejects
  `--oidc-*` flags in `extraArgs`. A patch replaces the document's
  `configuration` whole, so ours repeats the generated anonymous
  `/livez`, `/readyz` and `/healthz` rules.
- **Argo CD trusts `internal-ca` through a labelled Secret.** A
  throwaway Certificate from `internal-ca` puts `ca.crt` into the
  `argo-cd` namespace with `app.kubernetes.io/part-of: argocd`, and
  `oidc.config` reads it as `rootCA: $internal-ca-trust:ca.crt`. No CA is
  committed. If `internal-ca` becomes a Venafi issuer, check that its
  Secrets still carry `ca.crt`.
- **Argo CD's route has `timeouts.request: 0s`.** Cilium otherwise keeps
  Envoy's 15s route timeout, which would cut the UI's event streams.

## When Keycloak is down

Argo CD SSO and kubectl OIDC logins stop working. Nothing else does: the
admin kubeconfig (client certificate) and Argo CD's local `admin` don't
depend on Keycloak.

```sh
kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Not done yet

- **Headlamp OIDC.** Headlamp still takes pasted ServiceAccount tokens.
  It needs its own Gateway and a Keycloak client.
- **Database backups.** `keycloak-db` has no backup to object storage yet.
  That belongs with the Velero work, or with CNPG's Barman Cloud plugin.
- **Realm as code after day one.** Something like keycloak-config-cli
  would reconcile the realm continuously, instead of importing it once.
