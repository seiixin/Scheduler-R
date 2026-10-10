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
OUR DRAFT PROPOSAL TO CLIENT:


Simulated Annealing Flow (refined to match the current codebase)

    [ Start ]
        |
        v
+------------------------------------------------------+
| Load scheduling data; build candidate nodes and      |
| compatibility graph. Node = feasible placement       |
| option. The SA state is a set of selected node IDs.  |
+------------------------------------------------------+
        |
        v
+------------------------------------------------------+
| Precompute once (shared across all SA iterations):   |
| • node_weights  — preference-weighted node scores    |
| • meetings_needed — required meeting count per       |
|   offering (from nodes table)                        |
| • seed_weights  — base weights for greedy init       |
+------------------------------------------------------+
        |
        v
+------------------------------------------------------+
| generate_initial_solution():                         |
| Build a greedy seed with additive Gaussian noise     |
| (σ = 0.5 × sd(base_weights)) injected into node     |
| weights to diversify the starting point.             |
| Returns a DynamicGraph with selected_ids set.        |
+------------------------------------------------------+
        |
        v
+------------------------------------------------------+
| Fast-path exit: if the initial greedy solution has   |
| zero missing meetings and passes the optional        |
| verification_fn, return immediately without entering |
| the SA loop at all.                                  |
+------------------------------------------------------+
        |
        v
+------------------------------------------------------+ <-------------------+
| calculate_fitness(dg, data)                          |                     |
| Produces F = Σ vertex_weights                        |                     |
|            − schedule_penalty                        |                     |
|            − coverage_penalty                        |                     |
|            − workload_penalty                        |                     |
| Set T_start = |F_initial| × T0_factor               |                     |
| Set current_F, best_F, best_ids, best_dg             |                     |
+------------------------------------------------------+                     |
        |                                                                     |
        v                                                                     |
   ┌─ Outer Cooling Loop (k = 1 … total_cooling_steps) ────────────────────┐ |
   │                                                                        │ |
   │  ┌─ Inner Iteration Loop (j = 1 … n_iter_temp) ─────────────────────┐ │ |
   │  │                                                                   │ │ |
   │  │  generate_neighbor():                                             │ │ |
   │  │  Randomly select one of four move types:                         │ │ |
   │  │    A (30%) neighbor_move_swap     — pure adjacency check,        │ │ |
   │  │                                     no DynamicGraph rebuild      │ │ |
   │  │    B (25%) neighbor_move_insert   — add a missing meeting;       │ │ |
   │  │                                     one DynamicGraph rebuild     │ │ |
   │  │    C (20%) neighbor_move_remove   — drop one node & try to       │ │ |
   │  │                                     refill; one rebuild          │ │ |
   │  │    D (25%) neighbor_move_relocate — move candidate to a          │ │ |
   │  │                                     different slot; pure         │ │ |
   │  │                                     adjacency check, no rebuild  │ │ |
   │  │                                                                   │ │ |
   │  │  If neighbor_ids ≡ current_ids → no-op; skip scoring             │ │ |
   │  │                                                                   │ │ |
   │  │  fitness_from_ids(neighbor_ids):                                  │ │ |
   │  │  Rebuild DynamicGraph once; call calculate_fitness.               │ │ |
   │  │  Produce neighbor_F.                                              │ │ |
   │  │                                                                   │ │ |
   │  │  ΔF = neighbor_F − current_F                                     │ │ |
   │  │                                                                   │ │ |
   │  │  Acceptance rule:                                                 │ │ |
   │  │    ΔF > 0  → accept (always)                                     │ │ |
   │  │    ΔF ≤ 0  → accept if runif(1) < exp(ΔF / T_current)           │ │ |
   │  │                                                                   │ │ |
   │  │  If accepted:                                                     │ │ |
   │  │    • current_ids ← neighbor_ids                                  │ │ |
   │  │    • current_F   ← neighbor_F                                    │ │ |
   │  │    • current_dg  ← neighbor_dg                                   │ │ |
   │  │    • If current_F > best_F → update best_F, best_ids, best_dg   │ │ |
   │  │    • If is_verified_complete(current_dg) → stop_early = TRUE     │ │ |
   │  │                                             break inner loop     │ │ |
   │  └───────────────────────────────────────────────────────────────────┘ │ |
   │                                                                        │ |
   │  Record convergence row (step, T, avg_F, best_F, accepted, improved) │ |
   │                                                                        │ |
   │  If stop_early → break outer loop                                     │ |
   │                                                                        │ |
   │  T_current ← T_current × alpha_cool                                  │ |
   │  reheat_counter += 1                                                  │ |
   │  If reheat_counter ≥ reheat_interval:                                 │ |
   │    T_current ← min(T_current × 1.5, T_start × 0.5)   (partial       │ |
   │                                                         reheat)       │ |
   │    reheat_counter ← 0                                                 │ |
   └────────────────────────────────────────────────────────────────────────┘ |
        |                                                                     |
        +---------------------------------------------------------------------+
        |
        v
+------------------------------------------------------+
| Return the best solution found during the search:    |
| best_dg$get_expanded_selected_nodes() as schedule,   |
| best_F as fitness, best_ids as best_solution_nodes,  |
| convergence_history data frame.                      |
|                                                      |
| No post-hoc repair or fallback is applied.           |
| The schedule returned is whatever DynamicGraph state |
| produced the highest fitness score during the run.   |
| Remaining violations are already priced into F via   |
| coverage_penalty and schedule_penalty terms.         |
+------------------------------------------------------+
        |
        v
     [ End ]


Implementation notes:
- is_verified_complete() is a short-circuit early-exit, NOT a repair step.
  It only fires when the DynamicGraph already shows zero missing meetings
  AND the optional verification_fn passes. It triggers a clean early stop,
  not a reconstruction.
- There is no build_verified_r_schedule() call anywhere in run_SA().
  SA lives and dies by its own DynamicGraph + calculate_fitness path,
  exactly like GA and ACO do with their own internal evaluators.
- This makes SA directly comparable to GA and ACO: all three return the
  best scoring solution from their own search, with no external repair.
