# R entrypoint for the Genetic Algorithm scheduler.
# Run from any working directory; all project paths resolve beside this file.
#
# Environment variables (all optional):
#   R_UPC_MAX_NODES         — candidate node cap               (default: 1050)
#   R_UPC_MAX_ROOMS         — rooms sampled per offering        (default: 1)
#   R_UPC_MAX_STARTS        — start slots per day               (default: 1)
#   R_UPC_GA_POP            — population size                   (default: 8)
#   R_UPC_GA_GENERATIONS    — number of generations             (default: 4)
#   R_UPC_GA_CROSSOVER      — crossover rate       0.0–1.0      (default: 0.88)
#   R_UPC_GA_MUTATION       — mutation rate        0.0–1.0      (default: 0.18)
#   R_UPC_GA_ELITISM        — elitism fraction     0.0–1.0      (default: 0.12)
#   R_UPC_GA_TOURNAMENT     — tournament size                   (default: 3)
#   R_UPC_GA_SEED           — RNG seed                          (default: 20260915)
#
# PowerShell usage example:
#   $env:R_UPC_GA_POP         = "50"
#   $env:R_UPC_GA_GENERATIONS = "100"
#   $env:R_UPC_GA_CROSSOVER   = "0.85"
#   $env:R_UPC_GA_MUTATION    = "0.20"
#   $env:R_UPC_GA_ELITISM     = "0.10"
#   $env:R_UPC_GA_TOURNAMENT  = "5"
#   & Rscript --vanilla ga_scheduler.R

script_arg  <- commandArgs(trailingOnly = FALSE)
script_file <- sub("^--file=", "", script_arg[grep("^--file=", script_arg)][1])
if (!is.na(script_file) && nzchar(script_file)) setwd(dirname(normalizePath(script_file)))

source("01_data_loader.R")
source("02_graph_construction.R")
source("03_dynamic_node_selection.R")
source("04_fitness_calculation.R")
source("05_genetic_algorithm.R")
source("r_scheduler_export_helpers.R")

env_positive_int <- function(name, default) {
  value <- suppressWarnings(as.integer(Sys.getenv(name, unset = "")))
  if (is.na(value) || value < 1L) default else value
}

env_numeric <- function(name, default, min_val = 0, max_val = Inf) {
  raw   <- Sys.getenv(name, unset = "")
  value <- suppressWarnings(as.numeric(raw))
  if (is.na(value) || nchar(raw) == 0L || value < min_val || value > max_val)
    default
  else
    value
}

data  <- read_tupc_data(use_real_data = TRUE, use_synthetic_if_missing = FALSE)
nodes <- build_candidate_nodes(
  data,
  max_nodes              = env_positive_int("R_UPC_MAX_NODES",  1050L),
  sample_seed            = env_positive_int("R_UPC_GA_SEED",    20260915L),
  max_rooms_per_offering = env_positive_int("R_UPC_MAX_ROOMS",  1L),
  max_starts_per_day     = env_positive_int("R_UPC_MAX_STARTS", 1L)
)
adjacency <- build_adjacency_matrix(nodes, verbose = TRUE, use_sparse = FALSE)

run_started <- proc.time()
result <- run_GA(nodes, adjacency, data, params = list(
  pop_size        = env_positive_int("R_UPC_GA_POP",         8L),
  generations     = env_positive_int("R_UPC_GA_GENERATIONS", 4L),
  crossover_rate  = env_numeric("R_UPC_GA_CROSSOVER",  0.88, 0, 1),
  mutation_rate   = env_numeric("R_UPC_GA_MUTATION",   0.18, 0, 1),
  elitism_frac    = env_numeric("R_UPC_GA_ELITISM",    0.12, 0, 1),
  tournament_size = env_positive_int("R_UPC_GA_TOURNAMENT", 3L),
  seed            = env_positive_int("R_UPC_GA_SEED",   20260915L),
  verbose         = TRUE
))
result$time_sec <- as.numeric((proc.time() - run_started)["elapsed"])
cat(sprintf("GA finished in %.1f seconds. Final fitness: %.2f\n", result$time_sec, result$fitness))
utils::flush.console()

if (is.numeric(result$schedule)) {
  dg_ga <- DynamicGraph$new(nodes, adjacency, data)
  for (nid in as.integer(result$schedule)) {
    if (dg_ga$active_remaining == 0L) break
    dg_ga$select_node(nid)
  }
  result$schedule <- dg_ga$get_expanded_selected_nodes()
}

dir.create("outputs", showWarnings = FALSE, recursive = TRUE)
cat("Exporting GA result to outputs/ga_schedule_formatted.xlsx ...\n")
utils::flush.console()
export_r_algorithm_result(
  result, data,
  file.path("outputs", "ga_schedule_formatted.xlsx"),
  "GA"
)
cat("Done. File written to outputs/ga_schedule_formatted.xlsx\n")
utils::flush.console()
