###############################################################################
# 08_main_execution.R — Graph-Based Dynamic Node Selection Framework
# Full Pipeline: Data Loading → Graph Construction → Meta-Heuristic Trials
#                → Statistical Comparison (ANOVA / Kruskal-Wallis)
# TUPC SY 2025-2026 First Semester
###############################################################################

require_packages <- function(pkgs) {
  for (p in pkgs) {
    if (!requireNamespace(p, quietly = TRUE)) {
      install.packages(p,
                       repos = "https://cloud.r-project.org",
                       quiet = TRUE,
                       lib = .libPaths()[1])
    }
    library(p, character.only = TRUE, quietly = TRUE)
  }
}

SCRIPT_DIR <- getwd()
setwd(SCRIPT_DIR)

LIB_DIR <- file.path(SCRIPT_DIR, "R_libs")
if (!dir.exists(LIB_DIR)) {
  dir.create(LIB_DIR, showWarnings = FALSE, recursive = TRUE)
  message("Created project-local package library at: ", LIB_DIR)
}
.libPaths(c(LIB_DIR, .libPaths()))
message("Using R library paths: ", paste(.libPaths(), collapse = " ; "))

options(warn = 1, stringsAsFactors = FALSE, scipen = 999)

require_packages(c("readxl", "dplyr", "tidyr", "stringr", "Matrix", "ggplot2", "writexl"))

source("01_data_loader.R")
source("02_graph_construction.R")
source("03_dynamic_node_selection.R")
source("04_fitness_calculation.R")
source("05_genetic_algorithm.R")
source("06_ant_colony.R")
source("07_simulated_annealing.R")

###############################################################################
# CONFIGURATION
###############################################################################

QUICK_TEST_MODE <- FALSE
qt_env <- toupper(Sys.getenv("R_UPC_QUICK_TEST", unset = ""))
if (qt_env %in% c("1", "TRUE", "YES", "ON")) QUICK_TEST_MODE <- TRUE

N_TRIALS <- 35
nt_env <- as.integer(Sys.getenv("R_UPC_N_TRIALS", unset = NA))
if (!is.na(nt_env) && nt_env >= 1) N_TRIALS <- nt_env

OUTPUT_DIR <- file.path(SCRIPT_DIR, "outputs")
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)
timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

log_file_conn <- file(file.path(OUTPUT_DIR, paste0("run_log_", timestamp, ".txt")), open = "wt")
sink(log_file_conn, split = TRUE)
on.exit({ sink(); close(log_file_conn) }, add = TRUE)
message("Live log saved to: outputs/run_log_", timestamp, ".txt")

if (QUICK_TEST_MODE) {
  message("\n=== QUICK TEST MODE (smoke test, small subset) ===\n")
  USE_REAL_DATA <- TRUE
  MAX_OFFERINGS <- 30
  MAX_NODES <- 1500
  MAX_ROOMS_PER_OFFERING <- 3
  MAX_STARTS_PER_DAY <- 3
  N_TRIALS <- 3
  GA_PARAMS <- list(
    pop_size = 20,
    generations = 8,
    crossover_rate = 0.85,
    mutation_rate = 0.20,
    elitism_frac = 0.10,
    tournament_size = 3,
    verbose = FALSE
  )
  ACO_PARAMS <- list(
    n_ants = 8,
    n_iterations = 10,
    alpha = 1,
    beta = 2,
    rho_local = 0.1,
    rho_global = 0.2,
    tau0 = 1.0,
    q0 = 0.9
  )
  SA_PARAMS <- list(
    T0_factor = 2,
    alpha_cool = 0.95,
    n_iter_temp = 15,
    total_cooling_steps = 20,
    reheat_interval = 10
  )
} else {
  message("\n=== FULL EXECUTION MODE (", N_TRIALS, " trials, full data) ===\n")
  USE_REAL_DATA <- TRUE
  MAX_OFFERINGS <- Inf
  MAX_NODES <- 6000
  MAX_ROOMS_PER_OFFERING <- 4
  MAX_STARTS_PER_DAY <- 4
  if (is.na(nt_env) || nt_env < 1) N_TRIALS <- 5
  GA_PARAMS <- list(
    pop_size = 30,
    generations = 40,
    crossover_rate = 0.88,
    mutation_rate = 0.18,
    elitism_frac = 0.10,
    tournament_size = 3,
    verbose = FALSE
  )
  ACO_PARAMS <- list(
    n_ants = 10,
    n_iterations = 20,
    alpha = 1,
    beta = 2,
    rho_local = 0.10,
    rho_global = 0.20,
    tau0 = 1.0,
    q0 = 0.90
  )
  SA_PARAMS <- list(
    T0_factor = 2.5,
    alpha_cool = 0.985,
    n_iter_temp = 20,
    total_cooling_steps = 40,
    reheat_interval = 15
  )
}

cat("===========================================================\n")
cat("  TUPC Graph-Based UCTP — Optimization Framework\n")
cat("  Trials per algorithm:", N_TRIALS, "\n")
cat("  Mode:", ifelse(QUICK_TEST_MODE, "QUICK TEST", "FULL EXECUTION"), "\n")
cat("===========================================================\n\n")

###############################################################################
# STEP 1: Load & prepare data
###############################################################################

message("Step 1: Loading data...")
data <- read_tupc_data(use_real_data = USE_REAL_DATA)
message("Data loaded successfully.")
message("  Offerings: ", nrow(data$offerings))
message("  Sections:  ", nrow(data$sections))
message("  Faculty:   ", nrow(data$faculty))
message("  Rooms:     ", nrow(data$rooms))
message("  Courses:   ", nrow(data$courses))

if (is.finite(MAX_OFFERINGS) && MAX_OFFERINGS < nrow(data$offerings)) {
  message("Subsampling offerings to ", MAX_OFFERINGS, " (seed 42)")
  set.seed(42)
  keep_oids <- sample(unique(data$offerings$offering_id),
                      min(MAX_OFFERINGS, length(unique(data$offerings$offering_id))))
  data$offerings <- data$offerings %>% filter(offering_id %in% keep_oids)
  data$offerings$offering_id <- seq_len(nrow(data$offerings))
}

###############################################################################
# STEP 2: Build graph (candidate nodes + adjacency)
###############################################################################

message("\nStep 2: Building candidate nodes...")
nodes <- build_candidate_nodes(
  data,
  max_nodes = MAX_NODES,
  sample_seed = 2025,
  max_rooms_per_offering = MAX_ROOMS_PER_OFFERING,
  max_starts_per_day = MAX_STARTS_PER_DAY
)
message("Candidate nodes: ", nrow(nodes))

message("\nStep 3: Building adjacency matrix...")
# Compatibility matrices are very dense for this model; sparse conversion is
# slower and consumes more memory than the ordinary dense representation.
use_sparse <- FALSE
adjacency <- build_adjacency_matrix(nodes, verbose = TRUE, use_sparse = use_sparse)

###############################################################################
# STEP 4: Sanity check with greedy baseline
###############################################################################

message("\nStep 4: Running greedy baseline for sanity check...")
set.seed(123)
weight_vec <- precompute_node_weights(nodes, data)
dg_greedy <- DynamicGraph$new(nodes, adjacency, data)
invisible(schedule_greedy_construct(dg_greedy, weight_vec))
greedy_fit <- calculate_fitness(dg_greedy, data, verbose = FALSE)

message("Greedy Baseline Summary:")
message("  Fitness F:    ", round(greedy_fit$F, 2))
message("  N Selected:   ", greedy_fit$n_selected)
message("  Coverage:     ", round(greedy_fit$coverage_ratio * 100, 1), "%")
message("  Vertices Sum: ", round(greedy_fit$sum_vertex_weights, 2))
message("  Sched Pen:    ", greedy_fit$schedule_penalty)
message("  Cov Pen:      ", greedy_fit$coverage_penalty)
message("  WL Pen:       ", greedy_fit$workload_penalty)

saveRDS(list(
  nodes = nodes,
  adjacency = adjacency,
  data = data,
  greedy_fitness = greedy_fit
), file = file.path(OUTPUT_DIR, paste0("graph_setup_", timestamp, ".rds")))

###############################################################################
# STEP 5: Run trials per algorithm
###############################################################################

message("\nStep 5: Running optimization trials (n=", N_TRIALS, " per algorithm)...")
cat("-----------------------------------------------------------\n")

run_trial_safe <- function(algo_name, runner_fun, ...) {
  result <- tryCatch({
    start <- proc.time()
    res <- runner_fun(...)
    elapsed <- as.numeric((proc.time() - start)["elapsed"])
    list(
      success = TRUE,
      fitness = res$fitness,
      time_sec = elapsed,
      raw_result = res,
      error = NA_character_
    )
  }, error = function(e) {
    list(
      success = FALSE,
      fitness = NA_real_,
      time_sec = NA_real_,
      raw_result = NULL,
      error = conditionMessage(e)
    )
  })
  result
}

trials_results <- list(GA = list(), ACO = list(), SA = list())
trials_summary <- tibble(
  trial = integer(0),
  algorithm = character(0),
  fitness = numeric(0),
  time_sec = numeric(0),
  success = logical(0),
  error = character(0)
)

for (trial in 1:N_TRIALS) {
  cat(sprintf("\n>>> Trial %2d / %d  [%s]\n", trial, N_TRIALS, Sys.time()))

  seed_offset <- trial * 1000

  # --- GA ---
  ga_params_trial <- c(GA_PARAMS, list(seed = 42 + seed_offset))
  res_ga <- run_trial_safe("GA", run_GA, nodes, adjacency, data, ga_params_trial)
  trials_results$GA[[trial]] <- res_ga
  trials_summary <- bind_rows(trials_summary, tibble(
    trial = trial, algorithm = "GA",
    fitness = res_ga$fitness, time_sec = res_ga$time_sec,
    success = res_ga$success, error = ifelse(is.na(res_ga$error), "", res_ga$error)
  ))
  cat(sprintf("  GA: F=%s  t=%ss  %s\n",
              ifelse(is.na(res_ga$fitness), "NA", sprintf("%.2f", res_ga$fitness)),
              ifelse(is.na(res_ga$time_sec), "NA", sprintf("%.1f", res_ga$time_sec)),
              ifelse(res_ga$success, "OK", paste("ERR:", substr(res_ga$error, 1, 50)))))

  # --- ACO ---
  res_aco <- run_trial_safe("ACO", run_ACO, nodes, adjacency, data, ACO_PARAMS)
  trials_results$ACO[[trial]] <- res_aco
  trials_summary <- bind_rows(trials_summary, tibble(
    trial = trial, algorithm = "ACO",
    fitness = res_aco$fitness, time_sec = res_aco$time_sec,
    success = res_aco$success, error = ifelse(is.na(res_aco$error), "", res_aco$error)
  ))
  cat(sprintf("  ACO: F=%s  t=%ss  %s\n",
              ifelse(is.na(res_aco$fitness), "NA", sprintf("%.2f", res_aco$fitness)),
              ifelse(is.na(res_aco$time_sec), "NA", sprintf("%.1f", res_aco$time_sec)),
              ifelse(res_aco$success, "OK", paste("ERR:", substr(res_aco$error, 1, 50)))))

  # --- SA ---
  res_sa <- run_trial_safe("SA", run_SA, nodes, adjacency, data, SA_PARAMS)
  trials_results$SA[[trial]] <- res_sa
  trials_summary <- bind_rows(trials_summary, tibble(
    trial = trial, algorithm = "SA",
    fitness = res_sa$fitness, time_sec = res_sa$time_sec,
    success = res_sa$success, error = ifelse(is.na(res_sa$error), "", res_sa$error)
  ))
  cat(sprintf("  SA:  F=%s  t=%ss  %s\n",
              ifelse(is.na(res_sa$fitness), "NA", sprintf("%.2f", res_sa$fitness)),
              ifelse(is.na(res_sa$time_sec), "NA", sprintf("%.1f", res_sa$time_sec)),
              ifelse(res_sa$success, "OK", paste("ERR:", substr(res_sa$error, 1, 50)))))

  if (trial %% 5 == 0 || trial == N_TRIALS) {
    saveRDS(list(
      trials_summary = trials_summary,
      trials_results = trials_results,
      params = list(GA = GA_PARAMS, ACO = ACO_PARAMS, SA = SA_PARAMS,
                    N_TRIALS = N_TRIALS, QUICK = QUICK_TEST_MODE),
      greedy = greedy_fit,
      nodes_info = list(n = nrow(nodes), graph_sparse = use_sparse)
    ), file = file.path(OUTPUT_DIR, paste0("trials_checkpoint_", trial, "_", timestamp, ".rds")))
  }
}

write.csv(trials_summary,
          file = file.path(OUTPUT_DIR, paste0("trials_summary_", timestamp, ".csv")),
          row.names = FALSE)

###############################################################################
# STEP 6: Descriptive statistics per algorithm
###############################################################################

message("\n\n===========================================================")
message("  DESCRIPTIVE STATISTICS (Fitness Scores)")
message("===========================================================")

descriptive <- trials_summary %>%
  filter(success == TRUE) %>%
  group_by(algorithm) %>%
  summarise(
    n = n(),
    mean_F = mean(fitness, na.rm = TRUE),
    sd_F = sd(fitness, na.rm = TRUE),
    median_F = median(fitness, na.rm = TRUE),
    min_F = min(fitness, na.rm = TRUE),
    max_F = max(fitness, na.rm = TRUE),
    se_F = sd_F / sqrt(n),
    ci95_low = mean_F - qt(0.975, pmax(1, n - 1)) * se_F,
    ci95_high = mean_F + qt(0.975, pmax(1, n - 1)) * se_F,
    mean_time = mean(time_sec, na.rm = TRUE),
    sd_time = sd(time_sec, na.rm = TRUE),
    total_time = sum(time_sec, na.rm = TRUE),
    .groups = "drop"
  )

print(descriptive %>% as.data.frame(), digits = 3)

write.csv(descriptive,
          file = file.path(OUTPUT_DIR, paste0("descriptive_stats_", timestamp, ".csv")),
          row.names = FALSE)

message("\nGreedy Baseline F: ", round(greedy_fit$F, 2))

###############################################################################
# STEP 7: Hypothesis Testing — ANOVA & Kruskal-Wallis
# H0: There is no significant difference between GA, ACO, and SA fitness means.
# H1: At least one algorithm differs significantly (α = 0.05).
###############################################################################

message("\n\n===========================================================")
message("  HYPOTHESIS TESTING — Fitness Score Comparison")
message("  H0: μ_GA = μ_ACO = μ_SA   (α = 0.05)")
message("===========================================================\n")

fit_df <- trials_summary %>%
  filter(success == TRUE, !is.na(fitness)) %>%
  mutate(algorithm = factor(algorithm, levels = c("GA", "ACO", "SA")))

anova_result <- NULL
kw_result <- NULL
posthoc_tukey <- NULL
posthoc_dunn <- NULL

algorithms_present <- length(unique(fit_df$algorithm))

if (nrow(fit_df) >= 6 && algorithms_present >= 2) {
  anova_model <- aov(fitness ~ algorithm, data = fit_df)
  anova_result <- summary(anova_model)
  message("=== One-Way ANOVA ===")
  print(anova_result)
  p_anova <- anova_result[[1]][["Pr(>F)"]][1]
  message("\nANOVA p-value: ", round(p_anova, 6))
  if (p_anova < 0.05) {
    message("→ REJECT H0: Significant difference found between algorithms (p < 0.05).")
  } else {
    message("→ FAIL TO REJECT H0: No significant difference (p >= 0.05).")
  }

  if (algorithms_present >= 2 && requireNamespace("stats", quietly = TRUE)) {
    posthoc_tukey <- tryCatch({
      TukeyHSD(anova_model)
    }, error = function(e) NULL)
    if (!is.null(posthoc_tukey)) {
      message("\n=== Tukey HSD Post-hoc (95% family-wise confidence) ===")
      print(posthoc_tukey)
    }
  }

  message("\n=== Normality Check (Shapiro-Wilk per group) ===")
  for (alg in unique(fit_df$algorithm)) {
    vals <- fit_df$fitness[fit_df$algorithm == alg]
    if (length(vals) >= 3) {
      sw <- tryCatch(shapiro.test(vals), error = function(e) NULL)
      if (!is.null(sw)) {
        message(sprintf("  %s: W=%.4f, p=%.4f %s",
                        alg, sw$statistic, sw$p.value,
                        ifelse(sw$p.value < 0.05, "*NON-NORMAL*", "normal")))
      }
    }
  }

  message("\n=== Homogeneity of Variances (Levene/Bartlett) ===")
  bart <- tryCatch({
    if (algorithms_present >= 2) bartlett.test(fitness ~ algorithm, data = fit_df) else NULL
  }, error = function(e) NULL)
  if (!is.null(bart)) {
    message(sprintf("  Bartlett K²=%.4f, p=%.4f %s",
                    bart$statistic, bart$p.value,
                    ifelse(bart$p.value < 0.05, "*HETEROSCEDASTIC*", "homoscedastic")))
  }

  message("\n=== Kruskal-Wallis Rank Sum Test (non-parametric) ===")
  kw_result <- kruskal.test(fitness ~ algorithm, data = fit_df)
  print(kw_result)
  p_kw <- kw_result$p.value
  message("\nKruskal-Wallis p-value: ", round(p_kw, 6))
  if (p_kw < 0.05) {
    message("→ REJECT H0: Significant difference in distributions (p < 0.05).")
  } else {
    message("→ FAIL TO REJECT H0: No significant difference (p >= 0.05).")
  }

  if (p_kw < 0.05 && algorithms_present >= 3) {
    message("\n=== Pairwise Wilcoxon Rank-Sum (Bonferroni correction) ===")
    alg_pairs <- combn(levels(fit_df$algorithm), 2, simplify = FALSE)
    for (pr in alg_pairs) {
      a1 <- pr[1]; a2 <- pr[2]
      v1 <- fit_df$fitness[fit_df$algorithm == a1]
      v2 <- fit_df$fitness[fit_df$algorithm == a2]
      if (length(v1) >= 2 && length(v2) >= 2) {
        wt <- wilcox.test(v1, v2, exact = FALSE, correct = TRUE)
        p_adj <- pmin(1, wt$p.value * length(alg_pairs))
        direction <- ifelse(median(v1) > median(v2), paste0(a1, ">", a2),
                            ifelse(median(v1) < median(v2), paste0(a2, ">", a1), "tie"))
        message(sprintf("  %s vs %s: W=%.0f, p=%.4f, p_adj=%.4f  [%s] %s",
                        a1, a2, wt$statistic, wt$p.value, p_adj, direction,
                        ifelse(p_adj < 0.05, "*", "ns")))
      }
    }
  }
} else {
  message("Not enough successful trials for formal hypothesis testing (n=",
          nrow(fit_df), ").")
}

###############################################################################
# STEP 8: Computation time comparison
###############################################################################

message("\n\n===========================================================")
message("  COMPUTATION TIME COMPARISON (seconds)")
message("===========================================================")
time_desc <- trials_summary %>%
  filter(success == TRUE) %>%
  group_by(algorithm) %>%
  summarise(
    n = n(),
    mean_t = mean(time_sec, na.rm = TRUE),
    sd_t = sd(time_sec, na.rm = TRUE),
    median_t = median(time_sec, na.rm = TRUE),
    total_t = sum(time_sec, na.rm = TRUE),
    .groups = "drop"
  )
print(time_desc %>% as.data.frame(), digits = 3)

###############################################################################
# STEP 9: Visualizations
###############################################################################

message("\n\n===========================================================")
message("  GENERATING PLOTS")
message("===========================================================")

plot_list <- list()

fit_clean <- trials_summary %>% filter(success == TRUE, !is.na(fitness))

if (nrow(fit_clean) > 0) {
  p_box <- ggplot(fit_clean, aes(x = factor(algorithm, levels = c("GA", "ACO", "SA")),
                                 y = fitness, fill = algorithm)) +
    geom_boxplot(alpha = 0.7, outlier.colour = "red", outlier.shape = 16) +
    geom_jitter(width = 0.2, alpha = 0.5) +
    labs(title = "Fitness Score Distribution per Algorithm",
         subtitle = paste0(N_TRIALS, " trials each | TUPC SY 2025-2026 1st Sem"),
         x = "Algorithm", y = "Fitness Score F", fill = "Algorithm") +
    theme_minimal(base_size = 12) +
    scale_fill_brewer(palette = "Set2")
  ggsave(file.path(OUTPUT_DIR, paste0("boxplot_fitness_", timestamp, ".png")),
         plot = p_box, width = 8, height = 6, dpi = 150)
  plot_list$boxplot_fitness <- p_box

  p_violin <- ggplot(fit_clean, aes(x = factor(algorithm, levels = c("GA", "ACO", "SA")),
                                    y = fitness, fill = algorithm)) +
    geom_violin(alpha = 0.6) +
    geom_boxplot(width = 0.15, fill = "white") +
    labs(title = "Fitness Score Density per Algorithm",
         x = "Algorithm", y = "Fitness Score F", fill = "Algorithm") +
    theme_minimal(base_size = 12) +
    scale_fill_brewer(palette = "Set2")
  ggsave(file.path(OUTPUT_DIR, paste0("violin_fitness_", timestamp, ".png")),
         plot = p_violin, width = 8, height = 6, dpi = 150)
  plot_list$violin_fitness <- p_violin

  p_time <- ggplot(fit_clean, aes(x = factor(algorithm, levels = c("GA", "ACO", "SA")),
                                  y = time_sec, fill = algorithm)) +
    geom_col(alpha = 0.7, position = position_dodge()) +
    stat_summary(fun.data = "mean_se", geom = "errorbar", width = 0.2) +
    labs(title = "Mean Computation Time per Algorithm",
         subtitle = "Mean ± SE across trials",
         x = "Algorithm", y = "Time (seconds)", fill = "Algorithm") +
    theme_minimal(base_size = 12) +
    scale_fill_brewer(palette = "Set2")
  ggsave(file.path(OUTPUT_DIR, paste0("barplot_time_", timestamp, ".png")),
         plot = p_time, width = 8, height = 6, dpi = 150)
  plot_list$barplot_time <- p_time

  p_scatter <- ggplot(fit_clean, aes(x = time_sec, y = fitness, color = algorithm,
                                     shape = algorithm)) +
    geom_point(size = 3, alpha = 0.7) +
    geom_smooth(method = "lm", se = FALSE, alpha = 0.5) +
    labs(title = "Fitness vs Computation Time",
         subtitle = "Each point = 1 trial",
         x = "Time (seconds)", y = "Fitness Score F", color = "Algorithm", shape = "Algorithm") +
    theme_minimal(base_size = 12) +
    scale_color_brewer(palette = "Set1")
  ggsave(file.path(OUTPUT_DIR, paste0("scatter_fit_time_", timestamp, ".png")),
         plot = p_scatter, width = 8, height = 6, dpi = 150)
  plot_list$scatter_fit_time <- p_scatter
}

###############################################################################
# STEP 10: Save best overall schedule
###############################################################################

message("\n\n===========================================================")
message("  BEST OVERALL SOLUTION")
message("===========================================================")

best_overall <- list(fitness = -Inf, algorithm = NA_character_, trial = NA_integer_, raw = NULL)
for (alg in names(trials_results)) {
  for (t in seq_along(trials_results[[alg]])) {
    res <- trials_results[[alg]][[t]]
    if (res$success && !is.na(res$fitness) && res$fitness > best_overall$fitness) {
      best_overall$fitness <- res$fitness
      best_overall$algorithm <- alg
      best_overall$trial <- t
      best_overall$raw <- res$raw_result
    }
  }
}
message(sprintf("Best: %s (trial %d) with F=%.2f",
                best_overall$algorithm, best_overall$trial, best_overall$fitness))

if (!is.null(best_overall$raw)) {
  best_schedule_df <- NULL
  best_node_ids <- NULL

  raw_sched <- best_overall$raw$schedule
  if (!is.null(raw_sched)) {
    if (is.data.frame(raw_sched) && nrow(raw_sched) > 0) {
      best_schedule_df <- raw_sched
    } else if (is.vector(raw_sched) && length(raw_sched) > 0 && is.numeric(raw_sched)) {
      best_node_ids <- as.integer(raw_sched)
    }
  }

  if (is.null(best_node_ids) && "best_solution_nodes" %in% names(best_overall$raw)) {
    raw_nodes <- best_overall$raw$best_solution_nodes
    if (is.vector(raw_nodes) && length(raw_nodes) > 0 && is.numeric(raw_nodes)) {
      best_node_ids <- as.integer(raw_nodes)
    }
  }

  if (is.null(best_schedule_df) && !is.null(best_node_ids)) {
    dg_temp <- DynamicGraph$new(nodes, adjacency, data)
    for (nid in best_node_ids) dg_temp$select_node(nid)
    best_schedule_df <- dg_temp$selected_nodes_df
  }

  if (!is.null(best_schedule_df) && is.data.frame(best_schedule_df) && nrow(best_schedule_df) > 0) {
    cols_to_write <- names(best_schedule_df)
    cols_to_write <- cols_to_write[cols_to_write != "time_slot_ids"]
    write.csv(best_schedule_df %>% select(all_of(cols_to_write)),
              file = file.path(OUTPUT_DIR, paste0("best_schedule_", timestamp, ".csv")),
              row.names = FALSE)
    best_fit_detail <- NULL
    if ("fitness_detail" %in% names(best_overall$raw)) {
      best_fit_detail <- best_overall$raw$fitness_detail
    } else if ("fit_detail" %in% names(best_overall$raw)) {
      best_fit_detail <- best_overall$raw$fit_detail
    } else {
      dg_temp <- DynamicGraph$new(nodes, adjacency, data)
      for (nid in best_schedule_df$node_id) dg_temp$select_node(nid)
      best_fit_detail <- calculate_fitness(dg_temp, data)
    }
    if (!is.null(best_fit_detail)) {
      message("\nBest Solution Fitness Breakdown:")
      message(sprintf("  F = %.2f", best_fit_detail$F))
      message(sprintf("  Σ Vertex Weights: %.2f", best_fit_detail$sum_vertex_weights))
      message(sprintf("  - Schedule Penalties: %d", best_fit_detail$schedule_penalty))
      message(sprintf("  - Coverage Penalty: %d (%.1f%% covered)",
                      best_fit_detail$coverage_penalty,
                      best_fit_detail$coverage_ratio * 100))
      message(sprintf("  - Workload Penalty: %d", best_fit_detail$workload_penalty))
      message(sprintf("  Nodes Selected: %d", best_fit_detail$n_selected))
      if (length(best_fit_detail$schedule_penalty_details) > 0) {
        message("  Penalty Details (top 10):")
        for (pd in head(best_fit_detail$schedule_penalty_details, 10)) {
          message("    ", pd)
        }
      }
    }
  }
}

# GA schedule export is handled by ga_scheduler.R.
# Run:  Rscript --vanilla ga_scheduler.R

###############################################################################
# FINAL: Save full results
###############################################################################

final_output <- list(
  timestamp = timestamp,
  quick_mode = QUICK_TEST_MODE,
  n_trials = N_TRIALS,
  parameters = list(GA = GA_PARAMS, ACO = ACO_PARAMS, SA = SA_PARAMS),
  graph_info = list(
    n_nodes = nrow(nodes),
    n_offerings = nrow(data$offerings),
    sparse = use_sparse
  ),
  greedy_baseline = greedy_fit,
  trials_summary = trials_summary,
  descriptive = descriptive,
  hypothesis = list(
    anova = anova_result,
    kruskal_wallis = kw_result,
    tukey = posthoc_tukey
  ),
  best_solution = best_overall,
  plots = plot_list
)

saveRDS(final_output,
        file = file.path(OUTPUT_DIR, paste0("FINAL_RESULTS_", timestamp, ".rds")))

message("\n\n===========================================================")
message("  EXECUTION COMPLETE")
message("  All outputs saved to: ", OUTPUT_DIR)
message("  Timestamp: ", timestamp)
message("===========================================================")
cat("\nDone.\n")
