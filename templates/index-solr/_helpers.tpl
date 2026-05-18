{{/*
index-solr helpers — configuration.properties Solr section.

Moved here from root _helpers.tpl so the Solr feature owns its own template logic.
Referenced by kramerius.configurationProperties.baseContent in root _helpers.tpl.
*/}}

{{/*
Solr configuration.properties property map from root `solrConfig`.
Returns a JSON-encoded map consumed by kramerius.configurationProperties.section.
All keys are emitted even if empty, so operators can see what's set vs. blank.

Key mapping (values.yaml → configuration.properties):
  solrConfig.search               → solrSearchHost
  solrConfig.searchUseComposite   → solrSearch.useCompositeId
  solrConfig.processing           → solrProcessingHost
  solrConfig.sdnnt                → solrSdnntHost
  solrConfig.logs                 → k7.log.solr.point
  solrConfig.monitor              → api.monitor.point
  solrConfig.monitorThreshold     → api.monitor.threshold
  solrConfig.updates              → solrUpdatesHost (CDK mode)
  solrConfig.reharvest            → solrReharvestHost (CDK mode)
  solrConfig.clientConfig.*       → solr.apache.client.*
*/}}
{{- define "kramerius.solrConfigurationPropertyMap" -}}
{{- $root := . }}
{{- $s := $root.Values.solrConfig | default dict }}
{{- $out := dict
  "solrSearchHost"             (default "" $s.search)
  "solrSearch.useCompositeId"  (default false $s.searchUseComposite)
  "solrProcessingHost"         (default "" $s.processing)
  "solrSdnntHost"              (default "" $s.sdnnt)
  "k7.log.solr.point"          (default "" $s.logs)
  "api.monitor.point"          (default "" $s.monitor)
}}
{{- if $s.monitorThreshold }}
{{- $_ := set $out "api.monitor.threshold" ($s.monitorThreshold | toString) }}
{{- end }}
{{- if $s.updates }}
{{- $_ := set $out "solrUpdatesHost" $s.updates }}
{{- end }}
{{- if $s.reharvest }}
{{- $_ := set $out "solrReharvestHost" $s.reharvest }}
{{- end }}
{{- $cc := $s.clientConfig | default dict }}
{{- if $cc.maxConnections }}
{{- $_ := set $out "solr.apache.client.max_connections" ($cc.maxConnections | toString) }}
{{- end }}
{{- if $cc.maxPerRoute }}
{{- $_ := set $out "solr.apache.client.max_per_route" ($cc.maxPerRoute | toString) }}
{{- end }}
{{- if $cc.connectTimeout }}
{{- $_ := set $out "solr.apache.client.connect_timeout" ($cc.connectTimeout | toString) }}
{{- end }}
{{- if $cc.responseTimeout }}
{{- $_ := set $out "solr.apache.client.response_timeout" ($cc.responseTimeout | toString) }}
{{- end }}
{{- $out | toJson }}
{{- end }}

{{/*
Render Solr section as configuration.properties part.
Also validates CDK requirements: when cdk.enabled=true, updates and reharvest
must both be set.
*/}}
{{- define "kramerius.configurationProperties.solrSection" -}}
{{- $root := . }}
{{- $cdk := $root.Values.cdk | default dict }}
{{- $s := $root.Values.solrConfig | default dict }}
{{- if ($cdk.enabled | default false) }}
{{- if or (not $s.updates) (not $s.reharvest) }}
{{- fail "solrConfig.updates and solrConfig.reharvest are required when cdk.enabled=true" }}
{{- end }}
{{- end }}
{{- $solr := fromJson (include "kramerius.solrConfigurationPropertyMap" $root) }}
{{- include "kramerius.configurationProperties.section" (dict "title" "Solr" "map" $solr) }}
{{- end }}
