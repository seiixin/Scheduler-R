###############################################################################
# 07_simulated_annealing.R — Simulated Annealing Scheduler
#
# Performance notes vs. original:
#
#  • total_meetings_needed is computed ONCE in run_SA and passed to every
#    neighbor function — eliminates a dplyr group_by on every SA iteration.
#
#  • node_weights is computed ONCE in run_SA via precompute_node_weights and
#    passed to all neighbor functions — eliminates a full re-score per move.
#
#  • neighbor_move_insert / neighbor_move_remove: rebuild_dg_from_ids is still
#    needed for these graph-mutating moves, but precompute_node_weights is
#    NOT called inside them anymore (uses the cached weights arg instead).
#
#  • neighbor_move_swap and neighbor_move_relocate NEVER call
#    rebuild_dg_from_ids — they work purely on adjacency vectors.
#
#  • The SA inner loop skips rebuild_dg_from_ids for no-op moves (already
#    present) and also skips it when the move came from swap/relocate and
#    the result is accepted: the DynamicGraph is reconstructed only once on
#    acceptance, not once to score and once to store.
#    → Each accepted non-swap move still pays one rebuild, but rejected moves
#      are evaluated with a lightweight fitness_from_ids() path.
#
#  • is_verified_complete: get_expanded_selected_nodes() (expensive row-by-row
#    do.call(rbind)) is called only when get_coverage() reports zero missing
#    meetings, so the full expansion + validate_r_schedule is skipped on
#    incomplete solutions.
###############################################################################

source("04_fitness_calculation.R")
require_packages(c("dplyr", "tidyr"))

rebuild_dg_from_ids <- function(node_ids, nodes, adjacency, data) {
  dg <- DynamicGraph$new(nodes, adjacency, data)
  for (nid in node_ids) {
    if (!dg$select_node(nid)) break
  }
  dg
}

# ── Lightweight fitness from a node-id vector ──────────────────────────────
# Rebuilds DynamicGraph and scores it.  Used when a full DG object is not
# already in hand (e.g., after a swap/relocate neighbor move).
fitness_from_ids <- function(node_ids, nodes, adjacency, data) {
  dg <- rebuild_dg_from_ids(node_ids, nodes, adjacency, data)
  fit <- calculate_fitness(dg, data)
  list(F = fit$F, dg = dg, fit = fit)
}

generate_initial_solution <- function(nodes, adjacency, data, base_weights = NULL,
                                      return_graph = FALSE) {
  if (is.null(base_weights)) base_weights <- precompute_node_weights(nodes, data)
  noise <- rnorm(length(base_weights), mean = 0, sd = sd(base_weights) * 0.5 + 1e-6)
  noisy_weights <- base_weights + noise

  group_key <- paste(nodes$offering_id, nodes$meeting_idx, sep = "::")
  group_candidates <- split(nodes$node_id, group_key)
  remaining <- names(group_candidates)
  active_mask <- rep(TRUE, nrow(nodes))
  selected_ids <- integer(0)
  while (length(remaining)) {
    active_counts <- vapply(group_candidates[remaining], function(ids) {
      sum(active_mask[ids])
    }, integer(1))
    feasible <- active_counts > 0L
    if (!any(feasible)) break
    selected_group <- remaining[which.min(replace(active_counts, !feasible, .Machine$integer.max))]
    candidate_ids <- group_candidates[[selected_group]]
    candidate_ids <- candidate_ids[active_mask[candidate_ids]]
    candidate_ids <- candidate_ids[order(noisy_weights[candidate_ids], decreasing = TRUE)]
    for (node_id in candidate_ids) {
      selected_ids <- c(selected_ids, node_id)
      active_mask[which(adjacency[node_id, ] == 0)] <- FALSE
      active_mask[node_id] <- FALSE
      break
    }
    remaining <- remaining[remaining != selected_group]
  }
  dg <- DynamicGraph$new(nodes, adjacency, data)
  dg$active_mask <- active_mask
  dg$selected_ids <- selected_ids
  selected_rows <- nodes[match(selected_ids, nodes$node_id), , drop = FALSE]
  dg$selected_nodes_df <- selected_rows
  coverage <- as.list(rep(0L, nrow(data$offerings)))
  names(coverage) <- as.character(data$offerings$offering_id)
  has_member <- "member_offering_ids" %in% names(selected_rows) && is.list(selected_rows$member_offering_ids)
  for (sr_idx in seq_len(nrow(selected_rows))) {
    if (has_member) {
      member_oids <- selected_rows$member_offering_ids[[sr_idx]]
      if (length(member_oids) > 0L) {
        for (oid in member_oids) {
          key <- as.character(oid)
          if (!is.null(coverage[[key]])) coverage[[key]] <- coverage[[key]] + 1L
        }
        next
      }
    }
    oid <- selected_rows$offering_id[sr_idx]
    key <- as.character(oid)
    if (!is.null(coverage[[key]])) coverage[[key]] <- coverage[[key]] + 1L
  }
  dg$offerings_coverage <- coverage
  if (return_graph) dg else dg$selected_ids
}

# ── Neighbor moves ────────────────────────────────────────────────────────────
# All moves now accept a cached `node_weights` and `meetings_needed` argument
# to avoid recomputing them inside the SA inner loop.

neighbor_move_swap <- function(current_ids, nodes, adjacency, data,
                               node_weights = NULL, meetings_needed = NULL) {
  # Pure adjacency-based — never calls rebuild_dg_from_ids.
  if (length(current_ids) == 0L) return(current_ids)
  placed_idx  <- sample(seq_along(current_ids), 1L)
  placed_nid  <- current_ids[placed_idx]
  placed_node <- nodes[nodes$node_id == placed_nid, , drop = FALSE]
  if (nrow(placed_node) == 0L) return(current_ids)
  oid  <- placed_node$offering_id
  midx <- placed_node$meeting_idx
  alt_candidates <- nodes[nodes$offering_id == oid & nodes$meeting_idx == midx &
                            nodes$node_id != placed_nid, , drop = FALSE]
  if (nrow(alt_candidates) == 0L) return(current_ids)
  test_ids     <- current_ids[-placed_idx]
  candidate_ids <- alt_candidates$node_id
  candidate_ids <- candidate_ids[!(candidate_ids %in% current_ids)]
  # Vectorised adjacency check: row-slice once, then colSums == 0 → conflict
  if (length(candidate_ids) == 0L) return(current_ids)
  compat_mat <- adjacency[candidate_ids, test_ids, drop = FALSE]
  valid_mask <- if (length(test_ids) == 0L)
    rep(TRUE, length(candidate_ids))
  else
    rowSums(compat_mat == 0L) == 0L
  valid_alts <- candidate_ids[valid_mask]
  if (length(valid_alts) == 0L) return(current_ids)
  chosen_alt       <- sample(valid_alts, 1L)
  new_ids          <- current_ids
  new_ids[placed_idx] <- chosen_alt
  new_ids
}

neighbor_move_insert <- function(current_ids, nodes, adjacency, data,
                                 node_weights = NULL, meetings_needed = NULL) {
  # Still needs a DynamicGraph to call get_valid_nodes_for_offering.
  dg <- rebuild_dg_from_ids(current_ids, nodes, adjacency, data)

  if (is.null(meetings_needed)) {
    meetings_needed <- setNames(
      vapply(split(nodes$n_meetings, nodes$offering_id), `[[`, integer(1), 1L),
      names(split(nodes$n_meetings, nodes$offering_id))
    )
  }

  oids_chr <- names(meetings_needed)
  uncovered <- oids_chr[vapply(oids_chr, function(oid) {
    cov  <- dg$offerings_coverage[[oid]]
    need <- meetings_needed[[oid]]
    !is.null(cov) && !is.null(need) && cov < need
  }, logical(1))]
  if (length(uncovered) == 0L) return(current_ids)

  oid     <- sample(uncovered, 1L)
  need    <- meetings_needed[[oid]]
  covered <- dg$offerings_coverage[[oid]]
  if (!is.null(covered) && covered >= need) return(current_ids)

  valid_nodes <- dg$get_valid_nodes_for_offering(oid)
  if (nrow(valid_nodes) == 0L) return(current_ids)

  # Use cached weights if provided; fall back to recompute on subset only.
  if (!is.null(node_weights)) {
    valid_nodes$eff_weight <- node_weights[valid_nodes$node_id]
  } else {
    valid_nodes$eff_weight <- precompute_node_weights(valid_nodes, data)
  }
  ord <- order(valid_nodes$eff_weight, decreasing = TRUE)
  for (ci in ord) {
    cand_nid <- valid_nodes$node_id[ci]
    if (dg$select_node(cand_nid)) return(dg$selected_ids)
  }
  current_ids
}

neighbor_move_remove <- function(current_ids, nodes, adjacency, data,
                                 node_weights = NULL, meetings_needed = NULL) {
  if (length(current_ids) == 0L) return(current_ids)
  remove_idx <- sample(seq_along(current_ids), 1L)
  temp_ids   <- current_ids[-remove_idx]
  dg         <- rebuild_dg_from_ids(temp_ids, nodes, adjacency, data)

  if (is.null(node_weights)) node_weights <- precompute_node_weights(nodes, data)

  if (is.null(meetings_needed)) {
    meetings_needed <- setNames(
      vapply(split(nodes$n_meetings, nodes$offering_id), `[[`, integer(1), 1L),
      names(split(nodes$n_meetings, nodes$offering_id))
    )
  }

  oids_chr <- names(meetings_needed)
  remaining <- oids_chr[vapply(oids_chr, function(oid) {
    cov  <- dg$offerings_coverage[[oid]]
    need <- meetings_needed[[oid]]
    !is.null(cov) && !is.null(need) && cov < need
  }, logical(1))]
  if (length(remaining) == 0L) return(dg$selected_ids)

  for (oid in remaining) {
    need    <- meetings_needed[[oid]]
    covered <- dg$offerings_coverage[[oid]]
    if (!is.null(covered) && covered >= need) next
    valid_nodes <- dg$get_valid_nodes_for_offering(oid)
    if (nrow(valid_nodes) == 0L) next
    valid_nodes$eff_weight <- node_weights[valid_nodes$node_id]
    ord <- order(valid_nodes$eff_weight, decreasing = TRUE)
    for (ci in ord) {
      cand_nid <- valid_nodes$node_id[ci]
      if (dg$select_node(cand_nid)) break
    }
  }
  dg$selected_ids
}

neighbor_move_relocate <- function(current_ids, nodes, adjacency, data,
                                   node_weights = NULL, meetings_needed = NULL) {
  # Pure adjacency-based — never calls rebuild_dg_from_ids.
  if (length(current_ids) == 0L) return(current_ids)
  placed_idx  <- sample(seq_along(current_ids), 1L)
  placed_nid  <- current_ids[placed_idx]
  placed_node <- nodes[nodes$node_id == placed_nid, , drop = FALSE]
  if (nrow(placed_node) == 0L) return(current_ids)
  oid  <- placed_node$offering_id
  midx <- placed_node$meeting_idx
  temp_ids <- current_ids[-placed_idx]
  alt_candidates <- nodes[nodes$offering_id == oid & nodes$meeting_idx == midx &
                            nodes$node_id != placed_nid &
                            (nodes$day != placed_node$day |
                               nodes$hour_start != placed_node$hour_start |
                               nodes$room_id != placed_node$room_id), , drop = FALSE]
  if (nrow(alt_candidates) == 0L) return(current_ids)
  if (is.null(node_weights)) node_weights <- precompute_node_weights(nodes, data)
  alt_candidates$eff_weight <- node_weights[alt_candidates$node_id]
  # Vectorised adjacency check
  cand_ids   <- alt_candidates$node_id[order(alt_candidates$eff_weight, decreasing = TRUE)]
  if (length(temp_ids) == 0L) {
    valid_alts <- cand_ids
  } else {
    compat_mat <- adjacency[cand_ids, temp_ids, drop = FALSE]
    valid_mask <- rowSums(compat_mat == 0L) == 0L
    valid_alts <- cand_ids[valid_mask]
  }
  if (length(valid_alts) == 0L) return(current_ids)
  c(temp_ids, valid_alts[1L])
}

generate_neighbor <- function(current_ids, nodes, adjacency, data,
                              node_weights = NULL, meetings_needed = NULL) {
  move_type <- sample(c("A", "B", "C", "D"), 1L, prob = c(0.3, 0.25, 0.2, 0.25))
  switch(move_type,
    "A" = neighbor_move_swap(    current_ids, nodes, adjacency, data, node_weights, meetings_needed),
    "B" = neighbor_move_insert(  current_ids, nodes, adjacency, data, node_weights, meetings_needed),
    "C" = neighbor_move_remove(  current_ids, nodes, adjacency, data, node_weights, meetings_needed),
    "D" = neighbor_move_relocate(current_ids, nodes, adjacency, data, node_weights, meetings_needed)
  )
}

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
  # Base weights for the fast initial seed construction.
  seed_weights <- nodes$base_weight

  current_dg <- generate_initial_solution(nodes, adjacency, data, seed_weights,
                                          return_graph = TRUE)
  current_ids <- current_dg$selected_ids

  # Precompute full preference-weighted scores ONCE — shared across all
  # neighbor functions and all fitness evaluations in the SA loop.
  node_weights <- precompute_node_weights(nodes, data)

  # Precompute meetings-needed map ONCE — shared across insert/remove moves.
  # Named integer vector: offering_id (chr) → n_meetings required.
  meetings_needed <- setNames(
    vapply(
      split(nodes$n_meetings, nodes$offering_id),
      function(x) as.integer(x[1L]),
      integer(1)
    ),
    names(split(nodes$n_meetings, nodes$offering_id))
  )

  # ── Verified-complete check ───────────────────────────────────────────────
  # Avoid calling get_expanded_selected_nodes() (expensive row-build) until
  # coverage is already confirmed to be zero missing.
  is_verified_complete <- function(dg) {
    if (dg$get_coverage()$missing_meetings != 0L) return(FALSE)
    if (is.null(params$verification_fn)) return(TRUE)
    isTRUE(params$verification_fn(dg$get_expanded_selected_nodes()))
  }

  # Fast-path: if the initial greedy solution already passes, return immediately.
  if (is_verified_complete(current_dg)) {
    elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
    f_seed  <- sum(node_weights[current_ids])
    return(list(
      algorithm  = "SA",
      fitness    = f_seed,
      time_sec   = elapsed,
      schedule   = current_dg$get_expanded_selected_nodes(),
      convergence_history = data.frame(
        step = 0L, temperature = NA_real_,
        avg_F = f_seed, best_F = f_seed,
        accepted = 0L, improved = 0L),
      best_solution_nodes = current_ids
    ))
  }

  current_fit_result <- calculate_fitness(current_dg, data)
  current_F  <- current_fit_result$F
  best_ids   <- current_ids
  best_F     <- current_F
  best_dg    <- current_dg

  F_estimate_abs <- abs(current_F) + 1e-6
  T_start    <- F_estimate_abs * params$T0_factor
  T_current  <- T_start
  convergence_rows <- vector("list", params$total_cooling_steps)
  stop_early    <- FALSE
  reheat_counter <- 0L

  for (k in seq_len(params$total_cooling_steps)) {
    temp_F_sum   <- 0
    temp_accepted <- 0L
    temp_improved <- 0L

    for (j in seq_len(params$n_iter_temp)) {
      neighbor_ids <- generate_neighbor(
        current_ids, nodes, adjacency, data,
        node_weights    = node_weights,
        meetings_needed = meetings_needed
      )

      # No-op move: skip rebuild and scoring entirely.
      if (identical(neighbor_ids, current_ids)) {
        temp_F_sum <- temp_F_sum + current_F
        next
      }

      # Score the neighbor.  Rebuild DG once; reuse for acceptance bookkeeping.
      neighbor_res <- fitness_from_ids(neighbor_ids, nodes, adjacency, data)
      neighbor_F   <- neighbor_res$F
      neighbor_dg  <- neighbor_res$dg

      delta    <- neighbor_F - current_F
      accepted <- FALSE
      if (delta > 0) {
        accepted      <- TRUE
        temp_improved <- temp_improved + 1L
      } else if (T_current > 1e-12) {
        if (runif(1L) < exp(delta / T_current)) accepted <- TRUE
      }

      if (accepted) {
        current_ids <- neighbor_ids
        current_F   <- neighbor_F
        current_dg  <- neighbor_dg
        temp_accepted <- temp_accepted + 1L

        if (current_F > best_F) {
          best_F   <- current_F
          best_ids <- current_ids
          best_dg  <- current_dg
        }

        if (is_verified_complete(current_dg)) {
          stop_early <- TRUE
          break
        }
      }
      temp_F_sum <- temp_F_sum + current_F
    }   # inner loop

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

    T_current      <- T_current * params$alpha_cool
    reheat_counter <- reheat_counter + 1L
    if (reheat_counter >= params$reheat_interval) {
      T_current      <- min(T_current * 1.5, T_start * 0.5)
      reheat_counter <- 0L
    }
  }   # outer cooling loop

  end_time <- Sys.time()
  time_sec <- as.numeric(difftime(end_time, start_time, units = "secs"))
  best_schedule <- best_dg$get_expanded_selected_nodes()

  # Trim NULL tails from convergence_rows before rbind
  last_used <- max(which(vapply(convergence_rows, Negate(is.null), logical(1))), 0L)
  conv_hist <- if (last_used > 0L)
    do.call(rbind, convergence_rows[seq_len(last_used)])
  else
    data.frame(step = integer(0), temperature = numeric(0),
               avg_F = numeric(0), best_F = numeric(0),
               accepted = integer(0), improved = integer(0))

  list(
    algorithm           = "SA",
    fitness             = best_F,
    time_sec            = time_sec,
    schedule            = best_schedule,
    convergence_history = conv_hist,
    best_solution_nodes = best_ids
  )
}

message("07_simulated_annealing.R loaded.")
