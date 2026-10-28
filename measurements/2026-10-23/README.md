# Raw data of the 2026-10-23 measurements

[REPORT.md](../REPORT.md), section "Review fixes and the final measurement", is computed from these files.

| file | what | made by |
|---|---|---|
| `final/C{10,20,30}.ship.after.jsonl.gz`, `final/C10.lock.after.jsonl.gz` | the after side on frozen bin/ `df4badf` (`final/bin-final.sha`), same seeds and settings as `2026-10-22/fixes/` | `final/resume.sh` after the first start; started by hand with the arguments in `resume.sh` |
| `final/C30.ship.before.part2.jsonl.gz` | the before side (bin/ at `08e7423`) of N = 30, seeds 7250-7299: with `2026-10-22/fixes/C30.ship.before`, 100 runs | as above |
| `final/*.log` | the stand's output; the line "paused here" marks the pause of 2026-10-23, whose in-flight runs were dropped | |
| `final/superseded/` | runs on an earlier frozen bin/ (before R10b), kept, not used | |
| `final2/` | after the second review: C10 ship and lock on frozen bin/ `e63ffd8` (`bin-final.sha`), `kill-stress.txt` (300 reps) | the same arguments as `final/resume.sh`, `BIN=<frozen copy>`; `REPS=300 lab/kill-stress.sh` |
| `stress/probe1-4.txt` | `lab/kill-stress.sh`-style probes, 300 reps each, on the bin/ after each fix (see REPORT) | `/tmp` copy of the stand, then `lab/kill-stress.sh` |

Recompute:

```sh
python3 lab/compare.py measurements/2026-10-22/fixes/C20.ship.before.jsonl.gz measurements/2026-10-23/final/C20.ship.after.jsonl.gz --paired
REPS=300 lab/kill-stress.sh | tail -1
```
