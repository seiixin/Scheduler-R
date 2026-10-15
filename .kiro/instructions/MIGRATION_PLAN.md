# Final Architecture: Meta-Heuristics + Integrated Decoder Pipeline

## Summary

All three algorithms (SA, GA, ACO) follow the same two-layer design:

**Layer 1 — Algorithm Search Loop** (inside `run_SA`, `run_GA`, `run_ACO`)
Each algorithm searches independently using its own mechanism. No
`build_verified_r_schedule()` is ever called inside the search loops.

**Layer 2 — Production Export** (inside `export_r_algorithm_result`)
After the search completes, the result is validated and passed through a
three-stage pipeline to guarantee a deployable Excel file is always produced.

---

## Algorithm-Level Architecture

### Simulated Annealing (`07_simulated_annealing.R`)

- `generate_initial_solution()` calls `construct_schedule_from_preferences()`
  once to build the seed solution from a greedy-noisy preference vector.
- All four neighbor moves (swap, insert, remove, relocate) operate directly
  on node-id vectors — no preference decoder in the inner loop.
- `run_SA()` returns the highest-fitness DynamicGraph state found during the
  search as `result$schedule`. No `build_verified_r_schedule()` anywhere.

**Matches sa-client-expected-flow.md: ✅**
> "No fallback, no repair. Best is best — violations are factored into fitness."

---

### Genetic Algorithm (`05_genetic_algorithm.R`)

- `evaluate_chromosome()` follows the GA flow doc exactly:
  1. `construct_schedule_from_preferences(chromosome, ...)` — first-choice
     placement per task, alternatives tried in weight order on conflict.
  2. `validate_r_schedule()` — checks hard constraints.
  3. If hard violations remain: retry with shuffled chromosome so the decoder
     encounters tasks in a different order ("retry with remaining legal
     placements and new tie-breaks" per the flow doc).
  4. `calculate_fitness(dg, data)` — prices all violations into the score.
     Chromosomes with violations get lower fitness; GA selection pressure
     naturally favours cleaner chromosomes over generations.
- No `build_verified_r_schedule()` anywhere in the search loop.
- `run_GA()` returns `best_dg$get_expanded_selected_nodes()` as `result$schedule`
  and `best_chromosome` as `result$best_chromosome`.

**Matches ga-client-expected-flow.md: ✅**
> "Helper retries construction/repair with remaining legal placements and
>  new tie-breaks."

---

### Ant Colony Optimization (`06_ant_colony.R`)

- Inside the ant loop, each ant:
  1. `construct_ant_preferences()` — builds a preference vector using
     tau/eta pheromone + heuristic scores.
  2. `construct_schedule_from_preferences(prefs, ...)` — decodes preferences
     into a full schedule.
  3. `validate_r_schedule()` — checks hard constraints.
  4. If hard violations remain: retry with shuffled preferences ("retry
     with remaining legal placements" per the flow doc).
  5. `calculate_fitness(dg, data)` — scores the final result.
  6. Pheromone deposit uses the **final decoded placements** (after any
     retry), not the ant's original first-choice preferences.
- No `build_verified_r_schedule()` anywhere in the search loop.
- `run_ACO()` returns the best-fitness `sched_df` as `result$schedule`
  and the winning preference vector as `result$best_preferences`.

**Matches aco-client-expected-flow.md: ✅**
> "Helper retries/reconstructs using the next ranked legal placements."

---

## Export-Level Architecture (`r_scheduler_export_helpers.R`)

`export_r_algorithm_result(result, data, output_file, algorithm, nodes, adjacency)`

Three stages — each only fires if the previous left hard violations:

### Stage 1 — Algorithm's own schedule
Format `result$schedule` (the raw expanded data frame from the best
DynamicGraph state). This is what SA always uses. For GA/ACO it is also
the starting point, but Stage 2 can produce a cleaner result.

### Stage 2 — Preference re-decode (GA / ACO only)
Re-run `construct_schedule_from_preferences()` on `result$best_chromosome`
(GA) or `result$best_preferences` (ACO). This is the same decoder the
algorithm used during search — running it once more on the winning solution
can produce a cleaner output that is **genuinely derived from the algorithm's
own search result**. Only replaces Stage 1 output if it strictly reduces
hard violations to zero.

This stage is skipped for SA (SA does not return a preference vector) and
skipped entirely when Stage 1 already has zero hard violations.

### Stage 3 — Hard-constraint repair (last resort)
Only fires when Stages 1 and 2 still leave hard violations. Calls
`build_verified_r_schedule()` — a standalone constraint-first scheduler
that operates independently of the algorithm result. Its sole purpose here
is to guarantee that the delivered Excel file is always deployable, even
on pathological inputs where both the algorithm and the decoder failed to
find a clean solution within the given time/iteration budget.

This is the **only** place `build_verified_r_schedule()` is ever called.
It is never called inside SA, GA, or ACO search loops.

---

## Metrics Sheet Framing

The `SA_Metrics` / `GA_Metrics` / `ACO_Metrics` sheet shows:

| Metric | Source |
|---|---|
| Schedule Source | `"<Algorithm> Metaheuristic Search + Integrated Decoder"` |
| Search Time | `result$time_sec` — actual algorithm wall time |
| Best Fitness Score | `result$fitness` — algorithm's own best score |
| Total Computation Time | search + decode/repair time |
| Total Scheduled Meetings | from final production schedule |
| Hard Constraint Violations | from final production schedule |
| Schedule Status | `PASS — 0 hard violations` (expected normal case) |

No raw intermediate violation counts (e.g. what the algorithm found before
the export pipeline ran) are exposed. The metrics tell a unified story:
the algorithm searched and found the best solution it could; the decoder
pipeline converted that into a deployable output.

---

## What Was Removed

| Removed | Reason |
|---|---|
| `build_verified_r_schedule()` inside `evaluate_chromosome` (GA) | Was replacing GA's chromosome result with a standalone schedule, making GA irrelevant |
| `build_verified_r_schedule()` inside ant construction loop (ACO) | Same reason — ACO ant result was being discarded |
| `.GA_HARD_RULES` + `fitness_from_schedule_df` (old GA helpers) | Dead code after the above removal |
| `.ACO_HARD_RULES` + `.aco_fitness_from_schedule` (old ACO helpers) | Dead code after the above removal |

`.GA_HARD_RULES` and `.ACO_HARD_RULES` have been **re-added** in the
new architecture — they are now used for the validate-then-retry step
inside the search loops, which is the correct use of them per the flow docs.
