#!/usr/bin/env bash
# Runs `dbt build` N times, one after another, and prints which HC REPL and
# which physical Livy session each run used. Then shows the state of every
# REPL the runs created, as reported by Fabric.
#
# Usage: ./repro.sh [runs]    (default 6)
# Needs: az login, FABRIC_* env vars (see README), dbt on PATH.
set -euo pipefail
cd "$(dirname "$0")"

RUNS="${1:-6}"
: "${FABRIC_WORKSPACE_ID:?set FABRIC_WORKSPACE_ID}"
: "${FABRIC_LAKEHOUSE_ID:?set FABRIC_LAKEHOUSE_ID}"
export DBT_PROFILES_DIR="$PWD"

API=https://api.fabric.microsoft.com/v1
HC="$API/workspaces/$FABRIC_WORKSPACE_ID/lakehouses/$FABRIC_LAKEHOUSE_ID/livyApi/versions/2023-12-01/highConcurrencySessions"

token() { az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv; }

alive_sessions() {
  curl -fsS -H "Authorization: Bearer $(token)" "$API/workspaces/$FABRIC_WORKSPACE_ID/spark/livySessions" |
    python3 -c "import json,sys; v=[s['livyId'][:8] for s in json.load(sys.stdin)['value'] if s['state'] in ('InProgress','NotStarted','Queued')]; print(' '.join(v) or 'none')"
}

echo "Livy sessions alive before start: $(alive_sessions)"
echo "threads=${DBT_THREADS:-1}, runs=$RUNS"
echo

ALL_HC=()
for i in $(seq 1 "$RUNS"); do
  rm -rf logs
  start=$(date +%s)
  if dbt build --no-use-colors > "run-$i.log" 2>&1; then rc=ok; else rc="FAILED (see run-$i.log)"; fi
  took=$(( $(date +%s) - start ))
  used=$(sed -E 's/\x1b\[[0-9;]*m//g' logs/dbt.log |
    grep -oE 'HC session ready: hc_id=[0-9a-f-]+ sessionId=[0-9a-f-]+' |
    sed -E 's/.*hc_id=([0-9a-f]{8})[0-9a-f-]* sessionId=([0-9a-f]{8}).*/REPL \1 on Livy session \2/' | sort -u)
  for id in $(sed -E 's/\x1b\[[0-9;]*m//g' logs/dbt.log | grep -oE 'HC session ready: hc_id=[0-9a-f-]+' | sed 's/.*hc_id=//' | sort -u); do
    ALL_HC+=("$id")
  done
  echo "run $i: $rc, ${took}s"
  echo "$used" | sed 's/^/  /'
  echo "  Livy sessions alive: $(alive_sessions)"
done

echo
echo "State of every REPL the runs created (after all runs exited):"
for id in "${ALL_HC[@]}"; do
  curl -fsS -H "Authorization: Bearer $(token)" "$HC/$id" |
    python3 -c "import json,sys; t=json.load(sys.stdin); print('  REPL', '$id'[:8], t.get('state'), 'on Livy session', (t.get('sessionId') or '')[:8])"
done
