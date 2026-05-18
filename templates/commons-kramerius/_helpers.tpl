{{/*
commons-kramerius helpers — shared configuration.properties and logging defaults.
*/}}

{{/*
Shared Kramerius configuration.properties property map for public/curator/workers.
Returns JSON map consumed by kramerius.configurationProperties.section.
*/}}
{{- define "kramerius.commonsKrameriusConfigurationPropertyMap" -}}
{{- $app := .Values.krameriusCommon | default dict }}
{{- $oai := $app.oai | default dict }}
{{- $out := dict }}
{{- if $app.client }}
{{- $_ := set $out "client" $app.client }}
{{- end }}
{{- if $oai.rowsInResults }}
{{- $_ := set $out "oai.rowsInResults" ($oai.rowsInResults | toString) }}
{{- end }}
{{- if $oai.setEdmDataProvider }}
{{- $_ := set $out "oai.set.edm.dataProvider" $oai.setEdmDataProvider }}
{{- end }}
{{- if $oai.setEdmProvider }}
{{- $_ := set $out "oai.set.edm.provider" $oai.setEdmProvider }}
{{- end }}
{{- if $app.xForwardedFor }}
{{- $_ := set $out "x_ip_forwarded_enabled_for" $app.xForwardedFor }}
{{- end }}
{{- if $app.httpTimeout }}
{{- $_ := set $out "http.timeout" ($app.httpTimeout | toString) }}
{{- end }}
{{- if $app.defaultEduIdType }}
{{- $_ := set $out "default.eduid.type" $app.defaultEduIdType }}
{{- end }}
{{- if $app.acronym }}
{{- $_ := set $out "acronym" $app.acronym }}
{{- end }}
{{- if $app.sdnntAcronym }}
{{- $_ := set $out "sdnnt.check.acronym" $app.sdnntAcronym }}
{{- end }}
{{- if kindIs "bool" $app.turnOffPdfCheck }}
{{- $_ := set $out "turnOffPdfCheck" ($app.turnOffPdfCheck | toString) }}
{{- end }}
{{- if $app.generatePdfMaxRange }}
{{- $_ := set $out "generatePdfMaxRange" ($app.generatePdfMaxRange | toString) }}
{{- end }}
{{- $out | toJson }}
{{- end }}

{{/*
Render shared Kramerius section as configuration.properties part.
*/}}
{{- define "kramerius.configurationProperties.commonsKrameriusSection" -}}
{{- $props := fromJson (include "kramerius.commonsKrameriusConfigurationPropertyMap" .) }}
{{- include "kramerius.configurationProperties.section" (dict "title" "Kramerius properties" "map" $props) }}
{{- end }}

{{/*
configuration.properties assembly (shared base + merged content + shadow overlays).
Feature sections (Akubra, Solr, Keycloak, …) live in their feature directories.
*/}}

{{- define "kramerius.configurationProperties.section" -}}
{{- $m := .map | default dict }}
{{- if gt (len $m) 0 }}
## {{ .title }}
{{- range $k := sortAlpha (keys $m) }}
{{ $k }}={{ toString (index $m $k) }}
{{- end }}
{{- end }}
{{- end }}

{{- define "kramerius.configurationProperties.extraToString" -}}
{{- if kindIs "slice" . }}
{{- range . }}
{{- printf "%s=%v\n" .key .value }}
{{- end }}
{{- else }}
{{- . | default "" | trim }}
{{- end }}
{{- end }}

{{- define "kramerius.configurationProperties.baseContent" -}}
{{- $root := .root }}
{{- $includeKrameriusJdbc := .includeKrameriusJdbc | default false }}
{{- $includeProcessManagerHost := .includeProcessManagerHost | default false }}
{{- $includeKeycloak := .includeKeycloak | default false }}
{{- $appPart := include "kramerius.configurationProperties.commonsKrameriusSection" $root | trim }}
{{- $krameriusJdbcPart := "" }}
{{- if $includeKrameriusJdbc }}
{{- $krameriusJdbcPart = include "kramerius.configurationProperties.databaseSection" $root | trim }}
{{- end }}
{{- $processManagerPart := "" }}
{{- if $includeProcessManagerHost }}
{{- $processManagerPart = include "kramerius.configurationProperties.section" (dict "title" "Process Manager" "map" (dict "processManagerHost" (include "kramerius.processManagerHost" $root))) | trim }}
{{- end }}
{{- $importPart := include "kramerius.configurationProperties.importSection" $root | trim }}
{{- $keycloakPart := "" }}
{{- if $includeKeycloak }}
{{- $keycloakPart = include "kramerius.configurationProperties.keycloakSection" $root | trim }}
{{- end }}
{{- $mediaPart := include "kramerius.configurationProperties.mediaSection" $root | trim }}
{{- $parts := compact (list
  $appPart
  (include "kramerius.configurationProperties.akubraSection" $root)
  (include "kramerius.configurationProperties.solrSection" $root)
  (include "kramerius.configurationProperties.lockServerSection" $root)
  $keycloakPart
  $krameriusJdbcPart
  $processManagerPart
  $importPart
  $mediaPart
) }}
{{- join "\n" $parts }}
{{- end }}

{{/*
Dict: root, extra, includeKrameriusJdbc, includeProcessManagerHost, includeKeycloak,
      includeCdk (when true and Values.cdk.enabled, append kramerius.cdk.configurationProperties.part).
Global shadow: Values.shadow.configurationPropertiesExtra (appended last).
*/}}
{{- define "kramerius.configurationProperties.merged" -}}
{{- $root := .root }}
{{- $extra := include "kramerius.configurationProperties.extraToString" .extra | trim }}
{{- $includeKrameriusJdbc := .includeKrameriusJdbc | default false }}
{{- $includeProcessManagerHost := .includeProcessManagerHost | default false }}
{{- $includeKeycloak := .includeKeycloak | default false }}
{{- $includeCdk := .includeCdk | default false }}
{{- $base := include "kramerius.configurationProperties.baseContent" (dict
  "root" $root
  "includeKrameriusJdbc" $includeKrameriusJdbc
  "includeProcessManagerHost" $includeProcessManagerHost
  "includeKeycloak" $includeKeycloak
) | trim }}
{{- $body := "" }}
{{- if and $base $extra }}
{{- $body = printf "%s\n%s" $base $extra }}
{{- else if $extra }}
{{- $body = $extra }}
{{- else }}
{{- $body = $base }}
{{- end }}
{{- $cdkPart := "" }}
{{- if and $includeCdk (($root.Values.cdk | default dict).enabled | default false) }}
{{- $cdkPart = include "kramerius.cdk.configurationProperties.part" $root | trim }}
{{- end }}
{{- if and $body $cdkPart }}
{{- $body = printf "%s\n%s" $body $cdkPart }}
{{- else if $cdkPart }}
{{- $body = $cdkPart }}
{{- end }}
{{- $g := ((($root.Values.shadow) | default dict).configurationPropertiesExtra) | default "" | trim }}
{{- if and $body $g }}
{{- printf "%s\n%s" $body $g }}
{{- else if $g }}
{{- $g }}
{{- else }}
{{- $body }}
{{- end }}
{{- end }}

{{/*
Resolve logging.properties content with app-specific override and shared fallback.
Usage: include "kramerius.defaultLoggingProperties" (dict "root" . "value" .Values.krameriusPublic.loggingProperties)
*/}}
{{- define "kramerius.defaultLoggingProperties" -}}
{{- $root := .root }}
{{- $value := .value | default "" | trim }}
{{- if $value }}
{{- $value }}
{{- else }}
{{- $root.Values.defaultLoggingProperties | default "" | trim }}
{{- end }}
{{- end }}
