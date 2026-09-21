source("04_fitness_calculation.R")
require_packages(c("dplyr", "tidyr"))

compute_eta <- function(nodes, adjacency, node_weights) {
  n_nodes <- nrow(nodes)
  node_weights <- as.numeric(unlist(node_weights))
  node_degree <- as.numeric(rowSums(adjacency))
  eta <- node_weights / log2(1 + node_degree)
  eta[is.na(eta) | is.infinite(eta)] <- 0
  as.numeric(eta)
}

get_prioritized_candidates <- function(dg, nodes) {
  active <- as.integer(dg$get_active_nodes())
  if (length(active) == 0) return(list(high = integer(0), low = integer(0)))

  active_nodes <- nodes[active, ]
  active_off_ids <- as.character(active_nodes$offering_id)
  coverage_vals <- as.numeric(unlist(lapply(active_off_ids, function(oid) {
    val <- dg$offerings_coverage[[oid]]
    if (!is.null(val)) as.numeric(val) else 0
  })))
  if (length(coverage_vals) != length(active)) {
    coverage_vals <- rep(0, length(active))
  }

  n_meetings_vals <- as.numeric(active_nodes$n_meetings)
  not_covered <- (coverage_vals == 0)
  partially_covered <- (coverage_vals > 0 & coverage_vals < n_meetings_vals)

  high_priority <- active[which(not_covered)]
  low_priority <- active[which(partially_covered)]

  list(high = as.integer(high_priority), low = as.integer(low_priority))
}

roulette_wheel_selection <- function(probs) {
  probs <- as.numeric(unlist(probs))
  if (length(probs) == 0) return(NA_integer_)
  if (length(probs) == 1) return(1L)
  total_prob <- sum(probs, na.rm = TRUE)
  if (is.na(total_prob) || total_prob <= 0) return(sample.int(length(probs), 1))
  cum_probs <- cumsum(probs) / total_prob
  r <- runif(1)
  idx <- which(cum_probs >= r)[1]
  if (is.na(idx)) sample.int(length(probs), 1) else as.integer(idx)
}

construct_ant_solution <- function(dg, tau, eta, alpha, beta, q0, rho_local, tau0,
                                   nodes, node_weights, data) {
  dg$reset()
  max_steps <- nrow(nodes)

  for (step in 1:max_steps) {
    candidates <- get_prioritized_candidates(dg, nodes)
    cand_pool <- if (length(candidates$high) > 0) candidates$high else candidates$low
    if (length(cand_pool) == 0) break

    tau_cand <- as.numeric(tau[cand_pool])
    eta_cand <- as.numeric(eta[cand_pool])
    scores <- as.numeric((tau_cand^alpha) * (eta_cand^beta))
    scores[is.na(scores) | is.infinite(scores)] <- 0

    if (runif(1) <= q0) {
      if (all(scores == 0)) {
        best_idx <- sample.int(length(cand_pool), 1)
      } else {
        best_idx <- which.max(scores)
      }
    } else {
      best_idx <- roulette_wheel_selection(scores)
    }

    if (is.na(best_idx)) break
    chosen_nid <- cand_pool[best_idx]

    if (!dg$select_node(chosen_nid)) {
      dg$active_mask[chosen_nid] <- FALSE
      next
    }

    tau[chosen_nid] <- as.numeric((1 - rho_local) * tau[chosen_nid] + rho_local * tau0)
  }

  fitness <- calculate_fitness(dg, data)
  list(
    node_ids = as.integer(dg$selected_ids),
    schedule = dg$get_expanded_selected_nodes(),
    fitness = as.numeric(fitness$F),
    fitness_detail = fitness
  )
}

run_ACO <- function(nodes, adjacency, data, params = list()) {
  default_params <- list(
    n_ants = 50,
    n_iterations = 150,
    alpha = 1,
    beta = 2,
    rho_local = 0.1,
    rho_global = 0.2,
    tau0 = 1.0,
    q0 = 0.9
  )
  p <- modifyList(default_params, params)

  start_time <- Sys.time()
  n_nodes <- nrow(nodes)

  node_weights <- as.numeric(unlist(precompute_node_weights(nodes, data)))
  eta <- as.numeric(compute_eta(nodes, adjacency, node_weights))
  tau <- as.numeric(rep(p$tau0, n_nodes))

  best_so_far_fitness <- -Inf
  best_so_far_nodes <- integer(0)
  best_so_far_schedule <- tibble()
  best_so_far_detail <- NULL

  history <- list(
    iteration = integer(0),
    best_iter_fitness = numeric(0),
    best_so_far_fitness = numeric(0)
  )

  dg_template <- DynamicGraph$new(nodes, adjacency, data)

  for (iter in 1:p$n_iterations) {
    iter_best_fitness <- -Inf
    iter_best_nodes <- integer(0)
    iter_best_schedule <- tibble()
    iter_best_detail <- NULL

    for (ant in 1:p$n_ants) {
      dg_ant <- DynamicGraph$new(nodes, adjacency, data)
      ant_result <- construct_ant_solution(
        dg_ant, tau, eta, p$alpha, p$beta, p$q0,
        p$rho_local, p$tau0, nodes, node_weights, data
      )

      if (ant_result$fitness > iter_best_fitness) {
        iter_best_fitness <- ant_result$fitness
        iter_best_nodes <- ant_result$node_ids
        iter_best_schedule <- ant_result$schedule
        iter_best_detail <- ant_result$fitness_detail
      }
    }

    tau <- as.numeric((1 - p$rho_global) * tau)

    deposit_nodes <- integer(0)
    deposit_fitnesses <- numeric(0)

    if (length(iter_best_nodes) > 0) {
      deposit_nodes <- c(deposit_nodes, as.integer(iter_best_nodes))
      deposit_fitnesses <- c(deposit_fitnesses, as.numeric(iter_best_fitness))
    }

    if (iter_best_fitness > best_so_far_fitness) {
      best_so_far_fitness <- iter_best_fitness
      best_so_far_nodes <- iter_best_nodes
      best_so_far_schedule <- iter_best_schedule
      best_so_far_detail <- iter_best_detail
    }

    if (length(best_so_far_nodes) > 0) {
      deposit_nodes <- c(deposit_nodes, as.integer(best_so_far_nodes))
      deposit_fitnesses <- c(deposit_fitnesses, as.numeric(best_so_far_fitness))
    }

    if (length(deposit_nodes) > 0) {
      F_reference <- max(abs(as.numeric(best_so_far_fitness)), 1)
      deposit_amounts <- as.numeric(p$rho_global * (deposit_fitnesses / F_reference))
      unique_deposit <- unique(deposit_nodes)
      for (nid in unique_deposit) {
        nid_mask <- (deposit_nodes == nid)
        tau[nid] <- tau[nid] + sum(deposit_amounts[nid_mask])
      }
    }

    history$iteration <- c(history$iteration, iter)
    history$best_iter_fitness <- c(history$best_iter_fitness, iter_best_fitness)
    history$best_so_far_fitness <- c(history$best_so_far_fitness, best_so_far_fitness)
  }

  end_time <- Sys.time()
  time_sec <- as.numeric(difftime(end_time, start_time, units = "secs"))

  history_df <- tibble(
    iteration = history$iteration,
    best_iter_fitness = history$best_iter_fitness,
    best_so_far_fitness = history$best_so_far_fitness
  )

  list(
    algorithm = "ACO",
    fitness = best_so_far_fitness,
    time_sec = time_sec,
    schedule = best_so_far_schedule,
    history = history_df,
    best_solution_nodes = best_so_far_nodes,
    fitness_detail = best_so_far_detail
  )
}

message("06_ant_colony.R loaded.")
