source("04_fitness_calculation.R")

evaluate_chromosome <- function(chromosome, nodes, adjacency, data) {
  dg <- DynamicGraph$new(nodes, adjacency, data)
  for (nid in chromosome) {
    if (dg$active_remaining == 0L) break
    dg$select_node(nid)
  }
  fit <- calculate_fitness(dg, data)
  list(
    fitness = fit$F,
    schedule = dg$selected_ids,
    dg_ref = dg,
    fit_detail = fit
  )
}

evaluate_population <- function(population, nodes, adjacency, data, verbose = FALSE, label = "") {
  n <- nrow(population)
  fitnesses <- numeric(n)
  schedules <- vector("list", n)
  for (i in seq_len(n)) {
    res <- evaluate_chromosome(population[i, ], nodes, adjacency, data)
    fitnesses[i] <- res$fitness
    schedules[[i]] <- res$schedule
    if (verbose && (i %% max(1L, n %/% 5L) == 0L || i == n)) {
      cat(sprintf("  %seval %d/%d done (best so far: %.2f)\n", label, i, n, max(fitnesses[1:i])))
      utils::flush.console()
    }
  }
  list(fitnesses = fitnesses, schedules = schedules)
}

create_random_permutation <- function(n_nodes) {
  sample.int(n_nodes, n_nodes, replace = FALSE)
}

create_greedy_randomized <- function(n_nodes, weights, noise_sd = 20) {
  noisy_weights <- weights + rnorm(n_nodes, mean = 0, sd = noise_sd)
  order(-noisy_weights)
}

initialize_population <- function(pop_size, nodes, weights) {
  n_nodes <- nrow(nodes)
  n_greedy <- ceiling(pop_size * 0.8)
  n_random <- pop_size - n_greedy
  population <- matrix(0L, nrow = pop_size, ncol = n_nodes)
  for (i in seq_len(n_greedy)) {
    population[i, ] <- create_greedy_randomized(n_nodes, weights, noise_sd = runif(1, 10, 40))
  }
  if (n_random > 0) {
    for (i in (n_greedy + 1):pop_size) {
      population[i, ] <- create_random_permutation(n_nodes)
    }
  }
  population
}

tournament_select <- function(fitnesses, tournament_size = 3) {
  n <- length(fitnesses)
  candidates <- sample.int(n, tournament_size, replace = TRUE)
  candidates[which.max(fitnesses[candidates])]
}

order_crossover <- function(parent1, parent2) {
  n <- length(parent1)
  if (n < 3) return(matrix(c(parent1, parent2), nrow = 2, byrow = TRUE))
  points <- sort(sample.int(n, 2, replace = FALSE))
  a <- points[1]; b <- points[2]
  child1 <- integer(n); child2 <- integer(n)
  child1[a:b] <- parent1[a:b]
  child2[a:b] <- parent2[a:b]
  fill1 <- setdiff(parent2, child1[a:b])
  fill2 <- setdiff(parent1, child2[a:b])
  pos1 <- c(1:(a - 1), (b + 1):n)
  pos2 <- pos1
  child1[pos1] <- fill1
  child2[pos2] <- fill2
  matrix(c(child1, child2), nrow = 2, byrow = TRUE)
}

swap_mutation <- function(chromosome) {
  n <- length(chromosome)
  if (n < 2) return(chromosome)
  pts <- sample.int(n, 2, replace = FALSE)
  temp <- chromosome[pts[1]]
  chromosome[pts[1]] <- chromosome[pts[2]]
  chromosome[pts[2]] <- temp
  chromosome
}

scramble_mutation <- function(chromosome, subset_frac = 0.25) {
  n <- length(chromosome)
  if (n < 4) return(swap_mutation(chromosome))
  subset_size <- max(2, floor(n * subset_frac))
  start <- sample.int(n - subset_size + 1, 1)
  end <- start + subset_size - 1
  idx <- start:end
  chromosome[idx] <- sample(chromosome[idx])
  chromosome
}

mutate_chromosome <- function(chromosome, mutation_rate) {
  if (runif(1) < mutation_rate) {
    if (runif(1) < 0.5) {
      chromosome <- swap_mutation(chromosome)
    } else {
      chromosome <- scramble_mutation(chromosome)
    }
  }
  chromosome
}

ga_core <- function(nodes, adjacency, data, params = list()) {
  default_params <- list(
    pop_size = 100,
    generations = 200,
    crossover_rate = 0.85,
    mutation_rate = 0.15,
    elitism_frac = 0.10,
    tournament_size = 3,
    seed = NULL,
    verbose = TRUE
  )
  for (nm in names(default_params)) {
    if (is.null(params[[nm]])) params[[nm]] <- default_params[[nm]]
  }
  if (!is.null(params$seed)) set.seed(params$seed) else set.seed(NULL)

  pop_size <- params$pop_size
  generations <- params$generations
  crossover_rate <- params$crossover_rate
  mutation_rate <- params$mutation_rate
  elitism_frac <- params$elitism_frac
  tournament_size <- params$tournament_size
  verbose <- params$verbose

  n_nodes <- nrow(nodes)
  n_elite <- max(1, floor(pop_size * elitism_frac))
  n_children <- pop_size - n_elite
  if (n_children %% 2 == 1) {
    n_children <- n_children - 1
    n_elite <- n_elite + 1
  }

  if (verbose) cat("Precomputing node weights...\n")
  weights <- precompute_node_weights(nodes, data)

  if (verbose) cat("Initializing population (", pop_size, ")...\n", sep = "")
  population <- initialize_population(pop_size, nodes, weights)

  if (verbose) cat("Evaluating initial population...\n")
  eval_res <- evaluate_population(population, nodes, adjacency, data, verbose = verbose, label = "init ")
  fitnesses <- eval_res$fitnesses
  schedules <- eval_res$schedules

  convergence_history <- numeric(generations)
  per_generation_stats <- list()

  best_idx <- which.max(fitnesses)
  best_F <- fitnesses[best_idx]
  best_chromosome <- population[best_idx, ]
  best_schedule <- schedules[[best_idx]]

  for (gen in seq_len(generations)) {
    elite_idx <- order(fitnesses, decreasing = TRUE)[1:n_elite]
    new_population <- matrix(0L, nrow = pop_size, ncol = n_nodes)
    new_population[1:n_elite, ] <- population[elite_idx, ]

    child_count <- 0
    while (child_count < n_children) {
      p1_idx <- tournament_select(fitnesses, tournament_size)
      p2_idx <- tournament_select(fitnesses, tournament_size)
      while (p2_idx == p1_idx && pop_size > 1) {
        p2_idx <- tournament_select(fitnesses, tournament_size)
      }
      p1 <- population[p1_idx, ]
      p2 <- population[p2_idx, ]
      if (runif(1) < crossover_rate) {
        children <- order_crossover(p1, p2)
      } else {
        children <- matrix(c(p1, p2), nrow = 2, byrow = TRUE)
      }
      children[1, ] <- mutate_chromosome(children[1, ], mutation_rate)
      children[2, ] <- mutate_chromosome(children[2, ], mutation_rate)
      target_row1 <- n_elite + child_count + 1
      target_row2 <- n_elite + child_count + 2
      if (target_row1 <= pop_size) new_population[target_row1, ] <- children[1, ]
      if (target_row2 <= pop_size) new_population[target_row2, ] <- children[2, ]
      child_count <- child_count + 2
    }

    population <- new_population
    if (verbose) cat(sprintf("Gen %4d | Evaluating population...\n", gen))
    eval_res <- evaluate_population(population, nodes, adjacency, data, verbose = verbose, label = sprintf("G%02d ", gen))
    fitnesses <- eval_res$fitnesses
    schedules <- eval_res$schedules

    cur_best_idx <- which.max(fitnesses)
    cur_best_F <- fitnesses[cur_best_idx]
    if (cur_best_F > best_F) {
      best_F <- cur_best_F
      best_chromosome <- population[cur_best_idx, ]
      best_schedule <- schedules[[cur_best_idx]]
    }

    convergence_history[gen] <- best_F
    gen_stats <- list(
      generation = gen,
      best_F = cur_best_F,
      mean_F = mean(fitnesses),
      median_F = median(fitnesses),
      sd_F = sd(fitnesses),
      min_F = min(fitnesses),
      max_F = max(fitnesses)
    )
    per_generation_stats[[gen]] <- gen_stats

    if (verbose) {
      cat(sprintf("Gen %4d | Best=%.2f | Mean=%.2f | SD=%.2f | GlobalBest=%.2f\n",
        gen, cur_best_F, gen_stats$mean_F, gen_stats$sd_F, best_F))
      utils::flush.console()
    }
  }

  per_generation_stats <- do.call(rbind, lapply(per_generation_stats, as.data.frame))

  list(
    best_F = best_F,
    best_chromosome = best_chromosome,
    best_schedule = best_schedule,
    convergence_history = convergence_history,
    per_generation_stats = per_generation_stats,
    final_population = population,
    final_fitnesses = fitnesses,
    params_used = params
  )
}

run_GA <- function(nodes, adjacency, data, params = list()) {
  start_time <- proc.time()
  result <- ga_core(nodes, adjacency, data, params)
  elapsed <- as.numeric((proc.time() - start_time)["elapsed"])
  list(
    algorithm = "GA",
    fitness = result$best_F,
    time_sec = elapsed,
    schedule = result$best_schedule,
    history = result$convergence_history,
    per_generation_stats = result$per_generation_stats,
    best_chromosome = result$best_chromosome,
    params_used = result$params_used
  )
}

message("05_genetic_algorithm.R loaded. Call run_GA(nodes, adjacency, data, params=list()) to run.")
