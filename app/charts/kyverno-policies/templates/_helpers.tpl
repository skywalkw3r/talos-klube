{{/* A policy's validationActions, falling back to the chart-wide default. */}}
{{- define "kyverno-policies.actions" -}}
{{- toYaml (.policy.validationActions | default .root.Values.validationActions) }}
{{- end }}

{{/* Every container in a Pod, init and ephemeral ones included. */}}
{{- define "kyverno-policies.allContainers" -}}
- name: containers
  expression: >-
    object.spec.containers +
    (has(object.spec.initContainers) ? object.spec.initContainers : []) +
    (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
{{- end }}
