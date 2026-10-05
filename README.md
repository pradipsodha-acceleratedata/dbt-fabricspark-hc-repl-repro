# dbt-fabricspark: HC REPLs are not reused across runs

Repro for a dbt-fabricspark bug: with `high_concurrency: true` and `reuse_session: true`, each dbt command acquires new HC REPLs and never reuses the ones the previous command kept alive. The kept REPLs fill the Livy session's `spark.highConcurrency.max` slots (default 5), and the next command lands on a new Livy session with a cold start.

## What you need

- A Fabric workspace with a Lakehouse
- `az login` as a user with access to it
- Python 3.10+

## Run it

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export FABRIC_WORKSPACE_ID=<workspace id>
export FABRIC_WORKSPACE_NAME=<workspace name>
export FABRIC_LAKEHOUSE_ID=<lakehouse id>
export FABRIC_LAKEHOUSE_NAME=<lakehouse name>
export FABRIC_SCHEMA=hc_repro        # optional, default hc_repro

./repro.sh 6
```

Start with no Livy session alive for the lakehouse, otherwise the first runs pack onto it and the numbers shift.

`repro.sh` runs `dbt build` 6 times, one after another (`threads: 1`, so one REPL per run). For each run it prints the REPL (`hc_id`) and the Livy session it used, taken from the `HC session ready:` line in `logs/dbt.log`, and the Livy sessions alive in the workspace. At the end it asks Fabric for the state of every REPL the runs created.

Set `DBT_THREADS=5` to see it spill almost every run.

## What you should see

Runs 1-5 each create a new REPL on the same Livy session. Run 6 lands on a second Livy session while the first is still alive. Every REPL from the earlier runs is still `Idle`.

From a run with dbt-fabricspark 1.13.6, `threads: 1`:

| run | REPL (hc_id) | Livy session | time |
|---|---|---|---|
| 1 | 27183b11 | 83d36957 (cold start) | 173 s |
| 2 | 85d59fbf | 83d36957 | 96 s |
| 3 | 05e1a2ed | 83d36957 | 113 s |
| 4 | f4fd3b27 | 83d36957 | 89 s |
| 5 | fcd10064 | 83d36957 | 98 s |
| 6 | 5288fda6 | a471b4ff (cold start) | 166 s |

REPLs of a finished `dbt build` (`threads: 5`), 30 s after the process exited:

```
0d864168 Idle  on Livy session 74c26fef
a4fa6188 Idle  on Livy session 74c26fef
8e98a1e4 Idle  on Livy session 74c26fef
c6dc6488 Idle  on Livy session 74c26fef
37ac724b Idle  on Livy session 74c26fef
```

## Try the fix

```bash
pip install git+https://github.com/pradipsodha-acceleratedata/dbt-fabricspark.git@fix/hc-reclaim-repls-across-runs
rm -f livy-session-id.txt.hc.json
./repro.sh 6
```

With the fix, run 1 creates one REPL and runs 2-6 reuse it (`dbt.log` shows `Reclaimed saved HC REPL`), all on one Livy session.

## Files

| File | |
|---|---|
| `dbt_project.yml`, `models/` | 6 trivial table models |
| `profiles.yml` | `high_concurrency: true`, `reuse_session: true`, values from env vars |
| `requirements.txt` | dbt-core 1.12.5, dbt-fabricspark 1.13.6 |
| `repro.sh` | runs the builds and prints REPL / Livy session per run |
