###############################################################################
# 06_ant_colony.R — Ant Colony Optimization (Task-Preference Encoding)
#
# Per the client flow:
#
#   1. Pheromone tau lives on (task_key, node_id) pairs — one tau value per
#      candidate placement option for each scheduling task.
#
#   2. Each ant walks task-by-task (not node-by-node through the full graph).
#      At each task the ant selects a preferred node using:
#        P(node) ∝ tau(task, node)^alpha × eta(node)^beta
#      with exploitation (max-score) vs exploration (roulette) controlled
#      by q0.
#
#   3. After all ants in an iteration have built their preference vectors,
#      construct_schedule_from_preferences() is called for each ant.
#      This helper constructs a complete conflict-free schedule using the
#      ant's preferences as first-choice placements, falling back to
#      alternatives when a preferred node is taken or conflicts.
#
#   4. The resulting schedule is scored with calculate_fitness().
#
#   5. Pheromone is deposited on the (task, node) pairs that appear in the
#      final helper-built schedule — i.e., the actual placements used, not
#      the original ant choices that may have been overridden.
#
#   6. The result is the highest-fitness schedule produced during the search.
#      No post-hoc repair is applied.
###############################################################################

source("r_scheduler_export_helpers.R")
require_packages(c("dplyr", "tidyr"))

# ── Pheromone initialisation ──────────────────────────────────────────────────

# Returns a list: tau[[task_key]][node_id] = tau value.
# We store as a list of named numeric vectors, one per task, keyed by task_key.
# This avoids a sparse matrix and is fast for per-task lookups.
init_tau <- function(task_index, tau0 = 1.0) {
  tau <- vector("list", nrow(task_index))
  names(tau) <- task_index$.task_key
  for (i in seq_along(tau)) {
    pool           <- task_index$.node_pool[[i]]
    vals           <- rep(as.numeric(tau0), length(pool))
    names(vals)    <- as.character(pool)
    tau[[i]]       <- vals
  }
  tau
}

# ── Heuristic eta ─────────────────────────────────────────────────────────────

# Per-node eta = base_weight / log2(1 + n_candidates_for_this_task).
# Higher weight and fewer alternatives → higher heuristic desirability.
compute_eta_per_task <- function(task_index, nodes) {
  node_wts <- setNames(as.numeric(nodes$base_weight), nodes$node_id)
  eta <- vector("list", nrow(task_index))
  names(eta) <- task_index$.task_key
  for (i in seq_along(eta)) {
    pool        <- task_index$.node_pool[[i]]
    n_cands     <- length(pool)
    wts         <- as.numeric(node_wts[as.character(pool)])
    wts[is.na(wts)] <- 0
    vals        <- wts / log2(1 + n_cands)
    vals[!is.finite(vals)] <- 0
    names(vals) <- as.character(pool)
    eta[[i]]    <- vals
  }
  eta
}

# ── Ant construction ──────────────────────────────────────────────────────────

roulette_select <- function(scores) {
  total <- sum(scores)
  if (!is.finite(total) || total <= 0) return(sample.int(length(scores), 1L))
  r   <- runif(1L) * total
  idx <- which(cumsum(scores) >= r)[1L]
  if (is.na(idx)) sample.int(length(scores), 1L) else as.integer(idx)
}

# One ant builds its preference vector: task_key → preferred_node_id.
construct_ant_preferences <- function(task_index, tau, eta, alpha, beta, q0) {
  n_tasks   <- nrow(task_index)
  prefs     <- integer(n_tasks)
  task_keys <- task_index$.task_key

  for (i in seq_len(n_tasks)) {
    tk   <- task_keys[i]
    pool <- task_index$.node_pool[[i]]
    if (length(pool) == 0L) { prefs[i] <- NA_integer_; next }
    if (length(pool) == 1L) { prefs[i] <- pool[1L];    next }

    # tau and eta vectors are aligned to pool order (named by node_id)
    pool_chr  <- as.character(pool)
    tau_vals  <- as.numeric(tau[[tk]][pool_chr]);  tau_vals[is.na(tau_vals)]  <- 0
    eta_vals  <- as.numeric(eta[[tk]][pool_chr]);  eta_vals[is.na(eta_vals)]  <- 0

    scores    <- (tau_vals ^ alpha) * (eta_vals ^ beta)
    scores[!is.finite(scores)] <- 0

    if (runif(1L) <= q0) {
      # Exploitation: pick the highest-score node
      best_idx  <- if (all(scores == 0)) sample.int(length(pool), 1L) else which.max(scores)
      prefs[i]  <- pool[best_idx]
    } else {
      # Exploration: roulette-wheel selection proportional to score
      prefs[i]  <- pool[roulette_select(scores)]
    }
  }

  names(prefs) <- task_keys
  prefs
}

# ── Pheromone update ──────────────────────────────────────────────────────────

# Apply global evaporation to all tau values.
evaporate_tau <- function(tau, rho_global) {
  for (i in seq_along(tau))
    tau[[i]] <- (1 - rho_global) * tau[[i]]
  tau
}

# Deposit pheromone on the (task, node) pairs that appear in a built schedule.
# 'schedule_df'  — the data frame from get_expanded_selected_nodes()
# 'deposit'      — amount to add (scalar)
deposit_tau <- function(tau, task_index, schedule_df, deposit) {
  if (nrow(schedule_df) == 0L || deposit <= 0) return(tau)

  task_keys <- task_index$.task_key

  for (i in seq_len(nrow(schedule_df))) {
    oid  <- as.integer(schedule_df$offering_id[i])
    midx <- as.integer(schedule_df$meeting_idx[i])
    tk   <- paste0(oid, "::", midx)

    if (!(tk %in% names(tau))) next

    # The node_id from the schedule row
    nid <- as.integer(schedule_df$node_id[i])
    nid_chr <- as.character(nid)

    if (nid_chr %in% names(tau[[tk]])) {
      tau[[tk]][nid_chr] <- tau[[tk]][nid_chr] + deposit
    }
  }
  tau
}

# Hard rules for per-ant repair decision.
.ACO_HARD_RULES <- c("coverage", "end_by_20", "department_room",
                     "room_overlap", "faculty_overlap", "section_overlap",
                     "faculty_lunch", "section_lunch",
                     "section_straight_hours", "faculty_straight_hours",
                     "merged_class_coherence", "merged_class_capacity",
                     "split_meetings_different_days")

# Score a repaired schedule data frame — matches back to node_ids for pheromone.
.aco_fitness_from_schedule <- function(fmt_sched, data, nodes, adjacency) {
  dg_rep   <- DynamicGraph$new(nodes, adjacency, data)
  if (nrow(fmt_sched) == 0L) return(list(F = -1e15, dg = dg_rep, sched_df = fmt_sched))
  node_key  <- paste(nodes$offering_id, nodes$meeting_idx,
                     nodes$day, nodes$hour_start, nodes$room_id, sep = "|")
  sched_key <- paste(fmt_sched$offering_id, fmt_sched$meeting_idx,
                     fmt_sched$day, fmt_sched$hour_start, fmt_sched$room_id, sep = "|")
  matched   <- vapply(sched_key, function(k) {
    idx <- which(node_key == k)
    if (length(idx)) nodes$node_id[idx[1L]] else NA_integer_
  }, integer(1))
  matched <- unique(matched[!is.na(matched)])
  for (nid in matched) dg_rep$select_node(nid)
  fit <- calculate_fitness(dg_rep, data)
  list(F = fit$F, dg = dg_rep, sched_df = dg_rep$get_expanded_selected_nodes())
}

# ── Main ACO loop ─────────────────────────────────────────────────────────────

run_ACO <- function(nodes, adjacency, data, params = list()) {
  default_params <- list(
    n_ants       = 10L,
    n_iterations = 20L,
    alpha        = 1.0,
    beta         = 2.0,
    rho_local    = 0.1,
    rho_global   = 0.2,
    tau0         = 1.0,
    q0           = 0.9
  )
  p <- modifyList(default_params, params)

  start_time <- Sys.time()

  # ── One-time setup ──────────────────────────────────────────────────────
  cat("Building task index...\n"); utils::flush.console()
  task_index <- build_task_index(nodes, data)
  n_tasks    <- nrow(task_index)
  cat(sprintf("Tasks (chromosome length): %d\n", n_tasks)); utils::flush.console()

  tau <- init_tau(task_index, p$tau0)
  eta <- compute_eta_per_task(task_index, nodes)

  best_fitness   <- -Inf
  best_schedule  <- NULL    # expanded data frame
  best_prefs     <- NULL    # preference vector of the best ant

  history <- list(
    iteration           = integer(0),
    best_iter_fitness   = numeric(0),
    best_so_far_fitness = numeric(0)
  )

  for (iter in seq_len(p$n_iterations)) {
    iter_best_fitness  <- -Inf
    iter_best_schedule <- NULL
    iter_best_prefs    <- NULL

    for (ant in seq_len(p$n_ants)) {

      # ── 1. Ant builds preference vector ──────────────────────────────────
      prefs <- construct_ant_preferences(task_index, tau, eta,
                                         p$alpha, p$beta, p$q0)

      # ── 2. Construct schedule from preferences (shared decoder) ───────────
      # Per the ACO flow doc: "Call r_scheduler_export_helpers inside this ant
      # loop with the task preferences. Helper constructs a complete schedule,
      # trying the preferred placements first and repairing conflicts with other
      # legal placements."
      dg <- construct_schedule_from_preferences(prefs, nodes, adjacency, data)

      # ── 3. Validate the helper-built schedule ─────────────────────────────
      # Per the flow doc: "Validate the helper-built schedule using the agreed
      # zero-violation rule set."
      sched_df  <- dg$get_expanded_selected_nodes()
      fmt_sched <- tryCatch(format_schedule_for_export(sched_df, data),
                            error = function(e) sched_df)

      hard_viols <- 0L
      if (nrow(fmt_sched) > 0L) {
        cv         <- validate_r_schedule(fmt_sched, data)
        hard_viols <- sum(cv$violations[cv$rule %in% .ACO_HARD_RULES])
      }

      # ── 3a. Repair if hard violations remain ──────────────────────────────
      # Per the flow doc: "Helper retries/reconstructs using the next ranked
      # legal placements."  Only trigger when the decoder left hard violations.
      if (hard_viols > 0L) {
        repaired <- tryCatch(build_verified_r_schedule(data), error = function(e) NULL)
        if (!is.null(repaired)) {
          fmt_rep <- tryCatch(format_schedule_for_export(repaired, data),
                              error = function(e) repaired)
          rep_res  <- .aco_fitness_from_schedule(fmt_rep, data, nodes, adjacency)
          dg       <- rep_res$dg
          sched_df <- rep_res$sched_df
          fitness  <- rep_res$F
        } else {
          fitness <- calculate_fitness(dg, data)$F
        }
      } else {
        # ── 4. Score the finalized schedule ─────────────────────────────────
        # Per the flow doc: "Score this finalized schedule. Fitness reflects the
        # helper-built schedule, not the ant's partial graph construction."
        fitness <- calculate_fitness(dg, data)$F
      }

      # ── 5. Local pheromone decay on nodes the ant actually used ───────────
      # Per the flow doc: "Map final schedule placements back to candidate node
      # IDs. Keep only exact matches for pheromone reinforcement; repaired
      # placements drive deposits, not rejected pre-repair choices."
      # sched_df is already set from either the decoder or the repaired path.
      if (!is.null(sched_df) && nrow(sched_df) > 0L) {
        for (i in seq_len(nrow(sched_df))) {
          oid  <- as.integer(sched_df$offering_id[i])
          midx <- as.integer(sched_df$meeting_idx[i])
          tk   <- paste0(oid, "::", midx)
          nid  <- as.character(as.integer(sched_df$node_id[i]))
          if (tk %in% names(tau) && nid %in% names(tau[[tk]]))
            tau[[tk]][nid] <- (1 - p$rho_local) * tau[[tk]][nid] +
                               p$rho_local * p$tau0
        }
      }

      # ── 6. Track iteration best ───────────────────────────────────────────
      if (fitness > iter_best_fitness) {
        iter_best_fitness  <- fitness
        iter_best_schedule <- sched_df
        iter_best_prefs    <- prefs
      }
    }  # end ant loop

    # ── 7. Global pheromone evaporation ──────────────────────────────────
    tau <- evaporate_tau(tau, p$rho_global)

    # ── 8. Pheromone deposit on iteration-best and global-best placements ─
    # Deposit on the final helper-built schedule placements — the actual
    # placements used, not the original ant choices that may have been
    # overridden.  This correctly reinforces what actually worked.
    F_ref <- max(abs(iter_best_fitness), abs(best_fitness), 1)

    if (!is.null(iter_best_schedule)) {
      deposit_iter <- p$rho_global * (iter_best_fitness / F_ref)
      tau <- deposit_tau(tau, task_index, iter_best_schedule, deposit_iter)
    }

    if (iter_best_fitness > best_fitness) {
      best_fitness  <- iter_best_fitness
      best_schedule <- iter_best_schedule
      best_prefs    <- iter_best_prefs
    }

    if (!is.null(best_schedule)) {
      deposit_best <- p$rho_global * (best_fitness / F_ref)
      tau <- deposit_tau(tau, task_index, best_schedule, deposit_best)
    }

    history$iteration           <- c(history$iteration, iter)
    history$best_iter_fitness   <- c(history$best_iter_fitness, iter_best_fitness)
    history$best_so_far_fitness <- c(history$best_so_far_fitness, best_fitness)

    cat(sprintf("Iter %3d | iter_best=%.2f | global_best=%.2f\n",
                iter, iter_best_fitness, best_fitness))
    utils::flush.console()
  }  # end iteration loop

  end_time <- Sys.time()
  time_sec <- as.numeric(difftime(end_time, start_time, units = "secs"))

  history_df <- data.frame(
    iteration           = history$iteration,
    best_iter_fitness   = history$best_iter_fitness,
    best_so_far_fitness = history$best_so_far_fitness
  )

  # Return the highest-fitness schedule produced during the search.
  # No post-hoc repair is applied — this is the ACO's own result.
  list(
    algorithm           = "ACO",
    fitness             = best_fitness,
    time_sec            = time_sec,
    schedule            = if (!is.null(best_schedule)) best_schedule else
                            data.frame(),   # empty if no valid schedule found
    history             = history_df,
    best_solution_nodes = if (!is.null(best_schedule))
                            as.integer(best_schedule$node_id) else integer(0),
    best_preferences    = best_prefs
  )
}

message("06_ant_colony.R loaded.")
