{{/*
workers helpers — configuration.properties and optional config overrides.
*/}}

{{/*
Worker image: use group-specific image if defined, otherwise fall back to workersDefaults.image
Usage: include "kramerius.workerImage" (dict "group" $group "values" $.Values)
*/}}
{{- define "kramerius.workerImage" -}}
{{- $defaults := (.values.workersDefaults | default dict) }}
{{- $img := ($defaults.image | default dict) }}
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
{{- $defaults := (.values.workersDefaults | default dict) }}
{{- default "Always" (($defaults.image | default dict).pullPolicy) }}
{{- end }}
{{- end }}

{{/*
Worker volumeClaimTemplates combining tomcat logs and process logs PVC entries.
Usage: include "kramerius.workerVolumeClaimTemplates" (dict "root" $ "tomcatLogs" <config> "processLogs" <config>)
*/}}
{{- define "kramerius.workerVolumeClaimTemplates" -}}
{{- $root := .root }}
{{- $tl := .tomcatLogs }}
{{- $pl := .processLogs }}
{{- $default := $root.Values.defaultStorageClass }}
{{- $hasTomcat := and $tl (eq $tl.type "pvc") }}
{{- $hasProcess := and $pl (eq $pl.type "pvc") }}
{{- if or $hasTomcat $hasProcess }}
volumeClaimTemplates:
  {{- if $hasTomcat }}
  - metadata:
      name: worker-tomcat-logs
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: {{ default $default $tl.storageClass | quote }}
      resources:
        requests:
          storage: {{ $tl.size }}
  {{- end }}
  {{- if $hasProcess }}
  - metadata:
      name: worker-process-logs
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: {{ default $default $pl.storageClass | quote }}
      resources:
        requests:
          storage: {{ $pl.size }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Per-group extra mounts: workersDefaults.extraMounts entries first, then the group's own.
Usage: include "kramerius.workers.extraMounts" (dict "root" $root "group" $group) | fromJsonArray
*/}}
{{- define "kramerius.workers.extraMounts" -}}
{{- $defaults := (.root.Values.workersDefaults | default dict) }}
{{- concat ($defaults.extraMounts | default list) (.group.extraMounts | default list) | toJson }}
{{- end }}

{{/*
Validate a group's extra mounts. Fails the render on unusable input rather than
letting the API server reject the StatefulSet later.
Usage: include "kramerius.workers.validateExtraMounts" (dict "root" $root "group" $group "reserved" $wkReservedMounts)
*/}}
{{- define "kramerius.workers.validateExtraMounts" -}}
{{- $root := .root }}
{{- $group := .group }}
{{- include "kramerius.extraMounts.validate" (dict
  "root" $root
  "mounts" (include "kramerius.workers.extraMounts" (dict "root" $root "group" $group) | fromJsonArray)
  "reserved" (.reserved | default list)
  "context" (printf "workerGroups[%s].extraMounts" $group.name)
) }}
{{- end }}

{{/*
Extra mount volumeMounts for a worker group.
Usage: include "kramerius.workers.extraVolumeMounts" (dict "root" $root "group" $group)
Indent with nindent 12 under container volumeMounts.
*/}}
{{- define "kramerius.workers.extraVolumeMounts" -}}
{{- include "kramerius.extraMounts.volumeMounts" (dict
  "mounts" (include "kramerius.workers.extraMounts" (dict "root" .root "group" .group) | fromJsonArray)
) }}
{{- end }}

{{/*
Extra mount pod volumes for a worker group. type: nfs emits an inline NFS volume;
type: pvc references an existing claim.
Usage: include "kramerius.workers.extraVolumes" (dict "root" $root "group" $group)
Indent with nindent 8 under pod volumes.
*/}}
{{- define "kramerius.workers.extraVolumes" -}}
{{- $root := .root }}
{{- include "kramerius.extraMounts.volumes" (dict
  "root" $root
  "mounts" (include "kramerius.workers.extraMounts" (dict "root" $root "group" .group) | fromJsonArray)
) }}
{{- end }}

{{/*
Render key=value lines from a map in stable key order.
*/}}
{{- define "kramerius.workers.mapToProperties" -}}
{{- $m := . | default dict -}}
{{- range $k := sortAlpha (keys $m) }}
{{ $k }}={{ toString (index $m $k) }}
{{- end }}
{{- end }}

{{- define "kramerius.workers.pdfConfigMap" -}}
{{- $v := . | default dict -}}
{{- $out := dict -}}
{{- $apiClientPoint := ($v.apiClientPoint | default "") | toString | trim -}}
{{- $adminEmail := ($v.administratorEmail | default "") | toString | trim -}}
{{- $generatePdf := ($v.generatePdf | default dict) -}}
{{- $pdfSubject := ($generatePdf.subject | default "") | toString | trim -}}
{{- $pdfText := ($generatePdf.text | default "") | toString | trim -}}
{{- if $apiClientPoint }}{{- $_ := set $out "api.client.point" $apiClientPoint }}{{- end -}}
{{- if $adminEmail }}{{- $_ := set $out "administrator.email" $adminEmail }}{{- end -}}
{{- if $pdfSubject }}{{- $_ := set $out "generate.pdf.subject" $pdfSubject }}{{- end -}}
{{- if $pdfText }}{{- $_ := set $out "generate.pdf.text" $pdfText }}{{- end -}}
{{- $out | toJson -}}
{{- end }}

{{- define "kramerius.workers.mailConfigMap" -}}
{{- $v := . | default dict -}}
{{- $out := dict -}}
{{- $mailFromUser := ($v.fromUser | default "") | toString | trim -}}
{{- $smtp := ($v.smtp | default dict) -}}
{{- $smtpUser := ($smtp.user | default "") | toString | trim -}}
{{- $smtpPass := ($smtp.pass | default "") | toString | trim -}}
{{- $smtpHost := ($smtp.host | default "") | toString | trim -}}
{{- $smtpStartTlsEnable := ($smtp.startttlsEnable | default "") | toString | trim -}}
{{- $smtpPort := ($smtp.port | default "") | toString | trim -}}
{{- $smtpAuth := ($smtp.auth | default "") | toString | trim -}}
{{- $smtpSfPort := ($smtp.socketFactoryPort | default "") | toString | trim -}}
{{- $smtpSfClass := ($smtp.socketFactoryClass | default "") | toString | trim -}}
{{- if $mailFromUser }}{{- $_ := set $out "mail.from.user" $mailFromUser }}{{- end -}}
{{- if $smtpUser }}{{- $_ := set $out "mail.smtp.user" $smtpUser }}{{- end -}}
{{- if $smtpPass }}{{- $_ := set $out "mail.smtp.pass" $smtpPass }}{{- end -}}
{{- if $smtpHost }}{{- $_ := set $out "mail.smtp.host" $smtpHost }}{{- end -}}
{{- if $smtpStartTlsEnable }}{{- $_ := set $out "mail.smtp.startttls.enable" $smtpStartTlsEnable }}{{- end -}}
{{- if $smtpPort }}{{- $_ := set $out "mail.smtp.port" $smtpPort }}{{- end -}}
{{- if $smtpAuth }}{{- $_ := set $out "mail.smtp.auth" $smtpAuth }}{{- end -}}
{{- if $smtpSfPort }}{{- $_ := set $out "mail.smtp.socketFactory.port" $smtpSfPort }}{{- end -}}
{{- if $smtpSfClass }}{{- $_ := set $out "mail.smtp.socketFactory.class" $smtpSfClass }}{{- end -}}
{{- $out | toJson -}}
{{- end }}

{{- define "kramerius.workers.configurationProperties" -}}
{{- $root := .root }}
{{- $group := .group }}
{{- $defaults := ($root.Values.workersDefaults | default dict) }}
{{- $defaultCfg := ($defaults.config | default dict) }}
{{- $groupCfg := (($group.config) | default dict) }}
{{- $defaultToken := ($defaults.token | default dict) }}
{{- $groupToken := (($group.token) | default dict) }}
{{/* coalesce returns nil when every argument is empty; default "" keeps toString from yielding "<nil>" */}}
{{- $clientId := (coalesce $groupToken.clientId $defaultToken.clientId "") | default "" | toString | trim }}
{{- $secret := (coalesce $groupToken.secret $defaultToken.secret "") | default "" | toString | trim }}
{{- $tokenMap := dict }}
{{- if $clientId }}{{- $_ := set $tokenMap "process.token.clientId" $clientId }}{{- end }}
{{- if $secret }}{{- $_ := set $tokenMap "process.token.secret" $secret }}{{- end }}
{{- $groupConfiguration := ($group.configuration | default dict) }}
{{- $defaultPdfMap := fromJson (include "kramerius.workers.pdfConfigMap" ($defaults.configuration | default dict)) }}
{{- $groupPdfMap := fromJson (include "kramerius.workers.pdfConfigMap" $groupConfiguration) }}
{{- $workerMap := mergeOverwrite (deepCopy $defaultPdfMap) $groupPdfMap }}
{{- $tokenPart := include "kramerius.configurationProperties.section" (dict "title" "Worker token" "map" $tokenMap) | trim }}
{{- $workerPart := include "kramerius.configurationProperties.section" (dict "title" "Workers" "map" $workerMap) | trim }}
{{- $groupExtra := ($group.config | default dict).configurationPropertiesExtra | default "" | trim }}
{{- $extra := join "\n" (compact (list $tokenPart $workerPart $groupExtra)) | trim }}
{{- include "kramerius.configurationProperties.merged" (dict
  "root" $root
  "extra" $extra
  "includeKrameriusJdbc" true
  "includeProcessManagerHost" true
  "includeKeycloak" true
  "includeCdk" true
) }}
{{- end }}

{{- define "kramerius.workers.mailProperties" -}}
{{- $root := .root }}
{{- $group := .group }}
{{- $defaults := ($root.Values.workersDefaults | default dict) }}
{{- $groupMail := ($group.mail | default dict) }}
{{- $defaultMailMap := fromJson (include "kramerius.workers.mailConfigMap" ($defaults.mail | default dict)) }}
{{- $groupMailMap := fromJson (include "kramerius.workers.mailConfigMap" $groupMail) }}
{{- $mailMap := mergeOverwrite (deepCopy $defaultMailMap) $groupMailMap }}
{{- include "kramerius.workers.mapToProperties" $mailMap | trim }}
{{- end }}

{{/*
Worker server.xml override: group-level value or worker default.
*/}}
{{- define "kramerius.workers.serverXml" -}}
{{- $root := .root }}
{{- $group := .group }}
{{- $groupCfg := $group.config | default dict }}
{{- $defaultCfg := (($root.Values.workersDefaults | default dict).config | default dict) }}
{{- if $groupCfg.serverXml }}
{{- $groupCfg.serverXml }}
{{- else }}
{{- $defaultCfg.serverXml | default "" }}
{{- end }}
{{- end }}

{{/*
Worker lp.xml override: group-level value or worker default.
*/}}
{{- define "kramerius.workers.lpXml" -}}
{{- $root := .root }}
{{- $group := .group }}
{{- $groupCfg := $group.config | default dict }}
{{- $defaultCfg := (($root.Values.workersDefaults | default dict).config | default dict) }}
{{- if $groupCfg.lpXml }}
{{- $groupCfg.lpXml }}
{{- else }}
{{- $defaultCfg.lpXml | default "" }}
{{- end }}
{{- end }}
