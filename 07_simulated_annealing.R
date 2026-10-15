###############################################################################
# 07_simulated_annealing.R — Simulated Annealing Scheduler
#
# Per the client's agreed flow (sa-client-expected-flow.md):
#
#   The SA state is a PREFERENCE VECTOR — one preferred node_id per
#   scheduling task (same encoding as GA chromosomes and ACO ant preferences).
#
#   1. Generate an initial schedule by building a noisy preference vector
#      and decoding it through r_scheduler_export_helpers::
#      construct_schedule_from_preferences().
#
#   2. SA cooling loop:
#        a. Perturb the CURRENT preference vector by one of four moves:
#             • Swap    — replace a task's preferred node with another
#                         candidate for the same task
#             • Relocate — change a task's preferred node to one that maps
#                         to a different day/time/room
#             • Insert  — for an uncovered task, add a preferred node
#             • Remove  — drop a task's preference and attempt to replace it
#        b. Decode the PERTURBED preferences via
#           construct_schedule_from_preferences() → neighbor schedule.
#           The helper tries the preferred node first, falls back to
#           alternatives in weight order when conflicts arise.
#        c. Evaluate fitness F of the neighbor schedule.
#        d. Accept/Reject:
#             ΔF > 0  → always accept
#             ΔF ≤ 0  → accept with probability P = exp(ΔF / T)
#        e. If accepted: current_prefs ← neighbor_prefs,
#                        current_dg   ← neighbor_dg
#        f. Track best solution (highest F) seen so far.
#
#   3. Cool down T = T × alpha after each batch of iterations.
#      Partial reheat every reheat_interval steps.
#
#   4. Return the preference vector and decoded schedule that produced the
#      highest fitness.  No post-hoc repair is applied.
#      r_scheduler_export_helpers is the schedule-maker; SA is the
#      accept/reject decision-maker.
#
# Performance notes:
#   • node_weights and task_index are precomputed once and shared across
#     all perturbation functions and fitness evaluations.
#   • construct_schedule_from_preferences() is called once per inner
#     iteration (for the neighbor decode) — one call per proposed move.
#   • is_verified_complete() short-circuits to an early exit when the
#     current solution already has zero missing meetings, avoiding the
#     expensive row-build of get_expanded_selected_nodes() on every step.
###############################################################################

source("04_fitness_calculation.R")
require_packages(c("dplyr", "tidyr"))

# construct_schedule_from_preferences() is defined in r_scheduler_export_helpers.R
# which is sourced by the entry point (sa_scheduler.R) after this file.
# It is available at runtime when run_SA() is called.

# ── Initial solution ──────────────────────────────────────────────────────────

generate_initial_solution <- function(nodes, adjacency, data,
                                      base_weights = NULL) {
  # Build a noisy preference vector: for each task, pick the highest-weight
  # node after adding Gaussian noise so each run starts from a different point.
  node_wts <- if (!is.null(base_weights))
    as.numeric(base_weights)
  else
    as.numeric(precompute_node_weights(nodes, data))

  noise <- rnorm(length(node_wts), mean = 0,
                 sd = pmax(sd(node_wts) * 0.5, 1e-6))
  noisy <- node_wts + noise

  task_key_vec <- paste0(nodes$offering_id, "::", nodes$meeting_idx)
  task_keys    <- unique(task_key_vec)

  prefs <- integer(length(task_keys))
  names(prefs) <- task_keys
  for (tk in task_keys) {
    idx       <- which(task_key_vec == tk)
    prefs[tk] <- nodes$node_id[idx[which.max(noisy[idx])]]
  }

  # Decode the initial preference vector through the shared helper.
  dg <- construct_schedule_from_preferences(prefs, nodes, adjacency, data)

  list(prefs = prefs, dg = dg)
}

# ── Preference-level perturbation functions ───────────────────────────────────
#
# Each function takes the CURRENT preference vector and returns a PERTURBED
# copy.  The caller decodes it via construct_schedule_from_preferences().
#
# All four correspond directly to the move types in the client flow diagram:
#   Swap, Relocate, Insert, Remove.
#
# Arguments shared by all:
#   current_prefs — named integer vector: task_key → preferred node_id
#   task_index    — data frame with .task_key and .node_pool columns
#   nodes         — full candidate nodes data frame
#   node_weights  — named numeric vector: node_id → weight (precomputed once)

# Swap: replace one task's preferred node with a different node for the same task.
pref_swap <- function(current_prefs, task_index, nodes, node_weights) {
  n_tasks <- length(current_prefs)
  if (n_tasks == 0L) return(current_prefs)

  # Pick a random task that has at least two candidates
  task_order <- sample(n_tasks)
  for (ti in task_order) {
    tk   <- names(current_prefs)[ti]
    pool <- task_index$.node_pool[[match(tk, task_index$.task_key)]]
    if (length(pool) < 2L) next

    current_nid <- current_prefs[ti]
    alts        <- pool[pool != current_nid]
    if (length(alts) == 0L) next

    # Prefer higher-weight alternatives but pick randomly among top half
    alt_wts  <- node_weights[as.character(alts)]
    alt_wts[is.na(alt_wts)] <- 0
    chosen   <- alts[sample(length(alts), 1L,
                            prob = pmax(alt_wts - min(alt_wts) + 1e-6, 1e-6))]
    new_prefs    <- current_prefs
    new_prefs[ti] <- chosen
    return(new_prefs)
  }
  current_prefs  # no swap found (all tasks have only one candidate)
}

# Relocate: change a task's preference to a node that maps to a
# different day, start time, or room than the current preference.
pref_relocate <- function(current_prefs, task_index, nodes, node_weights) {
  n_tasks <- length(current_prefs)
  if (n_tasks == 0L) return(current_prefs)

  task_order <- sample(n_tasks)
  for (ti in task_order) {
    tk          <- names(current_prefs)[ti]
    current_nid <- current_prefs[ti]
    current_node <- nodes[nodes$node_id == current_nid, , drop = FALSE]
    if (nrow(current_node) == 0L) next

    pool <- task_index$.node_pool[[match(tk, task_index$.task_key)]]
    if (length(pool) < 2L) next

    # Keep only candidates with a different day OR time OR room
    alts <- pool[pool != current_nid]
    if (length(alts) == 0L) next
    alt_nodes <- nodes[nodes$node_id %in% alts, , drop = FALSE]
    different <- alt_nodes[
      alt_nodes$day        != current_node$day        |
      alt_nodes$hour_start != current_node$hour_start |
      alt_nodes$room_id    != current_node$room_id,
      , drop = FALSE]
    if (nrow(different) == 0L) next

    wts    <- node_weights[as.character(different$node_id)]
    wts[is.na(wts)] <- 0
    chosen <- different$node_id[sample(nrow(different), 1L,
                                       prob = pmax(wts - min(wts) + 1e-6, 1e-6))]
    new_prefs     <- current_prefs
    new_prefs[ti] <- chosen
    return(new_prefs)
  }
  current_prefs
}

# Insert: for a task that has no preferred node set (NA or 0), assign one.
# Also handles the case where a task exists in task_index but is not in
# current_prefs — extends the preference vector.
pref_insert <- function(current_prefs, task_index, nodes, node_weights) {
  # Find tasks whose current preference is NA or 0
  missing_mask <- is.na(current_prefs) | current_prefs == 0L
  missing_tks  <- names(current_prefs)[missing_mask]

  if (length(missing_tks) == 0L) {
    # All tasks have preferences — randomly re-assign one task to a new node
    # (acts as a diversification insert into an already-covered solution)
    ti <- sample(length(current_prefs), 1L)
    tk <- names(current_prefs)[ti]
    pool_idx <- match(tk, task_index$.task_key)
    if (is.na(pool_idx)) return(current_prefs)
    pool <- task_index$.node_pool[[pool_idx]]
    if (length(pool) == 0L) return(current_prefs)
    wts    <- node_weights[as.character(pool)]
    wts[is.na(wts)] <- 0
    chosen <- pool[sample(length(pool), 1L,
                          prob = pmax(wts - min(wts) + 1e-6, 1e-6))]
    new_prefs     <- current_prefs
    new_prefs[ti] <- chosen
    return(new_prefs)
  }

  # Assign a preferred node to one of the missing tasks
  tk       <- sample(missing_tks, 1L)
  pool_idx <- match(tk, task_index$.task_key)
  if (is.na(pool_idx)) return(current_prefs)
  pool <- task_index$.node_pool[[pool_idx]]
  if (length(pool) == 0L) return(current_prefs)
  wts    <- node_weights[as.character(pool)]
  wts[is.na(wts)] <- 0
  chosen <- pool[sample(length(pool), 1L,
                        prob = pmax(wts - min(wts) + 1e-6, 1e-6))]
  new_prefs    <- current_prefs
  new_prefs[tk] <- chosen
  new_prefs
}

# Remove: drop one task's preference (set to NA) to force the decoder to
# pick freely for that task.  Equivalent to "drop candidate and attempt
# to refill" — the decoder handles the refill via its fallback logic.
pref_remove <- function(current_prefs, task_index, nodes, node_weights) {
  if (length(current_prefs) == 0L) return(current_prefs)
  ti           <- sample(length(current_prefs), 1L)
  new_prefs    <- current_prefs
  new_prefs[ti] <- NA_integer_
  new_prefs
}

# ── Perturbation dispatcher ───────────────────────────────────────────────────

generate_neighbor_prefs <- function(current_prefs, task_index, nodes, node_weights) {
  move_type <- sample(c("swap", "relocate", "insert", "remove"), 1L,
                      prob = c(0.30, 0.25, 0.25, 0.20))
  switch(move_type,
    "swap"     = pref_swap(    current_prefs, task_index, nodes, node_weights),
    "relocate" = pref_relocate(current_prefs, task_index, nodes, node_weights),
    "insert"   = pref_insert(  current_prefs, task_index, nodes, node_weights),
    "remove"   = pref_remove(  current_prefs, task_index, nodes, node_weights)
  )
}

# ── Main SA loop ──────────────────────────────────────────────────────────────

run_SA <- function(nodes, adjacency, data, params = list()) {
  default_params <- list(
    T0_factor           = 2,
    alpha_cool          = 0.985,
    n_iter_temp         = 100,
    total_cooling_steps = 300,
    reheat_interval     = 50,
    verification_fn     = NULL
  )
  for (p in names(default_params)) {
    if (is.null(params[[p]])) params[[p]] <- default_params[[p]]
  }

  start_time <- Sys.time()

  # ── One-time precomputation ───────────────────────────────────────────────
  # node_weights and task_index are shared across all perturbation calls
  # and all fitness evaluations — never recomputed inside the loop.
  node_weights <- precompute_node_weights(nodes, data)
  task_index   <- build_task_index(nodes, data)

  # ── Generate initial solution ─────────────────────────────────────────────
  init         <- generate_initial_solution(nodes, adjacency, data,
                                            base_weights = nodes$base_weight)
  current_prefs <- init$prefs
  current_dg    <- init$dg

  # ── Verified-complete short-circuit ──────────────────────────────────────
  # Only expands the full schedule data frame (expensive) when coverage
  # already shows zero missing meetings.
  is_verified_complete <- function(dg) {
    if (dg$get_coverage()$missing_meetings != 0L) return(FALSE)
    if (is.null(params$verification_fn)) return(TRUE)
    isTRUE(params$verification_fn(dg$get_expanded_selected_nodes()))
  }

  # Fast-path: if the initial decode already produces a complete schedule,
  # return immediately without entering the cooling loop.
  if (is_verified_complete(current_dg)) {
    elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
    fit_init <- calculate_fitness(current_dg, data)
    return(list(
      algorithm           = "SA",
      fitness             = fit_init$F,
      time_sec            = elapsed,
      schedule            = current_dg$get_expanded_selected_nodes(),
      convergence_history = data.frame(
        step = 0L, temperature = NA_real_,
        avg_F = fit_init$F, best_F = fit_init$F,
        accepted = 0L, improved = 0L),
      best_solution_nodes = current_dg$selected_ids,
      best_preferences    = current_prefs
    ))
  }

  # ── Initialise SA state ───────────────────────────────────────────────────
  current_fit   <- calculate_fitness(current_dg, data)
  current_F     <- current_fit$F

  best_prefs    <- current_prefs
  best_dg       <- current_dg
  best_F        <- current_F

  T_start        <- (abs(current_F) + 1e-6) * params$T0_factor
  T_current      <- T_start
  convergence_rows <- vector("list", params$total_cooling_steps)
  stop_early     <- FALSE
  reheat_counter <- 0L

  # ── Cooling loop ──────────────────────────────────────────────────────────
  for (k in seq_len(params$total_cooling_steps)) {
    temp_F_sum    <- 0
    temp_accepted <- 0L
    temp_improved <- 0L

    for (j in seq_len(params$n_iter_temp)) {

      # ── Step a: perturb the current preference vector ─────────────────
      neighbor_prefs <- generate_neighbor_prefs(current_prefs, task_index,
                                                nodes, node_weights)

      # No-op: if perturbation produced the identical preference vector,
      # skip the decode and scoring entirely.
      if (identical(neighbor_prefs, current_prefs)) {
        temp_F_sum <- temp_F_sum + current_F
        next
      }

      # ── Step b: decode the perturbed preferences via the helper ───────
      # construct_schedule_from_preferences() tries each task's preferred
      # node first, then falls back to alternatives in weight order.
      # This is "Make New Sched (Prioritize Existing Nodes + Random
      # Numbers) using r_scheduler_export_helpers" per the client flow.
      neighbor_dg <- construct_schedule_from_preferences(
        neighbor_prefs, nodes, adjacency, data
      )

      # ── Step c: score the neighbor schedule ───────────────────────────
      neighbor_fit <- calculate_fitness(neighbor_dg, data)
      neighbor_F   <- neighbor_fit$F

      # ── Step d: accept or reject ──────────────────────────────────────
      delta    <- neighbor_F - current_F
      accepted <- FALSE
      if (delta > 0) {
        accepted      <- TRUE
        temp_improved <- temp_improved + 1L
      } else if (T_current > 1e-12) {
        if (runif(1L) < exp(delta / T_current)) accepted <- TRUE
      }

      if (accepted) {
        current_prefs <- neighbor_prefs
        current_F     <- neighbor_F
        current_dg    <- neighbor_dg
        temp_accepted <- temp_accepted + 1L

        # Track global best
        if (current_F > best_F) {
          best_F     <- current_F
          best_prefs <- current_prefs
          best_dg    <- current_dg
        }

        # Early exit if the accepted solution is already complete
        if (is_verified_complete(current_dg)) {
          stop_early <- TRUE
          break
        }
      }

      temp_F_sum <- temp_F_sum + current_F
    }   # inner iteration loop

    avg_F <- temp_F_sum / params$n_iter_temp
    convergence_rows[[k]] <- data.frame(
      step        = k,
      temperature = T_current,
      avg_F       = avg_F,
      best_F      = best_F,
      accepted    = temp_accepted,
      improved    = temp_improved
    )

    if (stop_early) break

    # ── Cool down ──────────────────────────────────────────────────────
    T_current      <- T_current * params$alpha_cool
    reheat_counter <- reheat_counter + 1L
    if (reheat_counter >= params$reheat_interval) {
      T_current      <- min(T_current * 1.5, T_start * 0.5)
      reheat_counter <- 0L
    }
  }   # outer cooling loop

  end_time <- Sys.time()
  time_sec <- as.numeric(difftime(end_time, start_time, units = "secs"))

  # Trim NULL tails from convergence_rows before rbind
  last_used <- max(which(vapply(convergence_rows, Negate(is.null), logical(1))), 0L)
  conv_hist <- if (last_used > 0L)
    do.call(rbind, convergence_rows[seq_len(last_used)])
  else
    data.frame(step = integer(0), temperature = numeric(0),
               avg_F = numeric(0), best_F = numeric(0),
               accepted = integer(0), improved = integer(0))

  # Return the best solution found.
  # The schedule is the decoded output from the best preference vector —
  # exactly what construct_schedule_from_preferences produced for best_prefs.
  # No post-hoc repair is applied; SA decides, helper builds.
  list(
    algorithm           = "SA",
    fitness             = best_F,
    time_sec            = time_sec,
    schedule            = best_dg$get_expanded_selected_nodes(),
    convergence_history = conv_hist,
    best_solution_nodes = best_dg$selected_ids,
    best_preferences    = best_prefs
  )
}

message("07_simulated_annealing.R loaded.")
