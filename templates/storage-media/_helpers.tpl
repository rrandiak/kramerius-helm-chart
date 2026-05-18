{{/*
storage-media helpers — configuration.properties media conversion section.

Generates the convert.* properties consumed by Kramerius workers during ingestion.
Referenced by kramerius.configurationProperties.baseContent in root _helpers.tpl.

Values source: convert.imageserver.* and convert.audioserver.*
See templates/storage-media/values.part.yaml for the full key reference.
*/}}

{{/*
Media configuration.properties section from convert values.
Returns a rendered ## Media section string (not a JSON map, because property order
and grouping matter for operator readability).

Only emits non-empty values. When both imageserver and audioserver are disabled
(convert.useImageServer=false, convert.useAudioServer=false) nothing is emitted.
*/}}
{{- define "kramerius.configurationProperties.mediaSection" -}}
{{- $mc   := .Values.convert | default dict }}
{{- $img  := $mc.imageserver | default dict }}
{{- $aud  := $mc.audioserver | default dict }}
{{- $props := dict }}

{{/* Imageserver */}}
{{- $_ := set $props "convert.useImageServer" (toString (default false $img.enabled)) }}
{{- if $img.directory }}
{{- $_ := set $props "convert.imageServerDirectory" $img.directory }}
{{- end }}
{{- if kindIs "bool" $img.useContract }}
{{- $_ := set $props "convert.useContractAsSubfoldersName" ($img.useContract | toString) }}
{{- end }}
{{- if kindIs "bool" $img.subfolders }}
{{- $_ := set $props "convert.imageServerDirectorySubfolders" ($img.subfolders | toString) }}
{{- end }}
{{- if kindIs "bool" $img.removeExtensions }}
{{- $_ := set $props "convert.imageServerSuffix.removeFilenameExtensions" ($img.removeExtensions | toString) }}
{{- end }}
{{- if $img.tilesUrlPrefix }}
{{- $_ := set $props "convert.imageServerTilesURLPrefix" $img.tilesUrlPrefix }}
{{- end }}
{{- if $img.imagesUrlPrefix }}
{{- $_ := set $props "convert.imageServerImagesURLPrefix" $img.imagesUrlPrefix }}
{{- end }}
{{- if $img.suffixBig }}
{{- $_ := set $props "convert.imageServerSuffix.big" $img.suffixBig }}
{{- end }}
{{- if $img.suffixThumb }}
{{- $_ := set $props "convert.imageServerSuffix.thumb" $img.suffixThumb }}
{{- end }}
{{- if $img.suffixPreview }}
{{- $_ := set $props "convert.imageServerSuffix.preview" $img.suffixPreview }}
{{- end }}
{{- if hasKey $img "suffixTiles" }}
{{- $_ := set $props "convert.imageServerSuffix.tiles" (default "" $img.suffixTiles) }}
{{- end }}

{{/* Audioserver */}}
{{- $_ := set $props "convert.useAudioServer" (toString (default false $aud.enabled)) }}
{{- if $aud.urlPrefix }}
{{- $_ := set $props "convert.audioServerURLPrefix" $aud.urlPrefix }}
{{- end }}
{{- if $aud.directory }}
{{- $_ := set $props "convert.audioServerDirectory" $aud.directory }}
{{- end }}
{{- if kindIs "bool" $aud.subfolders }}
{{- $_ := set $props "convert.audioServerDirectorySubfolders" ($aud.subfolders | toString) }}
{{- end }}

{{- include "kramerius.configurationProperties.section" (dict "title" "Media" "map" $props) }}
{{- end }}

{{/*
Media storage mounts for workers (imageserver/audioserver/pdfserver).
Usage: include "kramerius.mediaStorageVolumeMounts" (dict "root" $root "readOnly" false)
*/}}
{{- define "kramerius.mediaStorageVolumeMounts" -}}
{{- $root := .root }}
{{- $ro := .readOnly | default false }}
{{- with (index $root.Values.storages "imageserver") }}{{- if .type }}
- mountPath: /data/imageserver
  name: imageserver-storage
  readOnly: {{ $ro }}
{{- end }}{{- end }}
{{- with (index $root.Values.storages "audioserver") }}{{- if .type }}
- mountPath: /data/audioserver
  name: audioserver-storage
  readOnly: {{ $ro }}
{{- end }}{{- end }}
{{- with (index $root.Values.storages "pdfserver") }}{{- if .type }}
- mountPath: /data/pdfserver
  name: pdfserver-storage
  readOnly: {{ $ro }}
{{- end }}{{- end }}
{{- end }}

{{/*
Media storage volumes for workers (imageserver/audioserver/pdfserver).
Usage: include "kramerius.mediaStorageVolumes" (dict "root" $root)
*/}}
{{- define "kramerius.mediaStorageVolumes" -}}
{{- $root := .root }}
{{- include "kramerius.sharedStorageVolume" (dict "root" $root "volumeName" "imageserver-storage" "storageKey" "imageserver") }}
{{- include "kramerius.sharedStorageVolume" (dict "root" $root "volumeName" "audioserver-storage" "storageKey" "audioserver") }}
{{- include "kramerius.sharedStorageVolume" (dict "root" $root "volumeName" "pdfserver-storage" "storageKey" "pdfserver") }}
{{- end }}
