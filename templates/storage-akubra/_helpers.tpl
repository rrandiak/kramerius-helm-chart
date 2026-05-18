{{/*
storage-akubra helpers — configuration.properties Akubra section.

Moved here from root _helpers.tpl so the Akubra storage feature owns its own template logic.
Referenced by kramerius.configurationProperties.baseContent in root _helpers.tpl.
*/}}

{{/*
Akubra feature switch.
Defaults to enabled when the flag is not set.
*/}}
{{- define "kramerius.akubra.enabled" -}}
{{- $cfg := .Values.akubraConfig | default dict }}
{{- if hasKey $cfg "enabled" -}}
{{- $cfg.enabled | toString -}}
{{- else -}}
true
{{- end -}}
{{- end }}

{{/*
Akubra configuration.properties property map.
Returns a JSON-encoded map consumed by kramerius.configurationProperties.section.
Paths are fixed to match pod mount points (/data/akubra/...); patterns come from akubraConfig values.

Key mapping (values.yaml → configuration.properties):
  akubraConfig.objectStore.pattern     → objectStore.pattern
  akubraConfig.datastreamStore.pattern → datastreamStore.pattern
  (fixed)                             → objectStore.path    = /data/akubra/objectStore
  (fixed)                             → datastreamStore.path = /data/akubra/datastreamStore
*/}}
{{- define "kramerius.akubraConfigurationPropertyMap" -}}
{{- $root := . }}
{{- $cfg := $root.Values.akubraConfig | default dict }}
{{- if ne (include "kramerius.akubra.enabled" $root) "true" }}
{{- dict | toJson }}
{{- else }}
{{- $obj := $cfg.objectStore | default dict }}
{{- $ds := $cfg.datastreamStore | default dict }}
{{- $out := dict
  "objectStore.pattern"     (default (default "" $cfg.objectStorePattern) $obj.pattern)
  "datastreamStore.pattern" (default (default "" $cfg.datastreamStorePattern) $ds.pattern)
}}
{{- $_ := set $out "objectStore.path"     "/data/akubra/objectStore" }}
{{- $_ := set $out "datastreamStore.path" "/data/akubra/datastreamStore" }}
{{- $out | toJson }}
{{- end }}
{{- end }}

{{/*
Render Akubra section as configuration.properties part.
*/}}
{{- define "kramerius.configurationProperties.akubraSection" -}}
{{- $props := fromJson (include "kramerius.akubraConfigurationPropertyMap" .) }}
{{- include "kramerius.configurationProperties.section" (dict "title" "Akubra" "map" $props) }}
{{- end }}
