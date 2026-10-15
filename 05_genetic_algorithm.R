###############################################################################
# 05_genetic_algorithm.R — Genetic Algorithm (Task-Preference Encoding)
#
# Per the client flow (ga-client-expected-flow.md):
#
#   1. Each chromosome encodes one preferred node_id per scheduling task
#      (one entry per (offering_id, meeting_idx) pair).  A "gene" is the
#      preferred placement for a single meeting slot.
#
#   2. To evaluate a chromosome:
#        a. Call construct_schedule_from_preferences() with the chromosome's
#           preferred nodes.  The helper tries first-choice placements and
#           falls back to alternative nodes for the same task when conflicts
#           arise.
#        b. Validate the constructed schedule against the hard-constraint
#           rule set.
#        c. If hard violations remain, re-run construct_schedule_from_preferences
#           up to MAX_RETRIES times, each time with a reshuffled preference
#           vector so the helper encounters tasks in a different order and
#           breaks ties differently.  Stop as soon as violations reach zero;
#           keep the attempt with the fewest violations otherwise.
#        d. Score the final result with calculate_fitness().
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
#   6. The best schedule returned is the highest-fitness result produced
#      by the GA's own search loop — no post-hoc repair outside the loop.
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

# ── Hard-constraint rules used for per-chromosome validation ─────────────────
.GA_HARD_RULES <- c("coverage", "end_by_20", "department_room",
                    "room_overlap", "faculty_overlap", "section_overlap",
                    "faculty_lunch", "section_lunch",
                    "section_straight_hours", "faculty_straight_hours",
                    "merged_class_coherence", "merged_class_capacity",
                    "split_meetings_different_days")

# ── Evaluation ────────────────────────────────────────────────────────────────

evaluate_chromosome <- function(chromosome, task_index, nodes, adjacency, data) {

  # ── Step 1: construct schedule from task preferences ─────────────────────
  # construct_schedule_from_preferences() tries the chromosome's first-choice
  # node per task, then falls back to alternative nodes in weight order
  # when a preferred placement conflicts with an already-placed meeting.
  dg <- construct_schedule_from_preferences(chromosome, nodes, adjacency, data)

  # ── Step 2: validate the constructed schedule ─────────────────────────────
  # Per flow doc: "Validate constructed schedule against the agreed
  # zero-violation rule set."
  sched_df  <- dg$get_expanded_selected_nodes()
  fmt_sched <- tryCatch(format_schedule_for_export(sched_df, data),
                        error = function(e) sched_df)
  hard_viols <- 0L
  if (nrow(fmt_sched) > 0L) {
    cv         <- validate_r_schedule(fmt_sched, data)
    hard_viols <- sum(cv$violations[cv$rule %in% .GA_HARD_RULES])
  }

  # ── Step 3: retry loop if hard violations remain ─────────────────────────
  # Per flow doc: "Helper retries construction/repair with remaining legal
  # placements and new tie-breaks."  The flow doc shows a Validate → retry
  # loop, so we run up to MAX_RETRIES additional decode attempts.  Each
  # attempt shuffles the chromosome so the decoder encounters tasks in a
  # different order, breaking ties differently and potentially resolving
  # the conflicts that the first attempt could not.
  # We stop as soon as we reach zero hard violations; otherwise we keep
  # the attempt that produced the fewest violations.
  if (hard_viols > 0L) {
    best_retry_dg    <- dg
    best_retry_viols <- hard_viols
    MAX_RETRIES      <- 3L

    for (attempt in seq_len(MAX_RETRIES)) {
      shuffled        <- chromosome[sample(length(chromosome))]
      names(shuffled) <- names(chromosome)
      dg_try          <- construct_schedule_from_preferences(shuffled, nodes,
                                                             adjacency, data)
      sched_try <- tryCatch(
        format_schedule_for_export(dg_try$get_expanded_selected_nodes(), data),
        error = function(e) data.frame()
      )
      viols_try <- if (nrow(sched_try) > 0L) {
        cv_try <- validate_r_schedule(sched_try, data)
        sum(cv_try$violations[cv_try$rule %in% .GA_HARD_RULES])
      } else {
        hard_viols   # treat empty result as no improvement
      }

      if (viols_try < best_retry_viols) {
        best_retry_dg    <- dg_try
        best_retry_viols <- viols_try
      }

      if (best_retry_viols == 0L) break   # zero violations — stop early
    }

    # Accept the best retry result if it improved over the original
    if (best_retry_viols < hard_viols) dg <- best_retry_dg
  }

  # ── Step 4: score the final schedule ─────────────────────────────────────
  # calculate_fitness() prices all remaining violations into the score via
  # coverage_penalty and schedule_penalty.  Chromosomes with hard violations
  # still receive a meaningful (lower) fitness, so GA selection pressure
  # naturally favours cleaner solutions over generations.
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
