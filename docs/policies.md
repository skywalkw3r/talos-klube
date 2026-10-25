# Kyverno policies

Kyverno (chart `kyverno` from https://kyverno.github.io/kyverno/, pinned in
[values.yaml](../app/charts/root-app/values.yaml) `versions.kyverno`) is the
cluster's policy engine. It ships with a small starter policy set that
**reports** on workload hygiene and blocks nothing yet.

Two Argo Applications from one template
([templates/kyverno.yaml](../app/charts/root-app/templates/kyverno.yaml)),
both switched by `apps.kyverno` and both in the `kyverno` namespace:

| Application (source) | What it brings |
|---|---|
| `kyverno` (upstream chart) | admission, background, cleanup and reports controllers, and the CRDs (`ServerSideApply`: several exceed the client-side apply limit) |
| `kyverno-policies` ([app/charts/kyverno-policies](../app/charts/kyverno-policies)) | the policies below, in sync wave 1. Root-app doesn't wait for `kyverno` to be healthy first, so on a fresh cluster this app skips the dry-run for the missing policy CRDs and retries until they exist |

## Where this fits next to Pod Security Admission

Talos enforces Pod Security Admission (PSA) at `baseline` on every
namespace, and namespaces that need more opt out with
`pod-security.kubernetes.io/enforce: privileged` (rook-ceph, monitoring,
kubevirt, cdi, vm-lab). PSA stays the security boundary. Kyverno adds the
checks PSA doesn't make (image tags, resources) and puts the results in
PolicyReports, for running Pods as well as new ones. The upstream
`kyverno-policies` chart isn't used: it re-implements the Pod Security
Standards that PSA already enforces.

The policies are CEL `ValidatingPolicy` resources (`policies.kyverno.io`).
Kyverno 1.19 deprecates the older `kyverno.io` `ClusterPolicy` kinds.

## The starter set

All three match Pods and run in every namespace except `kube-system` and
`kyverno`, which Kyverno's chart defaults leave out.

| Policy | Checks | Now | Enforce? |
|---|---|---|---|
| `disallow-latest-tag` | every container image has a tag other than `latest`, or a digest | Audit, Warn | **Yes, next.** Flip to `[Deny, Audit]` once the PolicyReports show no failures. Every chart here renders with pinned tags or digests (the one `:latest`, in Kyverno's own pre-delete Jobs, is in the out-of-scope `kyverno` namespace). Pods that operators create (Rook, CNPG, KubeVirt, Trivy) only show up in the live reports, so check those first. |
| `require-requests-limits` | every app container sets CPU and memory requests and a memory limit (no CPU limit: it throttles a container even on an idle node) | Audit, Warn | **No.** Most upstream charts here ship without resources by default (cert-manager, kube-prometheus-stack, Harbor, Argo CD, Cilium…), so Deny would block them. The report is a to-do list: fix it chart by chart in each Application's values. |
| `disallow-privileged-containers` | no privileged container outside namespaces labelled `pod-security.kubernetes.io/enforce=privileged` | Audit, Warn | **No.** PSA already denies exactly these Pods at admission, with the same label as the opt-out. The policy adds visibility: a background scan also finds privileged Pods still running in a namespace whose label was dropped. |

`Audit` records each result in a PolicyReport. `Warn` sends a violation
back to the client as a warning without blocking. kubectl prints it for a
Pod you create directly, but Pods made by a controller send it to the
controller, so for those the reports are where results show up.

Every policy is `failurePolicy: Ignore`: when Kyverno is down, Pods are
admitted unchecked rather than refused. That's also why one admission
controller replica is enough.

### Moving a policy to enforce

Set its `validationActions` in
[app/charts/kyverno-policies/values.yaml](../app/charts/kyverno-policies/values.yaml)
and merge:

```yaml
disallowLatestTag:
  enabled: true
  validationActions: [Deny, Audit]
```

`Deny` and `Warn` can't be combined. Check the policy's report for
failures first: existing Pods keep running, but a Pod that fails is
refused on its next restart or reschedule.

## Reading the results

The reports controller keeps one `PolicyReport` per checked resource, in
that resource's namespace, from admission and from a background scan every
hour. The checked resource is the report's `scope`.

```sh
kubectl get vpol                                       # the policies and their status
kubectl get polr -A                                    # pass/fail/warn counts per resource
kubectl get polr -A -o yaml | yq '.items[] | .scope as $s | .results[] | select(.result == "fail") | [.policy, $s.namespace, $s.name, .message]'
kubectl -n kyverno logs deploy/kyverno-reports-controller   # if reports stay empty
```

**Headlamp:** PolicyReports are in its custom-resource browser under
`wgpolicyk8s.io`, next to Trivy Operator's VulnerabilityReports and
ConfigAuditReports under `aquasecurity.github.io`: Kyverno for what is
admitted, Trivy for what's inside the images. The `headlamp-viewer`
token can read both: `kyverno.io`, `policies.kyverno.io` and
`wgpolicyk8s.io` are in its `crdGroups`
([app/charts/rbac/values.yaml](../app/charts/rbac/values.yaml)).

Argo CD doesn't track the report kinds (`reports.kyverno.io`,
`wgpolicyk8s.io`): its chart's default `resource.exclusions` already leave
them out, so report churn doesn't touch app sync status.

## Adding a policy

Add a template to `app/charts/kyverno-policies/templates/` following the
existing ones (an `enabled` toggle and `validationActions` in values.yaml,
the `kyverno-policies.actions` helper), start it in Audit, and test it
against sample Pods with the Kyverno CLI before merging:

```sh
helm template app/charts/kyverno-policies > /tmp/policies.yaml
kyverno apply /tmp/policies.yaml --resource pods.yaml --detailed-results --table
```

A policy using a `namespaceSelector` also needs the namespaces' labels,
passed with `--values-file` (a `cli.kyverno.io/v1alpha1` `Value` with a
`namespaceSelector` list).
