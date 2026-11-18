#!/usr/bin/env bash
# Compare les bases de pg-main (source) et de pg-restore-test (restauré) :
# présence des bases et nombre de lignes par table.
#   exit 0 : identique
#   exit 1 : base manquante, ou table plus grande dans la restauration (anormal)
#   exit 2 : restauration en retard sur la source (écritures postérieures au
#            dernier WAL archivé) : relancer après une sauvegarde à la demande
set -euo pipefail

NS="${NS:-database}"
SRC="${SRC:-$(kubectl -n "$NS" get cluster pg-main -o jsonpath='{.status.currentPrimary}')}"
DST="${DST:-pg-restore-test-1}"

q() { # pod base requête
  kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -d "$2" -tAF'|' -c "$3"
}

COUNTS="select table_schema||'.'||table_name,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint
  from information_schema.tables
  where table_type='BASE TABLE' and table_schema not in ('pg_catalog','information_schema')
  order by 1"

rc=0
for db in $(q "$SRC" postgres "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1"); do
  if ! q "$DST" postgres "select 1 from pg_database where datname='$db'" | grep -q 1; then
    echo "KO   $db : base absente de la restauration"; rc=1; continue
  fi
  if ! diff -q <(q "$SRC" "$db" "$COUNTS" | cut -d'|' -f1) <(q "$DST" "$db" "$COUNTS" | cut -d'|' -f1) >/dev/null; then
    echo "KO   $db : listes de tables différentes"; rc=1; continue
  fi
  paste -d'|' <(q "$SRC" "$db" "$COUNTS") <(q "$DST" "$db" "$COUNTS") \
  | awk -F'|' -v db="$db" '
      { total++; if ($4 > $2) { more++; print "KO   " db "." $1 " : restauré " $4 " > source " $2 }
        else if ($4 < $2) { lag++; print "LAG  " db "." $1 " : restauré " $4 " < source " $2 } }
      END { printf "%s %s : %d tables, %d en retard, %d anormales\n", (more ? "KO  " : (lag ? "LAG " : "OK  ")), db, total, lag, more;
            exit (more ? 1 : (lag ? 2 : 0)) }' || r=$?
  case "${r:-0}" in 1) rc=1 ;; 2) [ "$rc" -eq 0 ] && rc=2 ;; esac
  r=0
done
exit "$rc"
