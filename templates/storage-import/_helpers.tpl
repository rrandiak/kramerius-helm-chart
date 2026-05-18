{{/*
storage-import helpers — import directory validation, volume mounts, and configuration.properties section.

Moved here from root _helpers.tpl so the import storage feature owns its own template logic.
Volume mount/volume helpers are referenced by statefulsets for curator and workers.
importDirectories is referenced by kramerius.configurationProperties.baseContent in root _helpers.tpl.
*/}}

{{/*
Returns the root import directory for configuration.properties (import.directory key).
Validates that all configured volume mountPaths are under storages.imports.directory.
*/}}
{{- define "kramerius.importDirectories" -}}
{{- $dir := .Values.storages.imports.directory }}
{{- range .Values.storages.imports.volumes }}
{{- if not (hasPrefix $dir .mountPath) }}
{{- fail (printf "Import volume %q mountPath %q is not under imports.directory %q" .name .mountPath $dir) }}
{{- end }}
{{- end }}
{{- $dir }}
{{- end }}

{{/*
Render Import section as configuration.properties part.
Omitted when no import root directory is configured.
*/}}
{{- define "kramerius.configurationProperties.importSection" -}}
{{- $dir := include "kramerius.importDirectories" . | trim }}
{{- if $dir }}
{{- include "kramerius.configurationProperties.section" (dict "title" "Import" "map" (dict "import.directory" $dir)) }}
{{- end }}
{{- end }}

{{/*
Import storage pod volumes — one PVC volume entry per configured import volume.
Usage: include "kramerius.importStorageVolumes" (dict "root" $)
Indent with nindent 8 under pod volumes.
*/}}
{{- define "kramerius.importStorageVolumes" -}}
{{- $root := .root }}
{{- range $imp := $root.Values.storages.imports.volumes }}
{{- $impName := printf "import-%s" $imp.name }}
{{- $claimName := $imp.existingClaim | default (printf "%s-%s" (include "kramerius.fullname" $root) ($impName | trunc 63 | trimSuffix "-")) }}
- name: {{ $impName }}
  persistentVolumeClaim:
    claimName: {{ $claimName | quote }}
{{- end }}
{{- end }}

{{/*
Import storage volume mounts — each volume mounted at its configured mountPath.
Usage: include "kramerius.importStorageVolumeMounts" (dict "root" $ "readOnly" true)
Indent with nindent 12 under container volumeMounts.
readOnly: true for curator (read-only access); false for workers (read-write).
*/}}
{{- define "kramerius.importStorageVolumeMounts" -}}
{{- $root := .root }}
{{- $ro := .readOnly | default false }}
{{- range $imp := $root.Values.storages.imports.volumes }}
- mountPath: {{ $imp.mountPath }}
  name: import-{{ $imp.name }}
  readOnly: {{ $ro }}
{{- end }}
{{- end }}
