#!/bin/sh
# Repair a partial schema without replacing existing tables or sequence rows.
set -eu
: "${MYSQL_HOST:?MYSQL_HOST is required}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is required}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
case "$MYSQL_DATABASE" in
  *[!a-zA-Z0-9_]*|'') echo 'Invalid MySQL database identifier' >&2; exit 1 ;;
esac
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
mysql_cmd() {
  if [ "${PINPOINT_VERSION:-3.1.1}" = "4.0.1" ]; then
    mysql -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" -u root -s -N --init-command='SET SESSION sql_generate_invisible_primary_key=ON' "$@"
  else
    mysql -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" -u root -s -N "$@"
  fi
}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT HUP INT TERM
schemas="create-tables.sql create-batch-tables.sql create-service.sql create-feature-flag.sql"
case "${PINPOINT_METRIC_ENABLED:-false}" in
  true) schemas="$schemas create-otlp-metric.sql" ;;
  false) ;;
  *) echo "PINPOINT_METRIC_ENABLED must be true or false" >&2; exit 1 ;;
esac
if [ "${PINPOINT_VERSION:-3.1.1}" = "4.0.1" ]; then
  version=$(mysql -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" -u root -s -N -e 'SELECT VERSION();')
  case "$version" in *MariaDB*) echo 'Pinpoint requires MySQL; MariaDB is not supported' >&2; exit 1 ;; esac
  supported=$(printf '%s' "$version" | awk -F. '{print ($1>8 || ($1==8 && $2>=4)) ? "yes" : "no"}')
  [ "$supported" = yes ] || { echo 'Pinpoint 4.0.1 requires MySQL 8.4 or newer' >&2; exit 1; }
  schemas="$schemas create-alarm.sql"
fi
for schema in $schemas; do
  sed -e 's/^CREATE TABLE /CREATE TABLE IF NOT EXISTS /' -e '/^ALTER TABLE .* ADD /d' "/shared/$schema" > "$workdir/$schema"
  mysql_cmd "$MYSQL_DATABASE" < "$workdir/$schema"
done
# Named indexes are separate ALTER statements in the upstream schema.
# Reapply only missing indexes; rerunning ADD INDEX blindly is not idempotent.
sed -n '/^ALTER TABLE .* ADD /p' /shared/create-tables.sql > "$workdir/indexes"
while read -r statement; do
  table=$(printf '%s\n' "$statement" | awk '{print $3}')
  index=$(printf '%s\n' "$statement" | awk '{if ($5=="UNIQUE") print $7; else print $6}')
  found=$(mysql_cmd -e "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='$MYSQL_DATABASE' AND table_name='$table' AND index_name='$index';")
  if [ "$found" = 0 ]; then
    mysql_cmd "$MYSQL_DATABASE" -e "$statement"
  fi
done < "$workdir/indexes"
# Use exact names from the shipped DDL rather than a count of unrelated tables.
for schema in $schemas; do
  awk 'toupper($1)=="CREATE" && toupper($2)=="TABLE" {name=$3; gsub(/`/,"",name); print name}' \
    "/shared/$schema"
done > "$workdir/expected-tables"
while read -r table; do
  found=$(mysql_cmd -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE' AND table_name='$table';")
  if [ "$found" != 1 ]; then
    echo "Missing required MySQL table: $table" >&2
    exit 1
  fi
done < "$workdir/expected-tables"
# An existing table with missing columns must not make the hook look successful.
# Only validate here; incompatible existing schemas require a reviewed migration.
for schema in $schemas; do
  awk '
    toupper($1)=="CREATE" && toupper($2)=="TABLE" {table=$3; gsub(/`/,"",table)}
    /^[[:space:]]+/ {
      column=$1; kind=$2
      if (column ~ /^`/) {
        split($0, parts, "`"); column=parts[2]; kind=parts[3]; sub(/^[[:space:]]+/, "", kind)
      }
      if (toupper(kind) ~ /^(INT|BIGINT|TINYINT|VARCHAR|CHAR|DATETIME|TEXT|MEDIUMTEXT|JSON|ENUM)(\(|[[:space:]]|$)/) print table, column
    }' "/shared/$schema"
done > "$workdir/expected-columns"
while read -r table column; do
  found=$(mysql_cmd -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$MYSQL_DATABASE' AND table_name='$table' AND column_name='$column';")
  if [ "$found" != 1 ]; then
    echo "Missing required MySQL column: $table.$column" >&2
    exit 1
  fi
done < "$workdir/expected-columns"
columns=$(mysql_cmd -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$MYSQL_DATABASE' AND table_name='webhook' AND column_name IN ('application_id','service_name') AND character_maximum_length < 127;")
if [ "$columns" -gt 0 ]; then
  mysql_cmd "$MYSQL_DATABASE" -e 'ALTER TABLE webhook MODIFY COLUMN application_id VARCHAR(127) NULL, MODIFY COLUMN service_name VARCHAR(127) NULL;'
fi
echo 'Required MySQL tables verified; existing data and batch sequence rows preserved.'
