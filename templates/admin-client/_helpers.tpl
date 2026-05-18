{{/*
Selector and pod template labels for admin-client (Deployment + Service).
*/}}
{{- define "kramerius.adminClient.matchLabels" -}}
app.kubernetes.io/name: admin-client
app.kubernetes.io/component: admin-client
{{- end }}

{{/*
Build globals.js content for the admin-client SPA.
coreBaseUrl is derived from networking.api host + tlsSecretName, suffixed with /search.
deployPath is always empty.
All other fields come from .Values.adminClient.config.
*/}}
{{- define "kramerius.adminClient.globalsJs" -}}
{{- $cfg := .Values.adminClient.config | default dict -}}
{{- $net := .Values.networking | default dict -}}
{{- $api := $net.api | default dict -}}

{{- $scheme := "http" -}}
{{- if ($api.tlsSecretName | default "") | trim -}}{{- $scheme = "https" -}}{{- end -}}

{{- $coreBaseUrl := printf "%s://%s/search" $scheme ($api.host | default "") -}}

var APP_GLOBAL = {
  coreBaseUrl: {{ $coreBaseUrl | squote }},
  userClientBaseUrl: {{ $cfg.userClientBaseUrl | default "" | squote }},
  deployPath: '',
  keycloak: {
    loginType: {{ $cfg.keycloakLoginType | default "all" | squote }}
  },
  homeDashboard: {{ $cfg.homeDashboard | default list | toJson }},
  devMode: {{ $cfg.devMode | default false }}
};
{{- end }}

{{/*
Checksum for admin-client pod template annotations.
Includes adminClient values (except replicas), generated globals.js, and networking inputs.
*/}}
{{- define "kramerius.checksum.adminClientPod" -}}
{{- $globalsJs := include "kramerius.adminClient.globalsJs" . -}}
{{- mustToJson (dict "adminClient" (omit .Values.adminClient "replicas") "networking" (.Values.networking | default dict) "globalsJs" $globalsJs) | sha256sum -}}
{{- end }}
