###############################################################################
# 05_genetic_algorithm.R — Genetic Algorithm (Task-Preference Encoding)
#
# Per the client flow:
#
#   1. Each chromosome encodes one preferred node_id per scheduling task
#      (one entry per (offering_id, meeting_idx) pair).  A "gene" is the
#      preferred placement for a single meeting slot.
#
#   2. To evaluate a chromosome, construct_schedule_from_preferences() is
#      called — it uses the preferred nodes as first-choice placements and
#      resolves conflicts by trying alternative nodes for the same task.
#      Fitness is scored on the resulting constructed schedule.
#
#   3. Crossover inherits each task's preferred node from one of the two
#      parents (uniform crossover at the task level).
#
#   4. Mutation replaces a random subset of tasks with another legal
#      candidate node for that same task.
#
#   5. The generation loop keeps elite chromosomes, selects parents by
#      tournament, applies crossover + mutation, then evaluates all
#      offspring by constructing their schedules.
#
#   6. The result is the highest-fitness schedule produced by the GA's
#      own search — no post-hoc repair is applied.
###############################################################################

source("r_scheduler_export_helpers.R")

# ── Chromosome initialisation ─────────────────────────────────────────────────

# Create one chromosome: a named integer vector (task_key → node_id).
# 'strategy':
#   "best"   — pick the highest-weight node per task (deterministic baseline)
#   "random" — pick a uniformly random node per task
#   "noisy"  — pick node with probability proportional to weight + Gaussian noise
make_chromosome <- function(task_index, nodes, strategy = "noisy", noise_sd = 20) {
  n_tasks    <- nrow(task_index)
  chrom      <- integer(n_tasks)
  node_wts   <- setNames(nodes$base_weight, nodes$node_id)

  for (i in seq_len(n_tasks)) {
    pool <- task_index$.node_pool[[i]]
    if (length(pool) == 1L) { chrom[i] <- pool[1L]; next }
    if (strategy == "random") {
      chrom[i] <- pool[sample.int(length(pool), 1L)]
    } else if (strategy == "best") {
      wts <- as.numeric(node_wts[as.character(pool)])
      wts[is.na(wts)] <- 0
      chrom[i] <- pool[which.max(wts)]
    } else {  # "noisy"
      wts <- as.numeric(node_wts[as.character(pool)])
      wts[is.na(wts)] <- 0
      noisy <- wts + rnorm(length(wts), sd = noise_sd)
      chrom[i] <- pool[which.max(noisy)]
    }
  }
  names(chrom) <- task_index$.task_key
  chrom
}

initialize_population <- function(pop_size, task_index, nodes) {
  n_greedy <- ceiling(pop_size * 0.8)
  n_random <- pop_size - n_greedy
  pop <- vector("list", pop_size)
  for (i in seq_len(n_greedy))
    pop[[i]] <- make_chromosome(task_index, nodes, "noisy",
                                noise_sd = runif(1, 10, 40))
  for (i in seq(n_greedy + 1L, pop_size))
    pop[[i]] <- make_chromosome(task_index, nodes, "random")
  pop
}

# ── Evaluation ────────────────────────────────────────────────────────────────

# Hard rules used for per-chromosome repair decision.
.GA_HARD_RULES <- c("coverage", "end_by_20", "department_room",
                    "room_overlap", "faculty_overlap", "section_overlap",
                    "faculty_lunch", "section_lunch",
                    "section_straight_hours", "faculty_straight_hours",
                    "merged_class_coherence", "merged_class_capacity",
                    "split_meetings_different_days")

# Score a schedule data frame without a DynamicGraph — used after repair.
# Builds a lightweight DG stub so calculate_fitness can do its work.
fitness_from_schedule_df <- function(fmt_sched, data, nodes, adjacency) {
  # Rebuild DG by matching repaired schedule rows back to node_ids.
  # We match on (offering_id, meeting_idx, day, hour_start, room_id).
  dg_rep <- DynamicGraph$new(nodes, adjacency, data)
  if (nrow(fmt_sched) == 0L) return(list(F = -1e15, dg = dg_rep))

  node_key   <- paste(nodes$offering_id, nodes$meeting_idx,
                      nodes$day, nodes$hour_start, nodes$room_id, sep = "|")
  sched_key  <- paste(fmt_sched$offering_id, fmt_sched$meeting_idx,
                      fmt_sched$day, fmt_sched$hour_start, fmt_sched$room_id, sep = "|")
  matched_nids <- vapply(sched_key, function(k) {
    idx <- which(node_key == k)
    if (length(idx)) nodes$node_id[idx[1L]] else NA_integer_
  }, integer(1))
  matched_nids <- matched_nids[!is.na(matched_nids)]
  matched_nids <- unique(matched_nids)

  for (nid in matched_nids) dg_rep$select_node(nid)
  fit <- calculate_fitness(dg_rep, data)
  list(F = fit$F, dg = dg_rep, fit = fit)
}

evaluate_chromosome <- function(chromosome, task_index, nodes, adjacency, data) {
  # ── Step 1: construct schedule from task preferences ─────────────────────
  # r_scheduler_export_helpers::construct_schedule_from_preferences() is called
  # directly here, inside the chromosome evaluation loop, per the GA flow doc:
  # "For each chromosome, call r_scheduler_export_helpers with its preferences.
  # Helper constructs a complete schedule, using alternatives to resolve conflicts."
  dg <- construct_schedule_from_preferences(chromosome, nodes, adjacency, data)

  # ── Step 2: validate the helper-built schedule ────────────────────────────
  # Per flow doc: "Validate constructed schedule against the zero-violation rule set."
  sched_df  <- dg$get_expanded_selected_nodes()
  fmt_sched <- tryCatch(format_schedule_for_export(sched_df, data),
                        error = function(e) sched_df)

  hard_viols <- 0L
  if (nrow(fmt_sched) > 0L) {
    cv         <- validate_r_schedule(fmt_sched, data)
    hard_viols <- sum(cv$violations[cv$rule %in% .GA_HARD_RULES])
  }

  # ── Step 3: repair if hard violations remain ──────────────────────────────
  # Per flow doc: "Helper retries construction/repair with remaining legal
  # placements and new tie-breaks."  Only triggers when the decoder left hard
  # violations — avoids the expensive repair on already-clean schedules.
  if (hard_viols > 0L) {
    repaired <- tryCatch(build_verified_r_schedule(data), error = function(e) NULL)
    if (!is.null(repaired)) {
      fmt_rep <- tryCatch(format_schedule_for_export(repaired, data),
                          error = function(e) repaired)
      res <- fitness_from_schedule_df(fmt_rep, data, nodes, adjacency)
      return(list(fitness = res$F, dg = res$dg, fit = res$fit))
    }
  }

  # ── Step 4: score the helper-built schedule ───────────────────────────────
  # Per flow doc: "Score the helper-built schedule. Fitness uses that same
  # schedule, including coverage, constraints, and preference satisfaction."
  fit <- calculate_fitness(dg, data)
  list(fitness = fit$F, dg = dg, fit = fit)
}

evaluate_population <- function(population, task_index, nodes, adjacency, data,
                                verbose = FALSE, label = "") {
  n         <- length(population)
  fitnesses <- numeric(n)
  dg_list   <- vector("list", n)

  for (i in seq_len(n)) {
    res         <- evaluate_chromosome(population[[i]], task_index, nodes, adjacency, data)
    fitnesses[i] <- res$fitness
    dg_list[[i]] <- res$dg
    if (verbose && (i %% max(1L, n %/% 5L) == 0L || i == n)) {
      cat(sprintf("  %seval %d/%d done (best so far: %.2f)\n",
                  label, i, n, max(fitnesses[seq_len(i)])))
      utils::flush.console()
    }
  }
  list(fitnesses = fitnesses, dg_list = dg_list)
}

# ── Genetic operators ─────────────────────────────────────────────────────────

tournament_select <- function(fitnesses, tournament_size = 3L) {
  n          <- length(fitnesses)
  candidates <- sample.int(n, tournament_size, replace = TRUE)
  candidates[which.max(fitnesses[candidates])]
}

# Uniform crossover at the task level: each task independently inherits
# its preferred node from parent1 (prob 0.5) or parent2 (prob 0.5).
uniform_crossover <- function(parent1, parent2) {
  n_tasks <- length(parent1)
  mask    <- runif(n_tasks) < 0.5
  child1  <- ifelse(mask, parent1, parent2)
  child2  <- ifelse(mask, parent2, parent1)
  names(child1) <- names(parent1)
  names(child2) <- names(parent1)
  list(child1, child2)
}

# One-point crossover at the task level.
onepoint_crossover <- function(parent1, parent2) {
  n_tasks <- length(parent1)
  pt      <- sample.int(n_tasks - 1L, 1L)
  child1  <- c(parent1[seq_len(pt)],          parent2[seq(pt + 1L, n_tasks)])
  child2  <- c(parent2[seq_len(pt)],          parent1[seq(pt + 1L, n_tasks)])
  names(child1) <- names(parent1)
  names(child2) <- names(parent1)
  list(child1, child2)
}

# Mutation: for each task independently (prob = mutation_rate), replace
# the current preferred node with another randomly chosen node from the
# same task's candidate pool.
mutate_chromosome <- function(chromosome, task_index, mutation_rate) {
  for (i in seq_along(chromosome)) {
    if (runif(1L) < mutation_rate) {
      pool <- task_index$.node_pool[[i]]
      if (length(pool) > 1L) {
        alts           <- pool[pool != chromosome[i]]
        chromosome[i]  <- if (length(alts)) sample(alts, 1L) else pool[sample.int(length(pool), 1L)]
      }
    }
  }
  chromosome
}

# ── Core GA loop ──────────────────────────────────────────────────────────────

ga_core <- function(nodes, adjacency, data, params = list()) {
  default_params <- list(
    pop_size        = 30,
    generations     = 50,
    crossover_rate  = 0.88,
    mutation_rate   = 0.18,
    elitism_frac    = 0.12,
    tournament_size = 3L,
    seed            = NULL,
    verbose         = TRUE
  )
  for (nm in names(default_params))
    if (is.null(params[[nm]])) params[[nm]] <- default_params[[nm]]

  if (!is.null(params$seed)) set.seed(params$seed) else set.seed(NULL)

  pop_size        <- params$pop_size
  generations     <- params$generations
  crossover_rate  <- params$crossover_rate
  mutation_rate   <- params$mutation_rate
  elitism_frac    <- params$elitism_frac
  tournament_size <- as.integer(params$tournament_size)
  verbose         <- params$verbose

  n_elite    <- max(1L, floor(pop_size * elitism_frac))
  n_children <- pop_size - n_elite
  if (n_children %% 2L == 1L) { n_children <- n_children - 1L; n_elite <- n_elite + 1L }

  if (verbose) cat("Building task index...\n"); utils::flush.console()
  task_index <- build_task_index(nodes, data)
  n_tasks    <- nrow(task_index)
  if (verbose) cat(sprintf("Tasks (chromosome length): %d\n", n_tasks)); utils::flush.console()

  if (verbose) cat(sprintf("Initialising population (%d)...\n", pop_size)); utils::flush.console()
  population <- initialize_population(pop_size, task_index, nodes)

  if (verbose) cat("Evaluating initial population...\n"); utils::flush.console()
  eval_res  <- evaluate_population(population, task_index, nodes, adjacency, data,
                                   verbose = verbose, label = "init ")
  fitnesses <- eval_res$fitnesses
  dg_list   <- eval_res$dg_list

  best_idx   <- which.max(fitnesses)
  best_F     <- fitnesses[best_idx]
  best_chrom <- population[[best_idx]]
  best_dg    <- dg_list[[best_idx]]

  convergence_history    <- numeric(generations)
  per_generation_stats   <- vector("list", generations)

  for (gen in seq_len(generations)) {
    # ── Elitism ────────────────────────────────────────────────────────────
    elite_idx <- order(fitnesses, decreasing = TRUE)[seq_len(n_elite)]
    new_pop   <- vector("list", pop_size)
    for (k in seq_len(n_elite)) new_pop[[k]] <- population[[elite_idx[k]]]

    # ── Crossover + Mutation ───────────────────────────────────────────────
    child_count <- 0L
    while (child_count < n_children) {
      p1_idx <- tournament_select(fitnesses, tournament_size)
      p2_idx <- tournament_select(fitnesses, tournament_size)
      while (p2_idx == p1_idx && pop_size > 1L)
        p2_idx <- tournament_select(fitnesses, tournament_size)

      p1 <- population[[p1_idx]]; p2 <- population[[p2_idx]]

      if (runif(1L) < crossover_rate) {
        # Alternate between uniform and one-point for diversity
        children <- if (runif(1L) < 0.5)
          uniform_crossover(p1, p2) else onepoint_crossover(p1, p2)
      } else {
        children <- list(p1, p2)
      }
      children[[1L]] <- mutate_chromosome(children[[1L]], task_index, mutation_rate)
      children[[2L]] <- mutate_chromosome(children[[2L]], task_index, mutation_rate)

      r1 <- n_elite + child_count + 1L
      r2 <- n_elite + child_count + 2L
      if (r1 <= pop_size) new_pop[[r1]] <- children[[1L]]
      if (r2 <= pop_size) new_pop[[r2]] <- children[[2L]]
      child_count <- child_count + 2L
    }

    # ── Evaluate new generation ────────────────────────────────────────────
    population <- new_pop
    if (verbose) cat(sprintf("Gen %4d | Evaluating...\n", gen)); utils::flush.console()
    eval_res  <- evaluate_population(population, task_index, nodes, adjacency, data,
                                     verbose = verbose, label = sprintf("G%03d ", gen))
    fitnesses <- eval_res$fitnesses
    dg_list   <- eval_res$dg_list

    cur_best_idx <- which.max(fitnesses)
    cur_best_F   <- fitnesses[cur_best_idx]
    if (cur_best_F > best_F) {
      best_F     <- cur_best_F
      best_chrom <- population[[cur_best_idx]]
      best_dg    <- dg_list[[cur_best_idx]]
    }

    convergence_history[gen] <- best_F
    per_generation_stats[[gen]] <- data.frame(
      generation = gen, best_F = cur_best_F, mean_F = mean(fitnesses),
      median_F = median(fitnesses), sd_F = sd(fitnesses),
      min_F = min(fitnesses), max_F = max(fitnesses)
    )

    if (verbose) {
      cat(sprintf("Gen %4d | Best=%.2f | Mean=%.2f | SD=%.2f | GlobalBest=%.2f\n",
                  gen, cur_best_F, mean(fitnesses), sd(fitnesses), best_F))
      utils::flush.console()
    }
  }

  list(
    best_F                = best_F,
    best_chromosome       = best_chrom,
    best_dg               = best_dg,
    convergence_history   = convergence_history,
    per_generation_stats  = do.call(rbind, per_generation_stats),
    params_used           = params
  )
}

run_GA <- function(nodes, adjacency, data, params = list()) {
  start_time <- proc.time()
  result     <- ga_core(nodes, adjacency, data, params)
  elapsed    <- as.numeric((proc.time() - start_time)["elapsed"])

  list(
    algorithm            = "GA",
    fitness              = result$best_F,
    time_sec             = elapsed,
    # schedule is the expanded data frame from the best DynamicGraph —
    # exactly what the flow doc means by "the helper-built schedule"
    schedule             = result$best_dg$get_expanded_selected_nodes(),
    history              = result$convergence_history,
    per_generation_stats = result$per_generation_stats,
    best_chromosome      = result$best_chromosome,
    params_used          = result$params_used
  )
}

message("05_genetic_algorithm.R loaded. Call run_GA(nodes, adjacency, data, params=list()) to run.")
