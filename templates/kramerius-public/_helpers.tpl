{{/*
Selector and pod template labels for kramerius-public (StatefulSet + Service).
Indent with nindent as required by each call site (e.g. 4 for Service spec.selector, 6 for StatefulSet matchLabels, 8 for pod template metadata.labels).
*/}}
{{- define "kramerius.public.matchLabels" -}}
app.kubernetes.io/name: kramerius-public
app.kubernetes.io/component: kramerius-public
{{- end }}

{{/*
Public configuration.properties: shared feature sections + public extra.
Includes cdk (if enabled), commons-kramerius, database, index-solr, keycloak,
lock-server, process-manager, storage-akubra (if enabled), storage-import,
and storage-media.
*/}}
{{- define "kramerius.public.configurationProperties" -}}
{{- include "kramerius.configurationProperties.merged" (dict
  "root" .
  "extra" .Values.krameriusPublic.config.configurationPropertiesExtra
  "includeKrameriusJdbc" true
  "includeProcessManagerHost" true
  "includeKeycloak" true
  "includeCdk" true
) }}
{{- end }}

{{/*
Public server.xml override.
Supports new key krameriusPublic.serverXml and legacy krameriusPublic.config.serverXml.
*/}}
{{- define "kramerius.public.serverXml" -}}
{{- if .Values.krameriusPublic.serverXml }}
{{- .Values.krameriusPublic.serverXml }}
{{- else }}
{{- .Values.krameriusPublic.config.serverXml | default "" }}
{{- end }}
{{- end }}
