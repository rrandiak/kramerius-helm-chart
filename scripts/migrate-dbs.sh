#!/bin/bash
# Merge tables from source into target DB via kubectl exec.
# Existing target data is preserved; duplicates matched on natural keys are skipped.
# Both source and target are accessed via kubectl exec into their respective pods.
#
# Usage:
#   ./migrate.sh rights  <src_ns> <src_pod> <src_db> <src_user> <src_pass> \
#                        <dst_ns> <dst_pod> <dst_db> <dst_user> <dst_pass>
#   ./migrate.sh folders <src_ns> <src_pod> <src_db> <src_user> <src_pass> \
#                        <dst_ns> <dst_pod> <dst_db> <dst_user> <dst_pass>

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

usage() {
  echo "Usage: $0 {rights|folders} <src_ns> <src_pod> <src_db> <src_user> <src_pass> \\"
  echo "                           <dst_ns> <dst_pod> <dst_db> <dst_user> <dst_pass>"
  echo "Example: $0 rights k7-source kramerius-db-0 kramerius postgres srcpass \\"
  echo "                   k7-target kramerius-db-0 kramerius postgres dstpass"
  exit 1
}

if [ $# -lt 11 ]; then usage; fi

MODE="$1"
SRC_NS="$2"
SRC_POD="$3"
SRC_DB="$4"
SRC_USER="$5"
SRC_PASS="$6"
DST_NS="$7"
DST_POD="$8"
DST_DB="$9"
DST_USER="${10}"
DST_PASS="${11}"

case "$MODE" in
  rights|folders) ;;
  *) echo "Unknown mode: $MODE"; usage ;;
esac

# --- helpers ---

src_psql() {
  sleep 1
  kubectl exec -i -n "$SRC_NS" "$SRC_POD" -- env PGPASSWORD="$SRC_PASS" psql -U "$SRC_USER" -d "$SRC_DB" "$@"
}

dst_psql() {
  sleep 1
  kubectl exec -i -n "$DST_NS" "$DST_POD" -- env PGPASSWORD="$DST_PASS" psql -h 127.0.0.1 -U "$DST_USER" -d "$DST_DB" "$@"
}

test_connections() {
  echo "=== Testing source connection..."
  src_psql -c "SELECT 1;" > /dev/null
  echo "=== Testing target connection..."
  dst_psql -c "SELECT 1;" > /dev/null
}

show_counts() {
  local target=$1 label=$2
  shift 2
  local tables=("$@")
  echo ""
  echo "=== $label:"
  for entry in "${tables[@]}"; do
    local table="$entry"
    local count
    if [ "$target" = "DST" ]; then
      count=$(dst_psql -t -A -c "SELECT COUNT(*) FROM $table;")
    else
      count=$(src_psql -t -A -c "SELECT COUNT(*) FROM $table;")
    fi
    echo "  $table: $count"
  done
}

confirm_proceed() {
  local msg="${1:-Proceed?}"
  echo ""
  read -p "$msg [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
  fi
}

export_table() {
  local table=$1
  local outfile="$TMPDIR/${table}.csv"
  src_psql -c "\\copy $table TO STDOUT WITH (FORMAT csv, HEADER)" > "$outfile"
  local count
  count=$(tail -n +2 "$outfile" | wc -l)
  echo "  $table: $count rows exported"
}

reset_seq() {
  local table=$1 col=$2 seq=$3
  local max
  max=$(dst_psql -t -A -c "SELECT COALESCE(MAX($col), 0) + 1 FROM $table;")
  dst_psql -c "SELECT setval('$seq', $max, false);" > /dev/null
  echo "  $seq -> next value: $max"
}

# --- rights migration ---
# Matches on natural keys, remaps all generated IDs (including FK references).
#
# Natural keys:
#   criterium_param_entity  -> (short_desc, vals)
#   labels_entity           -> (label_name, label_group)
#   rights_criterium_entity -> (type, qname, resolved citeriumparam, resolved label)
#   right_entity            -> (uuid, action, resolved rights_crit, resolved user loginname, resolved group gname, role)

migrate_rights() {
  local tables=(
    criterium_param_entity
    labels_entity
    rights_criterium_entity
    right_entity
  )

  test_connections

  show_counts "SRC" "Source row counts" "${tables[@]}"
  show_counts "DST" "Target row counts (before migration)" "${tables[@]}"
  confirm_proceed "Proceed? Existing target rights data WILL BE REPLACED."

  echo ""
  echo "=== Exporting source tables..."
  for t in "${tables[@]}"; do
    export_table "$t"
  done
  # Also export user_entity and group_entity for user_id/group_id remapping
  export_table user_entity
  export_table group_entity

  echo ""
  echo "=== Replacing target rights tables with source data..."

  # Build the piped input: temp table creation, \copy loads, then replace SQL
  {
    cat <<'SQL_HEADER'
SET client_min_messages TO warning;
BEGIN;

CREATE TEMP TABLE _src_criterium_param_entity (LIKE criterium_param_entity INCLUDING DEFAULTS) ON COMMIT DROP;
CREATE TEMP TABLE _src_labels_entity          (LIKE labels_entity INCLUDING DEFAULTS)          ON COMMIT DROP;
CREATE TEMP TABLE _src_rights_criterium_entity(LIKE rights_criterium_entity INCLUDING DEFAULTS) ON COMMIT DROP;
CREATE TEMP TABLE _src_right_entity           (LIKE right_entity INCLUDING DEFAULTS)           ON COMMIT DROP;
CREATE TEMP TABLE _src_user_entity            (LIKE user_entity INCLUDING DEFAULTS)            ON COMMIT DROP;
CREATE TEMP TABLE _src_group_entity           (LIKE group_entity INCLUDING DEFAULTS)           ON COMMIT DROP;
SQL_HEADER

    # Load each source CSV via \copy FROM STDIN
    for t in criterium_param_entity labels_entity rights_criterium_entity right_entity user_entity group_entity; do
      local cols
      cols=$(head -1 "$TMPDIR/${t}.csv")
      echo "\\copy _src_${t}(${cols}) FROM STDIN WITH (FORMAT csv, HEADER)"
      cat "$TMPDIR/${t}.csv"
      echo "\\."
    done

    cat <<'SQL_REPLACE'

-- Clear target tables in reverse FK order
DELETE FROM right_entity;
DELETE FROM rights_criterium_entity;
DELETE FROM labels_entity;
DELETE FROM criterium_param_entity;

-- Re-insert from source, preserving original IDs
-- Rows with null PKs are corrupt source data and are skipped.
INSERT INTO criterium_param_entity
SELECT * FROM _src_criterium_param_entity
WHERE crit_param_id IS NOT NULL;

INSERT INTO labels_entity
SELECT * FROM _src_labels_entity
WHERE label_id IS NOT NULL;

INSERT INTO rights_criterium_entity
SELECT * FROM _src_rights_criterium_entity
WHERE crit_id IS NOT NULL;

-- right_entity: preserve source IDs and rights_crit (FK already correct since we used
-- source IDs above), but remap user_id/group_id to target IDs via loginname/gname.
INSERT INTO right_entity (right_id, update_timestamp, uuid, action, rights_crit,
                          user_id, group_id, role, fixed_priority)
SELECT s.right_id, s.update_timestamp, s.uuid, s.action, s.rights_crit,
       tu.user_id,
       tg.group_id,
       s.role, s.fixed_priority
FROM _src_right_entity s
LEFT JOIN _src_user_entity su  ON su.user_id  = s.user_id
LEFT JOIN user_entity tu       ON tu.loginname = su.loginname
LEFT JOIN _src_group_entity sg ON sg.group_id  = s.group_id
LEFT JOIN group_entity tg      ON tg.gname     = sg.gname
WHERE s.right_id IS NOT NULL;

COMMIT;
SQL_REPLACE
  } | dst_psql

  echo ""
  echo "=== Resetting sequences..."
  reset_seq criterium_param_entity crit_param_id crit_param_id_sequence
  reset_seq labels_entity label_id label_id_sequence
  reset_seq rights_criterium_entity crit_id crit_id_sequence
  reset_seq right_entity right_id right_id_sequence

  show_counts "DST" "Target row counts (after migration)" "${tables[@]}"
  echo ""
  echo "=== Rights migration complete."
}

# --- folders migration ---
# Folders use UUIDs (not generated ints), so simple PK-based merge works.

merge_folder_tables() {
  local tables=("$@")
  echo ""
  echo "=== Merging tables..."
  for entry in "${tables[@]}"; do
    local table="${entry%%:*}"
    local pk="${entry#*:}"
    local tmpfile="$TMPDIR/${table}.csv"

    echo "  Exporting $table from source..."
    src_psql -c "\\copy $table TO STDOUT WITH (FORMAT csv, HEADER)" > "$tmpfile"

    local src_count
    src_count=$(tail -n +2 "$tmpfile" | wc -l)
    if [ "$src_count" -eq 0 ]; then
      echo "    -> 0 rows in source, skipping"
      continue
    fi

    echo "  Importing $table into target (ON CONFLICT DO NOTHING)..."
    local columns
    columns=$(head -1 "$tmpfile")

    {
      echo "BEGIN;"
      echo "CREATE TEMP TABLE _tmp_${table} (LIKE ${table} INCLUDING DEFAULTS) ON COMMIT DROP;"
      echo "\\copy _tmp_${table}(${columns}) FROM STDIN WITH (FORMAT csv, HEADER)"
      cat "$tmpfile"
      echo "\\."
      echo "INSERT INTO ${table}(${columns})"
      echo "SELECT ${columns} FROM _tmp_${table}"
      echo "ON CONFLICT (${pk}) DO NOTHING;"
      echo "COMMIT;"
    } | dst_psql

    local new_count
    new_count=$(dst_psql -t -A -c "SELECT COUNT(*) FROM $table;")
    echo "    -> source: $src_count rows, target now: $new_count rows"
  done
}

migrate_folders() {
  local tables_display=(
    folder
    folder_user
    folder_item
  )
  local tables_merge=(
    "folder:uuid"
    "folder_user:folder_uuid,user_id"
    "folder_item:folder_uuid,item_id"
  )

  test_connections
  show_counts "SRC" "Source row counts" "${tables_display[@]}"
  show_counts "DST" "Target row counts (before migration)" "${tables_display[@]}"
  confirm_proceed "Proceed? Existing target folders will NOT be deleted; new ones will be added."
  merge_folder_tables "${tables_merge[@]}"

  show_counts "DST" "Target row counts (after migration)" "${tables_display[@]}"
  echo ""
  echo "=== Folders migration complete."
}

# --- run ---

"migrate_${MODE}"
