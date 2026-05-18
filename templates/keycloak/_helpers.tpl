{{/*
keycloak helpers — keycloak.json adapter config and configuration.properties Keycloak section.

Moved here from root _helpers.tpl so the Keycloak feature owns its own template logic.
Referenced by keycloak/configmap.yaml and by kramerius.configurationProperties.baseContent.
*/}}

{{/*
Keycloak adapter JSON for the keycloak.json ConfigMap.
Renders the full adapter config from auth.keycloak values.
Returns "{}" when auth.keycloak.realm is not set (no-op / unauthenticated mode).
*/}}
{{- define "kramerius.keycloakAdapterJson" -}}
{{- $kc := .Values.auth.keycloak | default dict }}
{{- if not $kc.realm }}
{}
{{- else }}
{{- $doc := dict
  "realm" $kc.realm
  "auth-server-url" $kc.authServerUrl
  "ssl-required" (default "external" $kc.sslRequired)
  "resource" $kc.resource
  "verify-token-audience" (default false $kc.verifyTokenAudience)
  "credentials" (dict "secret" (default "" $kc.secret))
  "confidential-port" (default 0 $kc.confidentialPort)
}}
{{- if $kc.useResourceRoleMappings }}
{{- $_ := set $doc "use-resource-role-mappings" true }}
{{- end }}
{{- $_ := set $doc "policy-enforcer" (default (dict) $kc.policyEnforcer) }}
{{- toPrettyJson $doc }}
{{- end }}
{{- end }}

{{/*
Keycloak configuration.properties property map from auth.keycloak.
Returns a JSON-encoded map with token URL, client ID, and secret.
Returns an empty map when auth.keycloak.realm is not set.

Key mapping (values.yaml → configuration.properties):
  auth.keycloak.authServerUrl + realm → keycloak.tokenurl
  auth.keycloak.resource              → keycloak.clientId
  auth.keycloak.secret                → keycloak.secret
*/}}
{{- define "kramerius.keycloakConfigurationPropertyMap" -}}
{{- $root := . }}
{{- $kc := $root.Values.auth.keycloak | default dict }}
{{- if not $kc.realm }}
{{- dict | toJson }}
{{- else }}
{{- $base := trimSuffix "/" (default "" $kc.authServerUrl) }}
{{- $token := printf "%s/realms/%s/protocol/openid-connect/token" $base $kc.realm }}
{{- dict
  "keycloak.tokenurl" $token
  "keycloak.clientId" (default "" $kc.resource)
  "keycloak.secret"   (default "" $kc.secret)
| toJson }}
{{- end }}
{{- end }}

{{/*
Render Keycloak section as configuration.properties part.
Used by shared configuration builder for public/curator/workers.
Returns empty string when Keycloak is not configured.
*/}}
{{- define "kramerius.configurationProperties.keycloakSection" -}}
{{- $props := fromJson (include "kramerius.keycloakConfigurationPropertyMap" .) }}
{{- include "kramerius.configurationProperties.section" (dict "title" "Keycloak" "map" $props) }}
{{- end }}
