{{/*
Edge networking is driven only by .Values.networking.

  networking.enabled — if the key is absent, treated as true. If false, no Ingress and no Gateway API.
  networking.mode    — "ingress" | "gatewayApi" (case-insensitive, trimmed). Empty mode is treated as ingress.

Helpers output the string "true" or nothing, so use {{ if (include "..." .) }}.
*/}}
{{- define "kramerius.networking.ingressEnabled" -}}
{{- $net := .Values.networking | default dict -}}
{{- $umbrella := true -}}
{{- if hasKey $net "enabled" -}}
{{- $umbrella = $net.enabled | default false -}}
{{- end -}}
{{- $modeLower := $net.mode | default "" | trim | lower -}}
{{- if not $umbrella -}}
{{- else if eq $modeLower "gatewayapi" -}}
{{- else if or (eq $modeLower "ingress") (eq $modeLower "") -}}true{{- end -}}
{{- end }}

{{- define "kramerius.networking.gatewayApiEnabled" -}}
{{- $net := .Values.networking | default dict -}}
{{- $umbrella := true -}}
{{- if hasKey $net "enabled" -}}
{{- $umbrella = $net.enabled | default false -}}
{{- end -}}
{{- $modeLower := $net.mode | default "" | trim | lower -}}
{{- if not $umbrella -}}
{{- else if or (eq $modeLower "ingress") (eq $modeLower "") -}}
{{- else if eq $modeLower "gatewayapi" -}}true{{- end -}}
{{- end }}

{{/*
Fail the render when edge networking is active but required hosts (and TLS secrets) are missing.
Call from ingress.yaml / gatewayapi.yaml after confirming that mode’s resources are enabled.
*/}}
{{- define "kramerius.networking.validateEdgeHosts" -}}
{{- $net := .Values.networking | default dict -}}
{{- $api := $net.api | default dict -}}
{{- if not (($api.host | default "") | trim) -}}{{- fail "networking.api.host is required when networking.mode is ingress or gatewayApi" -}}{{- end -}}
{{- if not (($api.tlsSecretName | default "") | trim) -}}{{- fail "networking.api.tlsSecretName is required when networking.mode is ingress or gatewayApi" -}}{{- end -}}
{{- $pm := $net.processManager | default dict -}}
{{- if not (($pm.host | default "") | trim) -}}{{- fail "networking.processManager.host is required when edge networking is enabled" -}}{{- end -}}
{{- if not (($pm.tlsSecretName | default "") | trim) -}}{{- fail "networking.processManager.tlsSecretName is required when edge networking is enabled" -}}{{- end -}}
{{- if (.Values.adminClient.enabled | default false) -}}
{{- $ad := $net.admin | default dict -}}
{{- if not (($ad.host | default "") | trim) -}}{{- fail "networking.admin.host is required when adminClient.enabled is true" -}}{{- end -}}
{{- if not (($ad.tlsSecretName | default "") | trim) -}}{{- fail "networking.admin.tlsSecretName is required when adminClient.enabled is true" -}}{{- end -}}
{{- end -}}
{{- if (.Values.gateway.managementClient.enabled | default false) -}}
{{- $gm := $net.gatewayManager | default dict -}}
{{- if not (($gm.host | default "") | trim) -}}{{- fail "networking.gatewayManager.host is required when gateway.managementClient.enabled is true" -}}{{- end -}}
{{- if not (($gm.tlsSecretName | default "") | trim) -}}{{- fail "networking.gatewayManager.tlsSecretName is required when gateway.managementClient.enabled is true" -}}{{- end -}}
{{- end -}}
{{- if (.Values.observability.enabled | default false) -}}
{{- $hx := $net.hyperdx | default dict -}}
{{- if not (($hx.host | default "") | trim) -}}{{- fail "networking.hyperdx.host is required when observability.enabled is true" -}}{{- end -}}
{{- if not (($hx.tlsSecretName | default "") | trim) -}}{{- fail "networking.hyperdx.tlsSecretName is required when observability.enabled is true" -}}{{- end -}}
{{- end -}}
{{- end }}
