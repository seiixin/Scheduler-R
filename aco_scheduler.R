# R entrypoint for the Ant Colony Optimization scheduler.
# Run from any working directory; all project paths resolve beside this file.
#
# Environment variables (all optional):
#   R_UPC_MAX_NODES         — candidate node cap               (default: 2500)
#   R_UPC_MAX_ROOMS         — rooms sampled per offering        (default: 2)
#   R_UPC_MAX_STARTS        — start slots per day               (default: 2)
#   R_UPC_ACO_ANTS          — number of ants                    (default: 1)
#   R_UPC_ACO_ITERATIONS    — number of iterations              (default: 1)
#   R_UPC_ACO_ALPHA         — pheromone weight  > 0             (default: 1)
#   R_UPC_ACO_BETA          — heuristic weight  > 0             (default: 2)
#   R_UPC_ACO_RHO_LOCAL     — local evaporation rate  0.0–1.0   (default: 0.1)
#   R_UPC_ACO_RHO_GLOBAL    — global evaporation rate 0.0–1.0   (default: 0.2)
#   R_UPC_ACO_Q0            — exploitation probability 0.0–1.0  (default: 0.9)
#   R_UPC_ACO_TAU0          — initial pheromone level > 0       (default: 1.0)
#
# PowerShell usage example:
#   $env:R_UPC_ACO_ANTS       = "10"
#   $env:R_UPC_ACO_ITERATIONS = "50"
#   $env:R_UPC_ACO_ALPHA      = "1"
#   $env:R_UPC_ACO_BETA       = "3"
#   $env:R_UPC_ACO_RHO_GLOBAL = "0.15"
#   $env:R_UPC_ACO_Q0         = "0.85"
#   & Rscript --vanilla aco_scheduler.R

script_arg  <- commandArgs(trailingOnly = FALSE)
script_file <- sub("^--file=", "", script_arg[grep("^--file=", script_arg)][1])
if (!is.na(script_file) && nzchar(script_file)) setwd(dirname(normalizePath(script_file)))

source("01_data_loader.R")
source("02_graph_construction.R")
source("03_dynamic_node_selection.R")
source("04_fitness_calculation.R")
source("06_ant_colony.R")
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
result <- run_ACO(nodes, adjacency, data, params = list(
  n_ants       = env_positive_int("R_UPC_ACO_ANTS",       1L),
  n_iterations = env_positive_int("R_UPC_ACO_ITERATIONS", 1L),
  alpha        = env_numeric("R_UPC_ACO_ALPHA",      1.0,  0.01),
  beta         = env_numeric("R_UPC_ACO_BETA",       2.0,  0.01),
  rho_local    = env_numeric("R_UPC_ACO_RHO_LOCAL",  0.1,  0, 1),
  rho_global   = env_numeric("R_UPC_ACO_RHO_GLOBAL", 0.2,  0, 1),
  q0           = env_numeric("R_UPC_ACO_Q0",         0.9,  0, 1),
  tau0         = env_numeric("R_UPC_ACO_TAU0",       1.0,  0.001)
))
result$time_sec <- as.numeric((proc.time() - run_started)["elapsed"])
dir.create("outputs", showWarnings = FALSE, recursive = TRUE)
export_r_algorithm_result(
  result, data,
  file.path("outputs", "aco_schedule_formatted.xlsx"),
  "ACO"
)
