CLIENT EXPECTED FLOW:

[ Start ]
           |
           v
+------------------------------------------------------+
| Initialize with a single greedy solution.            |
| Assign a starting temperature T based on the         |
| initial fitness (high enough to accept bad moves).   |
+------------------------------------------------------+
           |
           v
+------------------------------------------------------+ <---+ (Cooling Loop Start)
| Generate a Neighbor Solution                         |     |
| Perturb the current schedule by one of:              |     |
|   • Swap: replace a placed candidate with            |     |
|     another for the same meeting slot                |     |
|   • Relocate: move a candidate to a different        |     |
|     day/time/room for the same meeting slot          |     |
|   • Insert: add a candidate for an uncovered meeting |     |
|   • Remove: drop one candidate and attempt to        |     |
|     refill uncovered meetings                        |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
+------------------------------------------------------+     |
| Evaluate the fitness F of the Neighbor               |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
    < ΔF = F_neighbor − F_current >                         |
      /                 \                                    |
  ΔF > 0             ΔF ≤ 0                                 |
 (Better)          (Worse or Equal)                          |
     |                   |                                   |
     v                   v                                   |
+-----------+   +-------------------------------+            |
| Accept    |   | Accept with probability       |            |
| the move  |   | P = exp(ΔF / T)               |            |
+-----------+   | (occasionally accept worse    |            |
     |          | solutions to escape           |            |
     |          | local optima)                 |            |
     |          +-------------------------------+            |
     |                   |                                   |
     +-------------------+                                   |
                 |                                           |
                 v                                           |
+------------------------------------------------------+     |
| Update current solution if accepted.                 |     |
| Track best solution found so far.                    |     |
+------------------------------------------------------+     |
                 |                                           |
                 v                                           |
    < Max Iterations at T Reached? >                        |
          /               \                                  |
        (No)             (Yes)                               |
          |                 |                                |
          |                 v                                |
          |     +-------------------------------+            |
          |     | Cool Down: T = T × α          |            |
          |     | (reduce temperature)          |            |
          |     +-------------------------------+            |
          |                 |                                |
          +---+<------------+                                |
              |                                              |
              v                                              |
    < Max Cooling Steps Reached? >                          |
          /               \                                  |
        (No)             (Yes)                               |
          |                 |                                |
          +------+          v                                |
                 |  +-----------------------+                |
    (Back to     |  | Return the best       |-->[ End ]      |
    Loop Start)--+  | solution found so far |               |
                    +-----------------------+               |
                                                            |
                    (No fallback, no repair.                |
                     Best is best — violations              |
                     are factored into fitness.)            |
                                                            +


-------------------------------------------------------------------
IMPLEMENTED FLOW (matches client's agreed design):


Simulated Annealing — Preference-Vector Architecture
(07_simulated_annealing.R)

    [ Start ]
        |
        v
+------------------------------------------------------+
| Load scheduling data; build candidate nodes and      |
| compatibility graph.                                 |
| Precompute once:                                     |
|   • node_weights  — preference-weighted node scores  |
|   • task_index   — task pool lookup for all tasks    |
+------------------------------------------------------+
        |
        v
+------------------------------------------------------+
| generate_initial_solution():                         |
| Build a noisy preference vector — one preferred      |
| node_id per task, chosen by weight + Gaussian noise. |
| Call construct_schedule_from_preferences() to decode |
| into a full schedule (DynamicGraph).                 |
| Returns: list(prefs = ..., dg = ...)                 |
+------------------------------------------------------+
        |
        v
+------------------------------------------------------+
| Fast-path exit: if the initial decoded schedule is   |
| already complete (zero missing meetings), return     |
| immediately without entering the SA loop.            |
+------------------------------------------------------+
        |
        v
+------------------------------------------------------+
| calculate_fitness(current_dg, data) → current_F     |
| Set T_start = |current_F| × T0_factor               |
| Set best_prefs, best_dg, best_F = current state     |
+------------------------------------------------------+
        |
        v
   ┌─ Outer Cooling Loop (k = 1 … total_cooling_steps) ──────────────────┐
   │                                                                      │
   │  ┌─ Inner Iteration Loop (j = 1 … n_iter_temp) ───────────────────┐ │
   │  │                                                                 │ │
   │  │  generate_neighbor_prefs():                                     │ │
   │  │  Randomly select one of four PREFERENCE-LEVEL perturbations:    │ │
   │  │                                                                 │ │
   │  │    Swap     (30%) — replace one task's preferred node with      │ │
   │  │                      a different candidate for the same task    │ │
   │  │    Relocate (25%) — change one task's preference to a node      │ │
   │  │                      in a different day / time / room           │ │
   │  │    Insert   (25%) — assign a preferred node to an uncovered     │ │
   │  │                      task (or re-assign a covered one)          │ │
   │  │    Remove   (20%) — set one task's preference to NA so the      │ │
   │  │                      decoder picks freely for that task         │ │
   │  │                                                                 │ │
   │  │  If neighbor_prefs ≡ current_prefs → no-op, skip decode        │ │
   │  │                                                                 │ │
   │  │  construct_schedule_from_preferences(neighbor_prefs, ...)       │ │
   │  │  → neighbor_dg  (helper builds the neighbor schedule)          │ │
   │  │                                                                 │ │
   │  │  calculate_fitness(neighbor_dg) → neighbor_F                   │ │
   │  │                                                                 │ │
   │  │  ΔF = neighbor_F − current_F                                   │ │
   │  │                                                                 │ │
   │  │  Acceptance rule:                                               │ │
   │  │    ΔF > 0  → accept (always)                                   │ │
   │  │    ΔF ≤ 0  → accept if runif(1) < exp(ΔF / T_current)         │ │
   │  │                                                                 │ │
   │  │  If accepted:                                                   │ │
   │  │    • current_prefs ← neighbor_prefs                            │ │
   │  │    • current_F     ← neighbor_F                                │ │
   │  │    • current_dg    ← neighbor_dg                               │ │
   │  │    • If current_F > best_F → update best_F, best_prefs,       │ │
   │  │                               best_dg                          │ │
   │  │    • If is_verified_complete(current_dg) → stop_early, break  │ │
   │  └─────────────────────────────────────────────────────────────────┘ │
   │                                                                      │
   │  Record convergence row (step, T, avg_F, best_F, accepted, improved)│
   │  If stop_early → break outer loop                                    │
   │  T_current ← T_current × alpha_cool                                 │
   │  Reheat every reheat_interval steps:                                 │
   │    T_current ← min(T_current × 1.5, T_start × 0.5)                 │
   └──────────────────────────────────────────────────────────────────────┘
        |
        v
+------------------------------------------------------+
| Return the best solution found during the search:    |
|   schedule   = best_dg$get_expanded_selected_nodes() |
|   fitness    = best_F                                |
|   best_prefs = best_preferences vector               |
|   convergence_history data frame                     |
|                                                      |
| No post-hoc repair is applied inside run_SA().       |
| r_scheduler_export_helpers builds every schedule;    |
| SA decides which ones to accept or reject.           |
+------------------------------------------------------+
        |
        v
     [ End ]


Implementation notes:
- The SA state is a PREFERENCE VECTOR (named integer vector:
  task_key → preferred node_id), identical in format to a GA chromosome
  and an ACO ant preference vector.  This makes all three algorithms
  directly comparable: they all use the same decoder.
- construct_schedule_from_preferences() is called ONCE per inner
  iteration to decode the neighbor preference vector.  The helper tries
  the preferred node first, falls back to alternatives in weight order.
  SA is the accept/reject mechanism; the helper is the schedule-builder.
- is_verified_complete() is a short-circuit early-exit only.  It fires
  when the decoded schedule already has zero missing meetings.  It does
  NOT call any repair function.
- No build_verified_r_schedule() is called anywhere inside run_SA().
  The export pipeline (export_r_algorithm_result) handles production
  verification after the search completes.
