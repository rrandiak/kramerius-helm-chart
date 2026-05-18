{{/*
Selector and pod template labels for Hazelcast lock-server (StatefulSet + headless Service).
*/}}
{{- define "kramerius.lockServer.matchLabels" -}}
app.kubernetes.io/name: hazelcast
app.kubernetes.io/component: lock-server
{{- end }}

{{/*
Lock-server configuration.properties property map from Values.hazelcast.
Returns JSON map consumed by kramerius.configurationProperties.section.
*/}}
{{- define "kramerius.lockServerConfigurationPropertyMap" -}}
{{- $hz := .Values.hazelcast | default dict }}
{{- $out := dict
  "hazelcast.server.addresses" (include "kramerius.hazelcastServerAddresses" .)
  "hazelcast.instance" (default "akubrasync" $hz.instance)
  "hazelcast.user" (default "dev" $hz.user)
}}
{{- $out | toJson }}
{{- end }}

{{/*
Render lock-server section as configuration.properties part.
*/}}
{{- define "kramerius.configurationProperties.lockServerSection" -}}
{{- $props := fromJson (include "kramerius.lockServerConfigurationPropertyMap" .) }}
{{- include "kramerius.configurationProperties.section" (dict "title" "Lock Server" "map" $props) }}
{{- end }}
