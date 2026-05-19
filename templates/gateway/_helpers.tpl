{{/*
Gateway shared labels for selectors.
*/}}
{{- define "kramerius.gateway.matchLabels" -}}
app.kubernetes.io/name: gateway
app.kubernetes.io/component: gateway
{{- end }}

{{/*
Management client (FastAPI) labels.
*/}}
{{- define "kramerius.gateway.management.matchLabels" -}}
app.kubernetes.io/name: gateway-management
app.kubernetes.io/component: gateway-management
{{- end }}

{{/*
Render 429 template file with placeholder substitutions.
Supported placeholders:
  __ERROR429_INFO__
*/}}
{{- define "kramerius.gateway.render429Template" -}}
{{- $src := .source -}}
{{- $content := .root.Files.Get $src -}}
{{- $info := .root.Values.gateway.error429Info | default "" -}}
{{- $out := replace "__ERROR429_INFO__" $info $content -}}
{{- $out -}}
{{- end }}

{{/*
True if gateway.caching is enabled and at least one rule uses proxy_cache (needs disk cache path).
*/}}
{{- define "kramerius.gateway.cachingDiskEnabled" -}}
{{- $c := .Values.gateway.caching | default dict -}}
{{- if not ($c.enabled | default false) -}}false{{- else -}}
{{- $any := false -}}
{{- range $c.rules | default list -}}
{{- if eq (.cacheType | default "proxy_cache") "proxy_cache" -}}{{- $any = true -}}{{- end -}}
{{- end -}}
{{- $any | toString -}}
{{- end -}}
{{- end }}

{{/*
Lua module ratelimit_config — GCRA burst fractions, poll interval, Redis connection, user resolution URL.
Consumed by gateway_config.lua and ratelimiter.lua.
*/}}
{{- define "kramerius.gateway.rateLimitConfigLua" -}}
{{- $rl := .Values.gateway.rateLimiting | default dict -}}
{{- $ur := .Values.gateway.userResolution | default dict -}}
{{- $rd := .Values.gateway.redis | default dict -}}
return {
  rl_burst  = {{ $rl.rlBurst | default 0.5 }},
  dl_burst  = {{ $rl.dlBurst | default 0.5 }},
  poll_secs = {{ .Values.gateway.pollIntervalSeconds | default 5 }},
  redis = {
    host     = "gateway-redis.{{ .Values.namespace }}.svc.cluster.local",
    port     = 6379,
    password = {{ $rd.password | default "" | quote }},
  },
  user_resolution = {
    enabled   = {{ $ur.enabled | default false }},
    cache_ttl = {{ $ur.cacheTtlSeconds | default 300 }},
    url       = "http://kramerius-public.{{ .Values.namespace }}.svc.cluster.local:8080/search/api/client/v7.0/user",
  },
  session_affinity = {
    {{- $sa := .Values.gateway.sessionAffinity | default dict }}
    enabled          = {{ $sa.enabled | default true }},
    refresh_interval = {{ $sa.refreshIntervalSeconds | default 5 }},
    backends = {
      { name = "public",  dns_name = "kramerius-public.{{ .Values.namespace }}.svc.cluster.local",  port = 8080, fallback = "http://kramerius-public.{{ .Values.namespace }}.svc.cluster.local:8080" },
      { name = "curator", dns_name = "kramerius-curator.{{ .Values.namespace }}.svc.cluster.local", port = 8080, fallback = "http://kramerius-curator.{{ .Values.namespace }}.svc.cluster.local:8080" },
    },
  },
}
{{- end }}

{{/*
Lua module cache_config — consumed by response_cache.lua (always present; may be enabled=false).
*/}}
{{- define "kramerius.gateway.cacheConfigLua" -}}
{{- $c := .Values.gateway.caching | default dict -}}
{{- $rules := $c.rules | default list -}}
return {
  enabled = {{ $c.enabled | default false }},
  methods = {
{{- $mets := $c.methods | default (list "GET" "HEAD") -}}
{{- range $i, $m := $mets }}{{ if $i }}, {{ end }}{{ $m | quote }}{{- end }}
  },
  memory = { maxEntryBytes = {{ ($c.memory | default dict).maxEntryBytes | default 2097152 | int }} },
  rules = {
{{- range $i, $r := $rules }}
    {
      pathTemplates = {
{{- range $j, $p := $r.pathTemplates | default list }}
        {{ $p | quote }}{{ if lt (add1 $j) (len ($r.pathTemplates | default list)) }},{{ end }}
{{- end }}
      },
      cacheType = {{ $r.cacheType | default "proxy_cache" | quote }},
      ttl = {{ $r.ttl | int }},
      minHits = {{ $r.minHits | default 2 | int }},
{{- if eq ($r.cacheType | default "proxy_cache") "proxy_cache" }}
      namedLocation = {{ printf "@gw_cache_%d" $i | quote }},
{{- end }}
    }{{ if lt (add1 $i) (len $rules) }},{{ end }}
{{- end }}
  }
}
{{- end }}

