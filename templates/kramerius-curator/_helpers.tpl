{{/*
Selector and pod template labels for kramerius-curator (StatefulSet + Service).
Indent with nindent as required by each call site.
*/}}
{{- define "kramerius.curator.matchLabels" -}}
app.kubernetes.io/name: kramerius-curator
app.kubernetes.io/component: kramerius-curator
{{- end }}

{{/*
Curator configuration.properties: shared feature sections + curator extra.
Includes cdk (if enabled), commons-kramerius, database, index-solr, keycloak,
lock-server, process-manager, storage-akubra (if enabled), storage-import,
and storage-media.
*/}}
{{- define "kramerius.curator.configurationProperties" -}}
{{- include "kramerius.configurationProperties.merged" (dict
  "root" .
  "extra" .Values.krameriusCurator.config.configurationPropertiesExtra
  "includeKrameriusJdbc" true
  "includeProcessManagerHost" true
  "includeKeycloak" true
  "includeCdk" true
) }}
{{- end }}

{{/*
Curator server.xml override.
Supports new key krameriusCurator.serverXml and legacy krameriusCurator.config.serverXml.
*/}}
{{- define "kramerius.curator.serverXml" -}}
{{- if .Values.krameriusCurator.serverXml }}
{{- .Values.krameriusCurator.serverXml }}
{{- else }}
{{- .Values.krameriusCurator.config.serverXml | default "" }}
{{- end }}
{{- end }}
