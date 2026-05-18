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
Shared storage PVC/NFS fragments and Tomcat log volumes.
*/}}
{{- define "kramerius.storageNfsServer" -}}
{{- $root := .root }}
{{- $st := index $root.Values.storages .storageKey }}
{{- default $root.Values.storages.defaultNfsServer $st.nfsServer }}
{{- end }}

{{- define "kramerius.storagePvcStorageClass" -}}
{{- $root := .root }}
{{- $st := index $root.Values.storages .storageKey }}
{{- default $root.Values.defaultStorageClass $st.storageClass }}
{{- end }}

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

{{- define "kramerius.tomcatLogsPodNameEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
{{- end }}

{{/*
Hazelcast client address for configuration.properties (matches chart Service hazelcast:5701).
*/}}
{{- define "kramerius.hazelcastServerAddresses" -}}
{{- printf "hazelcast.%s.svc.cluster.local:5701" .Values.namespace }}
{{- end }}

{{/*
Where feature-specific Helm helpers live (templates/<feature>/_helpers.tpl):
  - configuration-properties — kramerius.configurationProperties.{section,baseContent,merged,extraToString}
  - storages — kramerius.storageNfsServer, storagePvc*, sharedStorageVolume, tomcatLogs*, tomcatLogsPodNameEnv
  - workers — kramerius.workerImage, workerImagePullPolicy, workerVolumeClaimTemplates, workers.configurationProperties, …
  - process-manager — kramerius.processManagerUrl, processManagerHost, processManager.matchLabels
  - catalina-opts — kramerius.mergeCatalinaOpts
  - observability — perAppJavaagent*, otelJvmOpts, observability.*
  - networking — kramerius.ingressAnnotationsWithOptionalOAuth, ingress.annotationsMergedYaml
  - keycloak, storage-akubra, index-solr, lock-server, commons-kramerius, storage-import, storage-media — configuration.properties sections
  - cdk — kramerius.cdk.configurationProperties.part (merged when includeCdk and Values.cdk.enabled)
*/}}

{{/*
Pod anti-affinity block — hard (required) or soft (preferred).
Dict: type ("hard"|"soft"), matchLabels (map), topologyKey (string, default "kubernetes.io/hostname").

  hard — requiredDuringSchedulingIgnoredDuringExecution: pods MUST land on distinct nodes.
         Use for stateful primaries or when split-brain risk is unacceptable.
  soft — preferredDuringSchedulingIgnoredDuringExecution (weight 100): scheduler prefers
         distinct nodes but will co-locate when the cluster has too few nodes.
         Use for horizontally scalable workers where tight packing is acceptable.

Usage (inside a pod spec, needs nindent 6 or 8 from call site):
  {{- include "kramerius.podAntiAffinity" (dict "type" .Values.foo.affinity.type "matchLabels" (fromYaml (include "kramerius.foo.matchLabels" .))) | nindent 6 }}
*/}}
{{- define "kramerius.podAntiAffinity" -}}
{{- $type        := .type        | default "hard" }}
{{- $matchLabels := .matchLabels | default dict }}
{{- $topologyKey := .topologyKey | default "kubernetes.io/hostname" }}
podAntiAffinity:
{{- if eq $type "hard" }}
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          {{- toYaml $matchLabels | nindent 10 }}
      topologyKey: {{ $topologyKey }}
{{- else }}
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            {{- toYaml $matchLabels | nindent 12 }}
        topologyKey: {{ $topologyKey }}
{{- end }}
{{- end }}

{{/*
Rollout checksums: hash values that feed mounted ConfigMaps / shared config so `helm upgrade` rolls pods when config changes.
Replicas are omitted so scaling does not force a rolling restart.
*/}}
{{- define "kramerius.checksum.krameriusPublicPod" -}}
{{- $kp := omit .Values.krameriusPublic "replicas" -}}
{{- mustToJson (dict "auth" .Values.auth "cdk" (.Values.cdk | default dict) "databases" .Values.databases "akubraConfig" .Values.akubraConfig "solrConfig" .Values.solrConfig "krameriusPublic" $kp "storages" .Values.storages "timezone" .Values.timezone "shadow" (.Values.shadow | default dict)) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.krameriusCuratorPod" -}}
{{- $kc := omit .Values.krameriusCurator "replicas" -}}
{{- mustToJson (dict "auth" .Values.auth "cdk" (.Values.cdk | default dict) "databases" .Values.databases "akubraConfig" .Values.akubraConfig "solrConfig" .Values.solrConfig "krameriusCurator" $kc "storages" .Values.storages "timezone" .Values.timezone "shadow" (.Values.shadow | default dict)) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.processManagerPod" -}}
{{- mustToJson (dict "auth" .Values.auth "databases" .Values.databases "processManager" .Values.processManager "storages" .Values.storages "timezone" .Values.timezone "shadow" (.Values.shadow | default dict)) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.workerPod" -}}
{{- $g := omit .group "replicas" -}}
{{- mustToJson (dict "akubraConfig" .root.Values.akubraConfig "solrConfig" .root.Values.solrConfig "workersDefaults" (.root.Values.workersDefaults | default dict) "group" $g "storages" .root.Values.storages "timezone" .root.Values.timezone "shadow" (.root.Values.shadow | default dict)) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.gatewayOpenrestyPod" -}}
{{- mustToJson (dict "gateway" .Values.gateway "namespace" .Values.namespace) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.gatewayManagementPod" -}}
{{- $py := .Files.Get "files/gateway/management.py" -}}
{{- $req := .Files.Get "files/gateway/requirements.txt" -}}
{{- $ep := .Files.Get "files/gateway/endpoints.txt" -}}
{{- $dash := .Files.Get "files/gateway/dashboard.html" -}}
{{- $dashcss := .Files.Get "files/gateway/dashboard.css" -}}
{{- mustToJson (dict "managementPy" $py "requirementsTxt" $req "endpointsTxt" $ep "dashboardHtml" $dash "dashboardCss" $dashcss "managementClient" .Values.gateway.managementClient) | sha256sum -}}
{{- end }}

{{- define "kramerius.checksum.hazelcastPod" -}}
{{- mustToJson (dict "hazelcast" .Values.hazelcast "timezone" .Values.timezone) | sha256sum -}}
{{- end }}

