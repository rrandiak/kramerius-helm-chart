{{/*
CNPG process-manager cluster bootstrap secret name.
*/}}
{{- define "kramerius.cnpgBootstrapSecretName" -}}
process-db-secret
{{- end }}

{{/*
CNPG Kramerius cluster bootstrap secret name.
*/}}
{{- define "kramerius.cnpgKrameriusSecretName" -}}
kramerius-db-secret
{{- end }}

{{/*
Expand the name of the chart.
*/}}
{{- define "kramerius.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name prefix using release name.
*/}}
{{- define "kramerius.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kramerius.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Ingress annotations merged with optional nginx external auth (oauth2-proxy).
Dict: base (map), oauthProtected (bool), authUrl, authSignin
*/}}
{{- define "kramerius.ingressAnnotationsWithOptionalOAuth" -}}
{{- $base := .base | default dict }}
{{- $out := deepCopy $base }}
{{- if .oauthProtected }}
{{- $_ := set $out "nginx.ingress.kubernetes.io/auth-url" .authUrl }}
{{- $_ := set $out "nginx.ingress.kubernetes.io/auth-signin" (printf "%s?rd=https://$host$escaped_request_uri" .authSignin) }}
{{- end }}
{{- toYaml $out }}
{{- end }}

{{/*
Image pull secrets block — renders the imagePullSecrets list for pod specs.
*/}}
{{- define "kramerius.imagePullSecrets" -}}
{{- if .Values.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.imagePullSecrets }}
  - name: {{ .name }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Image pull secret resources — creates a kubernetes.io/dockerconfigjson Secret for each entry.
Include once in a dedicated template file.
*/}}
{{- define "kramerius.imagePullSecretResources" -}}
{{- range .Values.imagePullSecrets }}
{{- if .dockerconfigjson }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ .name }}
  namespace: {{ $.Values.namespace }}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {{ .dockerconfigjson }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Worker image: use group-specific image if defined, otherwise fall back to defaultWorkerImage
Usage: include "kramerius.workerImage" (dict "group" $group "values" $.Values)
*/}}
{{- define "kramerius.workerImage" -}}
{{- $img := .values.defaultWorkerImage }}
{{- if .group.image }}
{{- $img = .group.image }}
{{- end }}
{{- printf "%s:%s" $img.repository $img.tag }}
{{- end }}

{{/*
Worker image pull policy
*/}}
{{- define "kramerius.workerImagePullPolicy" -}}
{{- if .group.image }}
{{- default "Always" .group.image.pullPolicy }}
{{- else }}
{{- default "Always" .values.defaultWorkerImage.pullPolicy }}
{{- end }}
{{- end }}

{{/*
Process manager base URL for workers (cluster DNS; must match .Values.namespace).
*/}}
{{- define "kramerius.processManagerUrl" -}}
http://process-manager.{{ .Values.namespace }}.svc.cluster.local:8080/process-manager/api/
{{- end }}

{{/*
Process manager host for configuration.properties (processManagerHost key).
Used by kramerius-public and kramerius-curator.
*/}}
{{- define "kramerius.processManagerHost" -}}
http://process-manager.{{ .Values.namespace }}.svc.cluster.local:8080
{{- end }}

{{/*
One ## section for configuration.properties from a string map (sorted keys). Empty map yields empty string.
Dict: title (string), map (map)
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

{{/*
Hazelcast client address for configuration.properties (matches chart Service hazelcast:5701).
*/}}
{{- define "kramerius.hazelcastServerAddresses" -}}
{{- printf "hazelcast.%s.svc.cluster.local:5701" .Values.namespace }}
{{- end }}

{{/*
Keycloak adapter JSON for keycloak.json — same source as configuration.properties Keycloak lines (auth.keycloak).
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
Keycloak Java properties derived from auth.keycloak (token URL + client id + secret).
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
  "keycloak.secret" (default "" $kc.secret)
| toJson }}
{{- end }}
{{- end }}

{{/*
Akubra section: patterns from root `akubraConfig` + fixed paths matching pod mounts (/data/akubra/...).
*/}}
{{- define "kramerius.akubraConfigurationPropertyMap" -}}
{{- $root := . }}
{{- $cfg := $root.Values.akubraConfig | default dict }}
{{- $out := dict
  "objectStore.pattern" (default "" $cfg.objectStorePattern)
  "datastreamStore.pattern" (default "" $cfg.datastreamStorePattern)
}}
{{- $_ := set $out "objectStore.path" "/data/akubra/objectStore" }}
{{- $_ := set $out "datastreamStore.path" "/data/akubra/datastreamStore" }}
{{- $out | toJson }}
{{- end }}

{{/*
Solr section mapping from root `solrConfig`.
*/}}
{{- define "kramerius.solrConfigurationPropertyMap" -}}
{{- $root := . }}
{{- $s := $root.Values.solrConfig | default dict }}
{{- $out := dict
  "solrSearchHost" (default "" $s.search)
  "solrSearch.useCompositeId" (default false $s.searchUseComposite)
  "solrProcessingHost" (default "" $s.processing)
  "solrSdnntHost" (default "" $s.sdnnt)
  "k7.log.solr.point" (default "" $s.logs)
  "api.monitor.point" (default "" $s.monitor)
}}
{{- $out | toJson }}
{{- end }}

{{/*
Kramerius-app JDBC section from cnpg.kramerius.
Pool tuning keys (jdbcLeakDetectionThreshold, jdbcMaximumPoolSize, ...) can be supplied
by the user in `config.configurationPropertiesExtra` (appended after this section).
*/}}
{{- define "kramerius.configurationProperties.krameriusJdbcSection" -}}
{{- $root := .root }}
{{- $jdbc := dict
  "jdbcUrl" (printf "jdbc:postgresql://%s-rw:5432/%s" $root.Values.cnpg.kramerius.cluster.name "kramerius")
  "jdbcUserName" "kramerius"
}}
{{- $pw := $root.Values.cnpg.kramerius.password | default "" }}
{{- if $pw }}
{{- $_ := set $jdbc "jdbcUserPass" $pw }}
{{- end }}
{{- include "kramerius.configurationProperties.section" (dict "title" "Postgresql" "map" $jdbc) }}
{{- end }}

{{/*
Shared base for configuration.properties (Akubra + Solr + Keycloak + optional JDBC + optional Process Manager).
Used by kramerius-public, kramerius-curator, and workers.
Dict: root (context),
includeKrameriusJdbc (bool),
includeProcessManagerHost (bool),
*/}}
{{/*
Comma-joined list of import mount paths from storages.imports.
*/}}
{{- define "kramerius.importDirectories" -}}
{{- $dirs := list }}
{{- range .Values.storages.imports }}
{{- $dirs = append $dirs .mountPath }}
{{- end }}
{{- join "," $dirs }}
{{- end }}

{{- define "kramerius.configurationProperties.baseContent" -}}
{{- $root := .root }}
{{- $includeKrameriusJdbc := .includeKrameriusJdbc | default false }}
{{- $includeProcessManagerHost := .includeProcessManagerHost | default false }}
{{- $akubra := fromJson (include "kramerius.akubraConfigurationPropertyMap" $root) }}
{{- $solr := fromJson (include "kramerius.solrConfigurationPropertyMap" $root) }}
{{- $keycloak := fromJson (include "kramerius.keycloakConfigurationPropertyMap" $root) }}
{{- $krameriusJdbcPart := "" }}
{{- if $includeKrameriusJdbc }}
{{- $krameriusJdbcPart = include "kramerius.configurationProperties.krameriusJdbcSection" (dict "root" $root) | trim }}
{{- end }}
{{- $processManagerPart := "" }}
{{- if $includeProcessManagerHost }}
{{- $processManagerPart = include "kramerius.configurationProperties.section" (dict "title" "Process Manager" "map" (dict "processManagerHost" (include "kramerius.processManagerHost" $root))) | trim }}
{{- end }}
{{- $importDirs := include "kramerius.importDirectories" $root }}
{{- $importPart := "" }}
{{- if $importDirs }}
{{- $importPart = include "kramerius.configurationProperties.section" (dict "title" "Import" "map" (dict "import.directory" $importDirs)) | trim }}
{{- end }}
{{- $parts := compact (list
  (include "kramerius.configurationProperties.section" (dict "title" "Akubra" "map" $akubra))
  (include "kramerius.configurationProperties.section" (dict "title" "Solr" "map" $solr))
  (include "kramerius.configurationProperties.section" (dict "title" "Keycloak" "map" $keycloak))
  $krameriusJdbcPart
  $processManagerPart
  $importPart
) }}
{{- join "\n" $parts }}
{{- end }}

{{/*
Final configuration.properties: baseContent + per-component extra (trimmed).
Used by kramerius-public, kramerius-curator, and workers.
Dict: root,
extra (string),
includeKrameriusJdbc (bool),
includeProcessManagerHost (bool),
*/}}
{{- define "kramerius.configurationProperties.merged" -}}
{{- $root := .root }}
{{- $extra := .extra | default "" | trim }}
{{- $includeKrameriusJdbc := .includeKrameriusJdbc | default false }}
{{- $includeProcessManagerHost := .includeProcessManagerHost | default false }}
{{- $base := include "kramerius.configurationProperties.baseContent" (dict
  "root" $root
  "includeKrameriusJdbc" $includeKrameriusJdbc
  "includeProcessManagerHost" $includeProcessManagerHost
) | trim }}
{{- if and $base $extra }}
{{- printf "%s\n%s" $base $extra }}
{{- else if $extra }}
{{- $extra }}
{{- else }}
{{- $base }}
{{- end }}
{{- end }}

{{/*
Process-manager configuration.properties: Keycloak + extra.
No Akubra, Solr, or JDBC — the process manager gets JDBC credentials via env vars.
Dict: root, extra (string).
*/}}
{{- define "kramerius.configurationProperties.processManagerMerged" -}}
{{- $root := .root }}
{{- $extra := .extra | default "" | trim }}
{{- $keycloak := fromJson (include "kramerius.keycloakConfigurationPropertyMap" $root) }}
{{- $base := include "kramerius.configurationProperties.section" (dict "title" "Keycloak" "map" $keycloak) | trim }}
{{- if and $base $extra }}
{{- printf "%s\n%s" $base $extra }}
{{- else if $extra }}
{{- $extra }}
{{- else }}
{{- $base }}
{{- end }}
{{- end }}

{{/*
NFS server for a storage entry (uses storages.defaultNfsServer when storage.nfsServer is empty).
Usage: include "kramerius.storageNfsServer" (dict "root" $ "storageKey" "import")
*/}}
{{- define "kramerius.storageNfsServer" -}}
{{- $root := .root }}
{{- $st := index $root.Values.storages .storageKey }}
{{- default $root.Values.storages.defaultNfsServer $st.nfsServer }}
{{- end }}

{{/*
PVC StorageClass for a storage entry (uses defaultStorageClass when storage.storageClass is empty).
Usage: include "kramerius.storagePvcStorageClass" (dict "root" $ "storageKey" "akubraObjectStore")
*/}}
{{- define "kramerius.storagePvcStorageClass" -}}
{{- $root := .root }}
{{- $st := index $root.Values.storages .storageKey }}
{{- default $root.Values.defaultStorageClass $st.storageClass }}
{{- end }}

{{/*
PVC name for a storage: existing claimName or chart-generated name.
Usage: include "kramerius.storagePvcName" (dict "root" $ "storageKey" "akubra")
*/}}
{{- define "kramerius.storagePvcName" -}}
{{- $root := .root }}
{{- $key := .storageKey }}
{{- $st := index $root.Values.storages $key }}
{{- if $st.existingClaim }}
{{- $st.existingClaim }}
{{- else }}
{{- printf "%s-%s" (include "kramerius.fullname" $root) $key | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
One volume block (nfs or pvc) for any shared storage key.
Usage: include "kramerius.sharedStorageVolume" (dict "root" $ "volumeName" "javaagents-dir" "storageKey" "javaagents")
*/}}
{{- define "kramerius.sharedStorageVolume" -}}
{{- $root := .root }}
{{- $volName := .volumeName }}
{{- $key := .storageKey }}
{{- $st := index $root.Values.storages $key }}
{{- if and $st (or (eq $st.type "nfs") (eq $st.type "pvc")) }}
- name: {{ $volName }}
  persistentVolumeClaim:
    claimName: {{ include "kramerius.storagePvcName" (dict "root" $root "storageKey" $key) | quote }}
{{- end }}
{{- end }}

{{/*
Import storage volumes — one PVC volume per entry in storages.imports.
Usage: include "kramerius.importStorageVolumes" (dict "root" $)
*/}}
{{- define "kramerius.importStorageVolumes" -}}
{{- $root := .root }}
{{- range $imp := $root.Values.storages.imports }}
{{- $impName := printf "import-%s" $imp.name }}
{{- $claimName := $imp.existingClaim | default (printf "%s-%s" (include "kramerius.fullname" $root) ($impName | trunc 63 | trimSuffix "-")) }}
- name: {{ $impName }}
  persistentVolumeClaim:
    claimName: {{ $claimName | quote }}
{{- end }}
{{- end }}

{{/*
Import storage volume mounts — each mounted at its own mountPath.
Usage: include "kramerius.importStorageVolumeMounts" (dict "root" $ "readOnly" true)
*/}}
{{- define "kramerius.importStorageVolumeMounts" -}}
{{- $root := .root }}
{{- $ro := .readOnly | default false }}
{{- range $imp := $root.Values.storages.imports }}
- mountPath: {{ $imp.mountPath }}
  name: import-{{ $imp.name }}
  readOnly: {{ $ro }}
{{- end }}
{{- end }}

{{/*
Tomcat logs: NFS volume when tomcatLogs.type is nfs.
Usage: include "kramerius.tomcatLogsNfsVolume" (dict "root" $ "volumeName" "kramerius-public-tomcat-logs" "tomcatLogs" <config>)
*/}}
{{- define "kramerius.tomcatLogsNfsVolume" -}}
{{- $root := .root }}
{{- $volName := .volumeName }}
{{- $tl := .tomcatLogs }}
{{- if and $tl (eq $tl.type "nfs") }}
- name: {{ $volName }}
  nfs:
    server: {{ default $root.Values.storages.defaultNfsServer $tl.nfsServer | quote }}
    path: {{ $tl.nfsPath | quote }}
{{- end }}
{{- end }}

{{/*
Tomcat logs: volumeClaimTemplates fragment when tomcatLogs.type is pvc.
Usage: include "kramerius.tomcatLogsVolumeClaimTemplates" (dict "root" $ "volumeName" "kramerius-public-tomcat-logs" "tomcatLogs" <config>)
*/}}
{{- define "kramerius.tomcatLogsVolumeClaimTemplates" -}}
{{- $root := .root }}
{{- $volName := .volumeName }}
{{- $tl := .tomcatLogs }}
{{- if and $tl (eq $tl.type "pvc") }}
{{- $default := $root.Values.defaultStorageClass }}
volumeClaimTemplates:
  - metadata:
      name: {{ $volName }}
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: {{ default $default $tl.storageClass | quote }}
      resources:
        requests:
          storage: {{ $tl.size }}
{{- end }}
{{- end }}

{{/*
Fixed path for the JVM -javaagent JAR in the container (single file mount from storages.javaagents).
*/}}
{{- define "kramerius.javaagentJarMountPath" -}}/root/.kramerius4/javaagent.jar{{- end }}

{{/*
Merge env.CATALINA_OPTS with optional -javaagent and extra flags.
Dict: root (context), base (string from env.CATALINA_OPTS), componentExtra (optional per-workload string).
Order: base heap/user opts, then -javaagent, then javaagent.extraCatalinaOpts, then componentExtra.
*/}}
{{- define "kramerius.mergeCatalinaOpts" -}}
{{- $root := .root }}
{{- $base := .base | default "" | trim }}
{{- $comp := .componentExtra | default "" | trim }}
{{- $ja := $root.Values.javaagent }}
{{- $suffix := $ja.agentArgumentSuffix | default "" }}
{{- if and $ja.enabled ($ja.configFile.enabled | default false) (eq $suffix "") }}
{{- $suffix = printf "=%s" $ja.configFile.mountPath }}
{{- end }}
{{- $out := $base }}
{{- if $ja.enabled }}
{{- $flag := printf "-javaagent:%s%s" (include "kramerius.javaagentJarMountPath" $root) $suffix }}
{{- if $out }}
{{- $out = printf "%s %s" $out $flag }}
{{- else }}
{{- $out = $flag }}
{{- end }}
{{- end }}
{{- $extra := $ja.extraCatalinaOpts | default "" | trim }}
{{- if and $ja.enabled $extra }}
{{- if $out }}
{{- $out = printf "%s %s" $out $extra }}
{{- else }}
{{- $out = $extra }}
{{- end }}
{{- end }}
{{- if $comp }}
{{- if $out }}
{{- $out = printf "%s %s" $out $comp }}
{{- else }}
{{- $out = $comp }}
{{- end }}
{{- end }}
{{- $out }}
{{- end }}

{{/*
Downward API POD_NAME — required for Tomcat logs volume subPathExpr.
Indent with nindent 12 under container env.
*/}}
{{- define "kramerius.tomcatLogsPodNameEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
{{- end }}

{{/*
Javaagent volume mounts (jar + optional config file). Dict: root
Indent with nindent 12 under container volumeMounts.
*/}}
{{- define "kramerius.javaagentVolumeMounts" -}}
{{- $root := .root }}
{{- if $root.Values.javaagent.enabled -}}
- mountPath: {{ include "kramerius.javaagentJarMountPath" $root | quote }}
  name: javaagents-dir
  subPath: {{ $root.Values.javaagent.jarFile | default "opentelemetry-javaagent.jar" | quote }}
  readOnly: true
{{- if $root.Values.javaagent.configFile.enabled }}
- mountPath: {{ $root.Values.javaagent.configFile.mountPath | quote }}
  name: javaagent-config
  subPath: {{ $root.Values.javaagent.configFile.key | quote }}
  readOnly: true
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Javaagent-related pod volumes (javaagents storage + optional config ConfigMap). Dict: root
*/}}
{{- define "kramerius.javaagentVolumes" -}}
{{- $root := .root }}
{{- if $root.Values.javaagent.enabled }}
{{ include "kramerius.sharedStorageVolume" (dict "root" $root "volumeName" "javaagents-dir" "storageKey" "javaagents") }}
{{- if $root.Values.javaagent.configFile.enabled }}
- name: javaagent-config
  configMap:
    name: kramerius-javaagent-config
{{- end }}
{{- end }}
{{- end }}

{{/*
Rollout checksums: hash values that feed mounted ConfigMaps / shared config so `helm upgrade` rolls pods when config changes.
Replicas are omitted so scaling does not force a rolling restart.
*/}}
{{- define "kramerius.checksum.krameriusPublicPod" -}}
{{- $kp := omit .Values.krameriusPublic "replicas" -}}
{{- mustToJson (dict "auth" .Values.auth "cnpg" .Values.cnpg "akubraConfig" .Values.akubraConfig "solrConfig" .Values.solrConfig "javaagent" .Values.javaagent "krameriusPublic" $kp "storages" .Values.storages "timezone" .Values.timezone "tomcatShared" .Values.tomcatShared) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.krameriusCuratorPod" -}}
{{- $kc := omit .Values.krameriusCurator "replicas" -}}
{{- mustToJson (dict "auth" .Values.auth "cnpg" .Values.cnpg "akubraConfig" .Values.akubraConfig "solrConfig" .Values.solrConfig "javaagent" .Values.javaagent "krameriusCurator" $kc "storages" .Values.storages "timezone" .Values.timezone "tomcatShared" .Values.tomcatShared) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.processManagerPod" -}}
{{- mustToJson (dict "auth" .Values.auth "cnpg" .Values.cnpg "processManager" .Values.processManager "storages" .Values.storages "timezone" .Values.timezone "tomcatShared" .Values.tomcatShared) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.workerPod" -}}
{{- $g := omit .group "replicas" -}}
{{- mustToJson (dict "akubraConfig" .root.Values.akubraConfig "solrConfig" .root.Values.solrConfig "defaultWorkerImage" .root.Values.defaultWorkerImage "group" $g "imagePullSecrets" .root.Values.imagePullSecrets "javaagent" .root.Values.javaagent "storages" .root.Values.storages "timezone" .root.Values.timezone "tomcatShared" .root.Values.tomcatShared) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.gatewayOpenrestyPod" -}}
{{- mustToJson (dict "gateway" .Values.gateway "namespace" .Values.namespace "elkEnabled" .Values.elk.enabled) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.elkPod" -}}
{{- mustToJson (dict "elk" .Values.elk "namespace" .Values.namespace) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.adminClientPod" -}}
{{- mustToJson (dict "adminClient" (omit .Values.adminClient "replicas")) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.hazelcastPod" -}}
{{- mustToJson (dict "hazelcast" .Values.hazelcast "timezone" .Values.timezone) | sha256sum -}}
{{- end }}

{{- define "kramerius.kibanaInvestigatePath" -}}
/app/dashboards#/view/4c54599c-9e2a-4dab-9461-880fe550642b
{{- end }}
