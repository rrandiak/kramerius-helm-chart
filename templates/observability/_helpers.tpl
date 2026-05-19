{{/*
observability helpers — shared names, labels, and optional resources.
*/}}

{{- define "kramerius.checksum.clickhousePod" -}}
{{- $otel := ((.Values.observability | default dict).otel | default dict) -}}
{{- $ch   := ((.Values.observability | default dict).clickhouse | default dict) -}}
{{- mustToJson (dict "collector" ($otel.collector | default dict) "retentionDays" ($ch.retentionDays | default 90) "user" ($ch.user | default "") "password" ($ch.password | default "")) | sha256sum -}}
{{- end }}

{{- define "kramerius.observability.enabled" -}}
{{- ((.Values.observability | default dict).enabled | default false) | toString -}}
{{- end }}

{{- define "kramerius.observability.vectorName" -}}vector{{- end }}
{{- define "kramerius.observability.clickhouseName" -}}clickhouse{{- end }}
{{- define "kramerius.observability.hyperdxName" -}}hyperdx{{- end }}
{{- define "kramerius.observability.otelCollectorName" -}}otel-collector{{- end }}

{{- define "kramerius.observability.otelCollectorEnabled" -}}
{{- $otel := (((.Values.observability | default dict).otel) | default dict) -}}
{{- $collector := ($otel.collector | default dict) -}}
{{- ($collector.enabled | default false) | toString -}}
{{- end }}

{{- define "kramerius.observability.otelExporterEndpoint" -}}
{{- printf "http://%s.%s.svc.cluster.local:4317" (include "kramerius.observability.otelCollectorName" .) .Values.namespace -}}
{{- end }}

{{- define "kramerius.observability.vectorPipeline" -}}
{{- $v := ((.Values.observability | default dict).vector | default dict) -}}
{{- $endpoints := list -}}
{{- range splitList "\n" (.Files.Get "files/gateway/endpoints.txt") -}}
{{- $line := trim . -}}
{{- if and $line (not (hasPrefix "#" $line)) -}}
{{- $endpoints = append $endpoints $line -}}
{{- end -}}
{{- end -}}
{{- if $v.pipeline -}}
{{- $v.pipeline -}}
{{- else -}}
enrichment_tables:
  geoip_db:
    type: mmdb
    path: /var/lib/vector/geoip.mmdb
  asn_db:
    type: mmdb
    path: /var/lib/vector/asn.mmdb

sources:
  nginx_access:
    type: file
    include:
      - /var/log/nginx/access.log
      - /var/log/nginx/access.log.1
    read_from: beginning

transforms:
  parse_nginx:
    type: remap
    inputs:
      - nginx_access
    source: |-
      parsed = parse_json!(.message)
      ts, err = parse_timestamp(string!(parsed.time_local), format: "%d/%b/%Y:%H:%M:%S %z")
      uri_parts = split(string!(parsed.request_uri), "?", limit: 2)
      . = {}
      _ts = if err == null { ts } else { now() }
      .timestamp = format_timestamp!(_ts, format: "%Y-%m-%d %H:%M:%S%.3f")
      .remote_addr = string!(parsed.remote_addr)
      .is_private_ip = (ip_cidr_contains("10.0.0.0/8", .remote_addr) ?? false) ||
                        (ip_cidr_contains("172.16.0.0/12", .remote_addr) ?? false) ||
                        (ip_cidr_contains("192.168.0.0/16", .remote_addr) ?? false) ||
                        (ip_cidr_contains("127.0.0.0/8", .remote_addr) ?? false) ||
                        (ip_cidr_contains("169.254.0.0/16", .remote_addr) ?? false)
      .request_method = string!(parsed.request_method)
      .request_uri = string!(parsed.request_uri)
      .path = string!(uri_parts[0])
      .query_params = string(uri_parts[1]) ?? ""
      .status = to_int!(parsed.status)
      .body_bytes_sent = to_int!(parsed.body_bytes_sent)
      .response_time_ms = to_int(to_float!(parsed.request_time) * 1000.0)
      .http_referer = string(parsed.http_referer) ?? ""
      .http_user_agent = string(parsed.http_user_agent) ?? ""
      .actor = string(parsed.actor) ?? ""
      .endpoint = "unknown"
      _path = .path
{{- range $ep := $endpoints }}
{{- $regex := regexReplaceAll "\\{[^}]+\\}" ($ep | replace "." "\\.") "[^/]+" }}
      if .endpoint == "unknown" && match(_path, r'^{{ $regex }}$') { .endpoint = {{ $ep | quote }} }
{{- end }}
  enrich_geoip:
    type: remap
    inputs:
      - parse_nginx
    source: |-
      if !(to_bool(.is_private_ip) ?? false) {
        geo, err = get_enrichment_table_record("geoip_db", {"ip": .remote_addr})
        .continent_code = if err == null { string(geo.continent.code) ?? "" } else { "" }
        .country_code   = if err == null { string(geo.country.iso_code) ?? "" } else { "" }
        .city_name      = if err == null { string(geo.city.names.en) ?? "" } else { "" }

        asn, asn_err = get_enrichment_table_record("asn_db", {"ip": .remote_addr})
        .organization   = if asn_err == null { string(asn.autonomous_system_organization) ?? "" } else { "" }
      } else {
        .continent_code = ""
        .country_code   = ""
        .city_name      = ""
        .organization   = ""
      }

sinks:
  clickhouse_access_logs:
    type: clickhouse
    inputs:
      - enrich_geoip
    endpoint: "http://{{ include "kramerius.observability.clickhouseName" . }}.{{ .Values.namespace }}.svc.cluster.local:8123"
    database: default
    table: nginx_access_logs
    compression: gzip
    auth:
      strategy: basic
      user: {{ ((.Values.observability | default dict).clickhouse | default dict).user | default "" | quote }}
      password: {{ ((.Values.observability | default dict).clickhouse | default dict).password | default "" | quote }}
    buffer:
      type: disk
      max_size: 536870912
      when_full: block
{{- end -}}
{{- end }}

{{- define "kramerius.observability.otelCollectorConfig" -}}
{{- $root := . -}}
{{- $otel := (((.Values.observability | default dict).otel) | default dict) -}}
{{- $collector := ($otel.collector | default dict) -}}
{{- $ch := ((.Values.observability | default dict).clickhouse | default dict) -}}
{{- if $collector.config }}
{{- $collector.config -}}
{{- else }}
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    send_batch_size: 1000
    timeout: 1s
  tail_sampling:
    decision_wait: {{ default "10s" $collector.decisionWait }}
    num_traces: {{ default 50000 $collector.numTraces }}
    expected_new_traces_per_sec: {{ default 1000 $collector.expectedNewTracesPerSec }}
    policies:
      - name: errors-by-status-code
        type: status_code
        status_code:
          status_codes: [ERROR]
      - name: errors-by-http-status
        type: numeric_attribute
        numeric_attribute:
          key: http.response.status_code
          min_value: 400
          max_value: 599
      - name: slow-traces
        type: latency
        latency:
          threshold_ms: {{ default 1000 $collector.latencyThresholdMs }}
      - name: baseline-probabilistic
        type: probabilistic
        probabilistic:
          sampling_percentage: {{ default 10 $collector.probabilisticPercentage }}

exporters:
  clickhouse:
    endpoint: tcp://{{ printf "%s.%s.svc.cluster.local:9000" (include "kramerius.observability.clickhouseName" $root) $root.Values.namespace }}
    database: default
    traces_table_name: otel_traces
    ttl: {{ mul (default 90 $ch.retentionDays) 24 }}h
    create_schema: true
    username: {{ $ch.user | default "default" | quote }}
    password: {{ $ch.password | default "" | quote }}
    timeout: 10s
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, tail_sampling, batch]
      exporters: [clickhouse]
{{- end }}
{{- end }}

{{- define "kramerius.perAppJavaagentCatalinaFlags" -}}
{{- $flags := list }}
{{- range .javaagents }}
{{- $path := printf "/root/.kramerius4/javaagents/%s" .jarFile }}
{{- $suffix := .argumentSuffix | default "" }}
{{- $flags = append $flags (printf "-javaagent:%s%s" $path $suffix) }}
{{- end }}
{{- join " " $flags }}
{{- end }}

{{- define "kramerius.perAppJavaagentVolumeMounts" -}}
{{- $root := .root }}
{{- $javaagents := .javaagents | default list }}
{{- $otelComp := .otelComp | default dict }}
{{- range $javaagents }}
- mountPath: "/root/.kramerius4/javaagents/{{ .jarFile }}"
  name: javaagents-dir
  subPath: {{ .jarFile | quote }}
  readOnly: true
{{- end }}
{{- $otelJarName := (($root.Values.observability).otel).jarName | default "" }}
{{- if and $otelComp.enabled $otelJarName }}
- mountPath: "/root/.kramerius4/javaagents/{{ $otelJarName }}"
  name: javaagents-dir
  subPath: {{ $otelJarName | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "kramerius.perAppJavaagentVolumes" -}}
{{- $root := .root }}
{{- $javaagents := .javaagents | default list }}
{{- $otelComp := .otelComp | default dict }}
{{- $otelJarName := (($root.Values.observability).otel).jarName | default "" }}
{{- $needsVolume := or (gt (len $javaagents) 0) (and $otelComp.enabled $otelJarName) }}
{{- if $needsVolume }}
{{ include "kramerius.sharedStorageVolume" (dict "root" $root "volumeName" "javaagents-dir" "storageKey" "javaagents") }}
{{- end }}
{{- end }}

{{- define "kramerius.otelJvmOpts" -}}
{{- $root := .root }}
{{- $compOtel := .compOtel | default dict }}
{{- $serviceName := .serviceName | default "" }}
{{- if $compOtel.enabled }}
{{- $globalOtel := ($root.Values.observability).otel | default dict }}
{{- $jarName := $globalOtel.jarName | default "" }}
{{- if $jarName }}
{{- $opts := list }}
{{- $opts = append $opts (printf "-javaagent:/root/.kramerius4/javaagents/%s" $jarName) }}
{{- if $serviceName }}
{{- $opts = append $opts (printf "-Dotel.service.name=%s" $serviceName) }}
{{- $opts = append $opts "-Dotel.service.instance.id=$(POD_NAME)" }}
{{- $opts = append $opts "-Dotel.resource.attributes=host.name=$(POD_NAME)" }}
{{- end }}
{{- $endpoint := include "kramerius.observability.otelExporterEndpoint" $root }}
{{- $opts = append $opts (printf "-Dotel.exporter.otlp.endpoint=%s" $endpoint) }}
{{- $opts = append $opts (printf "-Dotel.exporter.otlp.protocol=%s" ($globalOtel.protocol | default "grpc")) }}
{{- $opts = append $opts "-Dotel.metrics.exporter=none" }}
{{- $opts = append $opts "-Dotel.logs.exporter=none" }}
{{- $methods := $compOtel.includeMethods | default list }}
{{- if $methods }}
{{- $opts = append $opts (printf "\"-Dotel.instrumentation.methods.include=%s\"" (join ";" $methods)) }}
{{- end }}
{{- join " " $opts }}
{{- end }}
{{- end }}
{{- end }}
