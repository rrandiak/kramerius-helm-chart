{{/*
Global database mode fallback (cnpg or pg).
Used as default when a role does not declare its own mode.
*/}}
{{- define "kramerius.database.mode" -}}
{{- $all := .Values.databases | default dict -}}
{{- default "cnpg" (index $all "mode") -}}
{{- end }}

{{/*
Per-role database mode: role-level mode field, falling back to the global databases.mode.
Dict keys: root, role.
Returns: "cnpg", "pg", or "external".
*/}}
{{- define "kramerius.database.roleMode" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $roleMode := index $roleCfg "mode" | default "" | trim -}}
{{- if $roleMode -}}
{{- $roleMode -}}
{{- else -}}
{{- include "kramerius.database.mode" $root -}}
{{- end -}}
{{- end }}

{{/*
Database roles used for rendering DB resources and configuration sections.
Base roles: kramerius, process, users.
Cache role is enabled only in CDK mode.
*/}}
{{/* Comma-separated role names (not JSON): Helm 4 fromJson() expects an object; arrays break iteration. */}}
{{- define "kramerius.database.roles" -}}
{{- $roles := list "kramerius" "process" "users" -}}
{{- $cdk := .Values.cdk | default dict -}}
{{- if ($cdk.enabled | default false) -}}
{{- $roles = append $roles "cache" -}}
{{- end -}}
{{- join "," $roles -}}
{{- end }}

{{/*
Database role config lookup from Values.databases.<role>.
Returns JSON so callers can parse with fromJson.
*/}}
{{- define "kramerius.database.roleConfig" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $all := $root.Values.databases | default dict -}}
{{- $cfg := index $all $role | default dict -}}
{{- toJson $cfg -}}
{{- end }}

{{/*
CNPG service host for a role, e.g. kramerius-db-rw.
*/}}
{{- define "kramerius.database.cnpgRwHost" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $cnpg := index $roleCfg "cnpg" | default dict -}}
{{- $cluster := index $cnpg "cluster" | default dict -}}
{{- printf "%s-rw" (default (printf "%s-db" $role) $cluster.name) -}}
{{- end }}

{{/*
PG service name rendered by this chart for a role.
*/}}
{{- define "kramerius.database.pgServiceName" -}}
{{- printf "%s-pg" .role -}}
{{- end }}

{{/*
Database host selected by per-role deployment mode.
Fails if mode=external and external.host is not set.
*/}}
{{- define "kramerius.database.jdbcHost" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $mode := include "kramerius.database.roleMode" (dict "root" $root "role" $role) | trim -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $pg := index $roleCfg "pg" | default dict -}}
{{- $ext := index $roleCfg "external" | default dict -}}
{{- if eq $mode "external" -}}
{{- $host := index $ext "host" | default "" | trim -}}
{{- if not $host -}}
  {{- fail (printf "databases.%s: mode=external requires external.host to be set" $role) -}}
{{- end -}}
{{- $host -}}
{{- else if eq $mode "cnpg" -}}
{{ include "kramerius.database.cnpgRwHost" (dict "root" $root "role" $role) }}
{{- else -}}
{{- default (include "kramerius.database.pgServiceName" (dict "role" $role)) (index $pg "host") -}}
{{- end -}}
{{- end }}

{{/*
Database port selected by per-role deployment mode.
*/}}
{{- define "kramerius.database.jdbcPort" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $mode := include "kramerius.database.roleMode" (dict "root" $root "role" $role) | trim -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $pg := index $roleCfg "pg" | default dict -}}
{{- $ext := index $roleCfg "external" | default dict -}}
{{- if eq $mode "cnpg" -}}
5432
{{- else if eq $mode "external" -}}
{{- default 5432 (index $ext "port") -}}
{{- else -}}
{{- default 5432 (index $pg "port") -}}
{{- end -}}
{{- end }}

{{/*
Database JDBC URL for a role.
*/}}
{{- define "kramerius.database.jdbcUrl" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $jdbc := $roleCfg.jdbc | default dict -}}
{{- $base := printf "jdbc:postgresql://%s:%v/%s" (include "kramerius.database.jdbcHost" (dict "root" $root "role" $role)) (include "kramerius.database.jdbcPort" (dict "root" $root "role" $role)) (default $role $jdbc.database) -}}
{{- if $jdbc.params -}}
{{- printf "%s?%s" $base $jdbc.params -}}
{{- else -}}
{{- $base -}}
{{- end -}}
{{- end }}

{{/*
Database section for configuration.properties.
Contains primary JDBC settings (kramerius), users JDBC settings, and optional
CDK cache JDBC settings.
*/}}
{{- define "kramerius.configurationProperties.databaseSection" -}}
{{- $root := . -}}
{{- $props := dict }}

{{- $_ := set $props "jdbcUrl" (include "kramerius.database.jdbcUrl" (dict "root" $root "role" "kramerius")) }}
{{- $krameriusCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" "kramerius")) }}
{{- $krameriusJdbc := $krameriusCfg.jdbc | default dict }}
{{- $_ := set $props "jdbcUserName" (default "kramerius" $krameriusJdbc.username) }}
{{- if $krameriusJdbc.password }}
{{- $_ := set $props "jdbcUserPass" $krameriusJdbc.password }}
{{- end }}

{{- $_ := set $props "userJdbcUrl" (include "kramerius.database.jdbcUrl" (dict "root" $root "role" "users")) }}
{{- $usersCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" "users")) }}
{{- $usersJdbc := $usersCfg.jdbc | default dict }}
{{- $_ := set $props "userJdbcUserName" (default "users" $usersJdbc.username) }}
{{- if $usersJdbc.password }}
{{- $_ := set $props "userJdbcUserPass" $usersJdbc.password }}
{{- end }}

{{- $cdk := $root.Values.cdk | default dict }}
{{- if ($cdk.enabled | default false) }}
{{- $_ := set $props "cdk.cache.jdbcUrl" (include "kramerius.database.jdbcUrl" (dict "root" $root "role" "cache")) }}
{{- $cacheCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" "cache")) }}
{{- $cacheJdbc := $cacheCfg.jdbc | default dict }}
{{- $_ := set $props "cdk.cache.jdbcUserName" (default "cache" $cacheJdbc.username) }}
{{- if $cacheJdbc.password }}
{{- $_ := set $props "cdk.cache.jdbcUserPass" $cacheJdbc.password }}
{{- end }}
{{- end }}

{{- include "kramerius.configurationProperties.section" (dict "title" "Postgresql" "map" $props) }}
{{- end }}

{{/*
Per-role secret name.
Priority: existingSecret > cnpg cluster secret name > pg secret name.
In cnpg mode the name must match the CNPG bootstrap secret.
*/}}
{{- define "kramerius.database.secretName" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $existingSecret := index $roleCfg "existingSecret" | default "" | trim -}}
{{- if $existingSecret -}}
{{- $existingSecret -}}
{{- else -}}
{{- $mode := include "kramerius.database.roleMode" (dict "root" $root "role" $role) | trim -}}
{{- $cnpg := index $roleCfg "cnpg" | default dict -}}
{{- $cluster := index $cnpg "cluster" | default dict -}}
{{- if eq $mode "cnpg" -}}
{{- printf "%s-secret" (default (printf "%s-db" $role) (index $cluster "name")) -}}
{{- else -}}
{{- printf "%s-pg-secret" $role -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Render one CNPG Cluster manifest for role.
*/}}
{{- define "kramerius.database.cnpgCluster" }}
{{- $root := .root }}
{{- $role := .role }}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) }}
{{- $cnpg := index $roleCfg "cnpg" | default dict }}
{{- $cluster := index $cnpg "cluster" | default dict }}
{{- $storage := index $cnpg "storage" | default dict }}
{{- $jdbc := index $roleCfg "jdbc" | default dict }}
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ default (printf "%s-db" $role) $cluster.name }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "kramerius.labels" $root | nindent 4 }}
spec:
  instances: {{ default 1 $cluster.instances }}
  storage:
    size: {{ default "10Gi" $storage.size }}
    {{- if $storage.storageClass }}
    storageClass: {{ $storage.storageClass }}
    {{- end }}
  {{- if $cluster.maxConnections }}
  postgresql:
    parameters:
      max_connections: {{ $cluster.maxConnections | quote }}
  {{- end }}
  bootstrap:
    initdb:
      database: {{ default $role $jdbc.database }}
      owner: {{ default $role $jdbc.username }}
      secret:
        name: {{ include "kramerius.database.secretName" (dict "root" $root "role" $role) }}
{{- end }}

{{/*
Render one DB Secret manifest for role.
*/}}
{{- define "kramerius.database.secret" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $jdbc := index $roleCfg "jdbc" | default dict -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "kramerius.database.secretName" (dict "root" $root "role" $role) }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "kramerius.labels" $root | nindent 4 }}
type: kubernetes.io/basic-auth
stringData:
  username: {{ default $role $jdbc.username | quote }}
  password: {{ default "changeme" $jdbc.password | quote }}
{{- end }}

{{/*
Render one PVC for pg mode role.
*/}}
{{- define "kramerius.database.pgPvc" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $pg := index $roleCfg "pg" | default dict -}}
{{- $storage := index $pg "storage" | default dict -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ printf "%s-pg-data" $role }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "kramerius.labels" $root | nindent 4 }}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ default $root.Values.defaultStorageClass $storage.storageClass | quote }}
  resources:
    requests:
      storage: {{ default "10Gi" $storage.size }}
{{- end }}

{{/*
Render one Service for pg mode role.
*/}}
{{- define "kramerius.database.pgService" -}}
{{- $root := .root -}}
{{- $role := .role -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "kramerius.database.pgServiceName" (dict "role" $role) }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "kramerius.labels" $root | nindent 4 }}
    app.kubernetes.io/name: {{ printf "%s-pg" $role }}
    app.kubernetes.io/component: database
spec:
  selector:
    app.kubernetes.io/name: {{ printf "%s-pg" $role }}
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
{{- end }}

{{/*
Render one Deployment for pg mode role.
*/}}
{{- define "kramerius.database.pgDeployment" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $db := $root.Values.databases | default dict -}}
{{- $roleCfg := fromJson (include "kramerius.database.roleConfig" (dict "root" $root "role" $role)) -}}
{{- $jdbc := index $roleCfg "jdbc" | default dict -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ printf "%s-pg" $role }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "kramerius.labels" $root | nindent 4 }}
    app.kubernetes.io/name: {{ printf "%s-pg" $role }}
    app.kubernetes.io/component: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ printf "%s-pg" $role }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ printf "%s-pg" $role }}
        app.kubernetes.io/component: database
    spec:
      {{- if $db.pg.pullSecret }}
      imagePullSecrets:
        - name: {{ $db.pg.pullSecret | quote }}
      {{- end }}
      containers:
        - name: postgres
          image: {{ printf "%s:%s" (default "postgres" $db.pg.image) (default "16" $db.pg.version) }}
          imagePullPolicy: Always
          ports:
            - containerPort: 5432
              name: postgres
          env:
            - name: POSTGRES_DB
              value: {{ default $role $jdbc.database | quote }}
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: {{ include "kramerius.database.secretName" (dict "root" $root "role" $role) }}
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "kramerius.database.secretName" (dict "root" $root "role" $role) }}
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ printf "%s-pg-data" $role }}
{{- end }}
