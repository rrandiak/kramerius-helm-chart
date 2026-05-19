# How to migrate Kramerius databases

This chart expects three PostgreSQL databases (names come from your `values.yaml` / CNPG secrets):

| Database   | Typical name  | Contents (high level) |
|------------|---------------|------------------------|
| **kramerius** | `kramerius` | Application DB including **Rights Editor** in five **`public`** tables (section 1). On a new deploy, non-Rights data is mostly cache or filled by the stack; only Rights are migrated with **`pg_dump`** in this guide. |
| **users**   | `users`     | User-scoped data with **text/UUID keys** — this is where **folders** live (`folder`, `folder_item`, `folder_user`). |
| **process** | `process`   | Process Manager: four `pcp_*` tables with **text** primary keys (`pcp_node`, `pcp_plugin`, `pcp_profile`, `pcp_process`). |

**Two deployments:** **old** = current **production** (source DBs for dumps / replication). **new** = replacement stack (target DBs). An operator migrates database state onto **new**, then switches **production URLs**.

---

## 1. `kramerius` database — Rights Editor

Use **`SRC_*`** connection variables for **old production** and **`DST_*`** for **new** stack PostgreSQL below.

**Rights Editor** uses these **`public`** tables (and their FK graph):

| Table | Role |
|-------|------|
| `criterium_param_entity` | Criteria parameters; PK `crit_param_id` |
| `labels_entity` | Labels; PK `label_id` |
| `rights_criterium_entity` | Criteria; PK `crit_id`; FKs to `criterium_param_entity`, `labels_entity` |
| `group_entity` | Groups; PK `group_id` |
| `right_entity` | Grants; PK `right_id`; FKs to `group_entity`, `rights_criterium_entity`; nullable `user_id` → `user_entity` when present |

After **`pg_dump --data-only`**, **`setval`** the sequences that back those PK columns inside the same transaction as the load (section 1.4). Example names in many installs: `crit_param_id_sequence`, `label_id_sequence`, `crit_id_sequence`, `group_id_sequence`, `right_id_sequence` — confirm in **`pg_sequences`** / **`\d`** on **new** and adjust the script if yours differ.

### 1.1 Operator note

Take the Rights **`pg_dump`** from **old production** when you are ready to apply **new** (avoid changing these five tables on old prod during that snapshot if you want a clean copy). On **new**, run **one transaction**: delete existing Rights rows, apply **`rights.sql`**, **`setval`**. Validate, then point **production** at **new**.

### 1.2 New stack `kramerius` (Helm + application)

On **new** stack:

1. **Helm** (this chart) provisions the PostgreSQL instance and the **`kramerius`** database role — not a manual `CREATE DATABASE` step.
2. The **application** creates and migrates schema (tables, sequences, constraints) when it runs against that database as it normally does on install. It may **already insert rows** into some of the five Rights tables — the migration transaction in **section 1.4** **deletes** all rows in those tables on **new**, then loads the dump, so you end with **old production**’s Rights state only.

Deploy **new** with Helm and run the **application** so the five Rights tables exist on **`DST`** before you run **section 1.4**.

### 1.3 Dump Rights data from old production

```bash
pg_dump \
  --host="${SRC_PGHOST}" \
  --port="${SRC_PGPORT:-5432}" \
  --username="${SRC_PGUSER}" \
  --dbname=kramerius \
  --data-only \
  --column-inserts \
  --no-owner \
  --no-privileges \
  --table=public.criterium_param_entity \
  --table=public.labels_entity \
  --table=public.rights_criterium_entity \
  --table=public.group_entity \
  --table=public.right_entity \
  --file=rights.sql
```

### 1.4 One transaction on **new** stack: delete Rights rows, load dump, **`setval`**

Run on **`DST`** (role that may **`SET session_replication_role`** — typically superuser — because **`INSERT`** into **`right_entity`** can reference **`user_id`** while **`user_entity`** is still empty or unrelated on **new**).

Use **one** transaction so either the whole migration applies or nothing does. Run **`psql` from the directory that contains **`rights.sql`**, or change **`\i rights.sql`** to an absolute path.

```bash
psql \
  --host="${DST_PGHOST}" \
  --port="${DST_PGPORT:-5432}" \
  --username="${DST_PGUSER}" \
  --dbname=kramerius \
  -v ON_ERROR_STOP=1 <<'EOF'
BEGIN;
SET LOCAL session_replication_role = replica;

DELETE FROM public.right_entity;
DELETE FROM public.rights_criterium_entity;
DELETE FROM public.labels_entity;
DELETE FROM public.criterium_param_entity;
DELETE FROM public.group_entity;

\i rights.sql

SELECT setval('public.crit_param_id_sequence', COALESCE((SELECT MAX(crit_param_id) FROM public.criterium_param_entity), 1));
SELECT setval('public.label_id_sequence', COALESCE((SELECT MAX(label_id) FROM public.labels_entity), 1));
SELECT setval('public.crit_id_sequence', COALESCE((SELECT MAX(crit_id) FROM public.rights_criterium_entity), 1));
SELECT setval('public.group_id_sequence', COALESCE((SELECT MAX(group_id) FROM public.group_entity), 1));
SELECT setval('public.right_id_sequence', COALESCE((SELECT MAX(right_id) FROM public.right_entity), 1));

COMMIT;
EOF
```

Data-only dumps do not advance sequences; the **`setval`** calls align them with the loaded **`MAX(...)`** values. Smoke-test **new** before you switch production URLs.

---

## 2. `users` database

Folders and related data use **stable text/UUID keys**. **Logical replication** directly into the target `users` database is the usual approach: one **publication** on the source and one **subscription** on the target, each with an **explicit `FOR TABLE` list** (no `FOR ALL TABLES`).

### 2.1 Prepare target

Create an empty `users` database (or schema) on the target and apply the same structure as the source (`pg_dump -s` or equivalent). Match PostgreSQL major version when replication compatibility requires it.

### 2.2 Prepare replication role on source

Grant the **`REPLICATION`** privilege to the role used by subscriptions:

```sql
-- On SOURCE
ALTER ROLE replicator WITH REPLICATION;
```

### 2.3 Publication on source (`users`)

```sql
-- On SOURCE users DB
CREATE PUBLICATION users_pub FOR TABLE
  folder,
  folder_item,
  folder_user;
```

Add any other tables your deployment keeps in this database using the same **`FOR TABLE`** pattern.

### 2.4 Subscription on target (`users`)

```sql
-- On TARGET users DB
CREATE SUBSCRIPTION users_sub
CONNECTION 'host={db-name}-rw.{namespace}.svc.cluster.local port=5432 dbname=users user=replicator password=...'
PUBLICATION users_pub
WITH (copy_data = true, create_slot = true);
```

Replace **`{db-name}`** and **`{namespace}`** with the CNPG cluster name and Kubernetes namespace of the **source**. Use a dedicated **`REPLICATION`** / **`LOGIN`** user on the source. Monitor **`pg_stat_subscription`**. Ensure network reachability and **TLS** where appropriate.

---

## 3. `process` database

Process Manager data lives in four tables with **text** primary keys and foreign-key relationships:

| Table | PK | FKs |
|-------|-----|-----|
| `pcp_node` | `node_id` | — |
| `pcp_plugin` | `plugin_id` | — |
| `pcp_profile` | `profile_id` | `plugin_id` → `pcp_plugin` (CASCADE) |
| `pcp_process` | `process_id` | `profile_id` → `pcp_profile` (CASCADE), `worker_id` → `pcp_node` (CASCADE) |

**Logical replication** directly into the target `process` database is the usual approach, with **explicit `FOR TABLE` lists** only.

### 3.1 Prepare target

Create the target `process` database. The **application** creates the schema (tables, constraints) when it first connects — same as the `kramerius` database. Alternatively, replicate the schema from the source with **`pg_dump -s`**. Match PostgreSQL major version when needed.

### 3.2 Publication on source (`process`)

```sql
-- On SOURCE process DB
CREATE PUBLICATION process_pub FOR TABLE
  pcp_node,
  pcp_plugin,
  pcp_profile,
  pcp_process;
```

### 3.3 Subscription on target (`process`)

```sql
-- On TARGET process DB
CREATE SUBSCRIPTION process_sub
CONNECTION 'host={db-name}-rw.{namespace}.svc.cluster.local port=5432 dbname=process user=replicator password=...'
PUBLICATION process_pub
WITH (copy_data = true, create_slot = true);
```

Replace **`{db-name}`** and **`{namespace}`** with the CNPG cluster name and Kubernetes namespace of the **source**. Use a dedicated **`REPLICATION`** / **`LOGIN`** user on the source. Monitor **`pg_stat_subscription`**. Ensure network reachability and **TLS** where appropriate.

---

## 4. Monitoring and cleanup

### 4.1 Check replication state

```sql
-- On TARGET: list active subscriptions
SELECT * FROM pg_subscription;

-- On SOURCE: list active publications
SELECT * FROM pg_publication;
```

### 4.2 Drop replication after cutover

Once the migration is complete and production URLs point to **new**, remove the replication objects:

```sql
-- On TARGET: drop subscriptions
DROP SUBSCRIPTION users_sub;
DROP SUBSCRIPTION process_sub;

-- On SOURCE: drop publications
DROP PUBLICATION users_pub;
DROP PUBLICATION process_pub;
```
