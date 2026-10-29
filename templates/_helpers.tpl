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

Shared here (not feature-owned): kramerius.extraMounts.{validate,volumeMounts,volumes},
used by worker groups, kramerius-public, and kramerius-curator.
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
Extra mounts — shared by workers (per group) and the Kramerius apps (public, curator).
An entry mounts an existing NFS export or an existing PVC at an arbitrary path;
it never creates a PVC. Entry shape:

  name          — DNS-1123 label, max 57 chars (pod volume name is extra-<name>)
  mountPath     — absolute path; must not collide with a built-in mount
  type          — nfs or pvc
  nfsServer     — type nfs; empty uses storages.defaultNfsServer
  nfsPath       — type nfs; export path on the NFS server
  existingClaim — type pvc; name of a pre-existing PVC
  readOnly      — optional, default false

`context` is the values path used in error messages, e.g. "krameriusPublic.extraMounts".
*/}}

{{/*
Validate extra mounts. Fails the render on unusable input rather than letting the
API server reject the workload later.
Usage: include "kramerius.extraMounts.validate" (dict "root" $ "mounts" $mounts "reserved" $reserved "context" "krameriusPublic.extraMounts")
*/}}
{{- define "kramerius.extraMounts.validate" -}}
{{- $root := .root }}
{{- $mounts := .mounts | default list }}
{{- $reserved := .reserved | default list }}
{{- $ctx := .context | default "extraMounts" }}
{{- $defaultNfsServer := (($root.Values.storages | default dict).defaultNfsServer | default "") | toString | trim }}
{{- $seenNames := list }}
{{- $seenPaths := list }}
{{- range $m := $mounts }}
{{- $name := ($m.name | default "") | toString | trim }}
{{- $path := ($m.mountPath | default "") | toString | trim }}
{{- $type := ($m.type | default "") | toString | trim }}
{{- if not $name }}
  {{- fail (printf "%s: every entry requires a name" $ctx) }}
{{- end }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) }}
  {{- fail (printf "%s[%s]: name must be lowercase alphanumeric with dashes (used as a volume name)" $ctx $name) }}
{{- end }}
{{- if gt (len $name) 57 }}
  {{- fail (printf "%s[%s]: name must be at most 57 characters (volume name is extra-<name>)" $ctx $name) }}
{{- end }}
{{- if has $name $seenNames }}
  {{- fail (printf "%s: duplicate name %q" $ctx $name) }}
{{- end }}
{{- if not $path }}
  {{- fail (printf "%s[%s]: mountPath is required" $ctx $name) }}
{{- end }}
{{- if not (hasPrefix "/" $path) }}
  {{- fail (printf "%s[%s]: mountPath %q must be absolute" $ctx $name $path) }}
{{- end }}
{{- if has $path $reserved }}
  {{- fail (printf "%s[%s]: mountPath %q conflicts with a built-in volume mount" $ctx $name $path) }}
{{- end }}
{{- if has $path $seenPaths }}
  {{- fail (printf "%s: duplicate mountPath %q" $ctx $path) }}
{{- end }}
{{- if eq $type "nfs" }}
  {{- if not (($m.nfsPath | default "") | toString | trim) }}
    {{- fail (printf "%s[%s]: nfsPath is required when type is \"nfs\"" $ctx $name) }}
  {{- end }}
  {{- if not (or (($m.nfsServer | default "") | toString | trim) $defaultNfsServer) }}
    {{- fail (printf "%s[%s]: nfsServer is empty and storages.defaultNfsServer is not set" $ctx $name) }}
  {{- end }}
{{- else if eq $type "pvc" }}
  {{- if not (($m.existingClaim | default "") | toString | trim) }}
    {{- fail (printf "%s[%s]: existingClaim is required when type is \"pvc\" (extraMounts does not create PVCs)" $ctx $name) }}
  {{- end }}
{{- else }}
  {{- fail (printf "%s[%s]: type must be \"nfs\" or \"pvc\", got %q" $ctx $name $type) }}
{{- end }}
{{- $seenNames = append $seenNames $name }}
{{- $seenPaths = append $seenPaths $path }}
{{- end }}
{{- end }}

{{/*
Extra mount volumeMounts. Indent with nindent 12 under container volumeMounts.
Usage: include "kramerius.extraMounts.volumeMounts" (dict "mounts" $mounts)
*/}}
{{- define "kramerius.extraMounts.volumeMounts" -}}
{{- range $m := (.mounts | default list) }}
- mountPath: {{ $m.mountPath }}
  name: extra-{{ $m.name }}
  readOnly: {{ $m.readOnly | default false }}
{{- end }}
{{- end }}

{{/*
Extra mount pod volumes. type: nfs emits an inline NFS volume; type: pvc references
an existing claim. Indent with nindent 8 under pod volumes.
Usage: include "kramerius.extraMounts.volumes" (dict "root" $ "mounts" $mounts)
*/}}
{{- define "kramerius.extraMounts.volumes" -}}
{{- $root := .root }}
{{- range $m := (.mounts | default list) }}
- name: extra-{{ $m.name }}
{{- if eq $m.type "nfs" }}
  nfs:
    server: {{ default (($root.Values.storages | default dict).defaultNfsServer) $m.nfsServer | quote }}
    path: {{ $m.nfsPath | quote }}
{{- else }}
  persistentVolumeClaim:
    claimName: {{ $m.existingClaim | quote }}
{{- end }}
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
{{- $files := dict -}}
{{- range $path, $_ := .Files.Glob "files/gateway/{nginx.conf,*.lua,429.body,429.titles,endpoints.txt}" -}}
{{- $_ := set $files $path ($.Files.Get $path) -}}
{{- end -}}
{{- $vector := "" -}}
{{- if eq (include "kramerius.observability.enabled" .) "true" -}}
{{- $vector = include "kramerius.observability.vectorPipeline" . -}}
{{- end -}}
{{- mustToJson (dict "gateway" .Values.gateway "namespace" .Values.namespace "files" $files "vector" $vector) | sha256sum -}}
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

