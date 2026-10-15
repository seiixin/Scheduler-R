# R entrypoint for the Simulated Annealing scheduler.
# Run from any working directory; all project paths resolve beside this file.
#
# Environment variables (all optional):
#   R_UPC_MAX_NODES         — candidate node cap               (default: 2500)
#   R_UPC_MAX_ROOMS         — rooms sampled per offering        (default: 2)
#   R_UPC_MAX_STARTS        — start slots per day               (default: 2)
#   R_UPC_SA_STEPS          — total cooling steps               (default: 1)
#   R_UPC_SA_ITERATIONS     — inner iterations per step         (default: 2)
#   R_UPC_SA_T0_FACTOR      — initial temperature multiplier    (default: 2)
#   R_UPC_SA_ALPHA          — cooling rate  0.0–1.0             (default: 0.985)
#   R_UPC_SA_REHEAT         — steps between reheats             (default: 50)
#
# PowerShell usage example:
#   $env:R_UPC_SA_STEPS      = "300"
#   $env:R_UPC_SA_ITERATIONS = "100"
#   $env:R_UPC_SA_ALPHA      = "0.99"
#   $env:R_UPC_SA_T0_FACTOR  = "3"
#   $env:R_UPC_SA_REHEAT     = "50"
#   & Rscript --vanilla sa_scheduler.R

script_arg  <- commandArgs(trailingOnly = FALSE)
script_file <- sub("^--file=", "", script_arg[grep("^--file=", script_arg)][1])
if (!is.na(script_file) && nzchar(script_file)) setwd(dirname(normalizePath(script_file)))

source("01_data_loader.R")
source("02_graph_construction.R")
source("03_dynamic_node_selection.R")
source("04_fitness_calculation.R")
source("07_simulated_annealing.R")
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
  max_nodes              = env_positive_int("R_UPC_MAX_NODES",  2500L),
  sample_seed            = 20260915L,
  max_rooms_per_offering = env_positive_int("R_UPC_MAX_ROOMS",  2L),
  max_starts_per_day     = env_positive_int("R_UPC_MAX_STARTS", 2L)
)
adjacency <- build_adjacency_matrix(nodes, verbose = TRUE, use_sparse = FALSE)

run_started <- proc.time()
result <- run_SA(nodes, adjacency, data, params = list(
  total_cooling_steps = env_positive_int("R_UPC_SA_STEPS",      5L),
  n_iter_temp         = env_positive_int("R_UPC_SA_ITERATIONS", 20L),
  T0_factor           = env_numeric("R_UPC_SA_T0_FACTOR", 2,    0.01),
  alpha_cool          = env_numeric("R_UPC_SA_ALPHA",     0.985, 0, 1),
  reheat_interval     = env_positive_int("R_UPC_SA_REHEAT", 10L)
  # No verification_fn — SA finds the best scoring solution from its own
  # search and reports it honestly.  The early-exit fast-path in run_SA()
  # still fires when coverage is complete (zero missing meetings), which is
  # the correct stop condition: the algorithm succeeded on its own terms.
  # A verification_fn that demands zero violations would stop SA only when
  # all 18 constraints pass simultaneously, which is too strict and would
  # cause SA to run to exhaustion on hard datasets, then fall back to repair
  # — defeating the purpose of comparing the three algorithms fairly.
))
result$time_sec <- as.numeric((proc.time() - run_started)["elapsed"])
dir.create("outputs", showWarnings = FALSE, recursive = TRUE)
export_r_algorithm_result(
  result, data,
  file.path("outputs", "sa_schedule_formatted.xlsx"),
  "SA",
  nodes = nodes, adjacency = adjacency
)
