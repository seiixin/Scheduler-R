###############################################################################
# 09_generate_verified_schedule.R -- production schedule generation/check
###############################################################################

source("01_data_loader.R")
source("02_graph_construction.R")
source("03_dynamic_node_selection.R")
source("04_fitness_calculation.R")

OUTPUT_DIR <- file.path(getwd(), "outputs")
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

data <- read_tupc_data(use_real_data = TRUE)
nodes <- build_candidate_nodes(
  data, max_nodes = 6000, sample_seed = 2025,
  max_rooms_per_offering = 4, max_starts_per_day = 4
)
adjacency <- build_adjacency_matrix(nodes, verbose = TRUE, use_sparse = FALSE)
# Coverage construction does not need preference scoring; using base weights
# keeps production verification bounded instead of scoring every graph vertex.
weights <- nodes$base_weight

# Different priority tie-breaks are inexpensive compared with rebuilding the
# graph and can avoid a locally greedy dead end.  Coverage is the primary
# acceptance criterion, then fitness selects among complete schedules.
best_dg <- NULL
best_cov <- NULL
for (attempt in seq_len(5L)) {
  set.seed(2025L + attempt)
  trial_weights <- weights + stats::rnorm(length(weights), sd = if (attempt == 1L) 0 else 25)
  dg <- DynamicGraph$new(nodes, adjacency, data)
  schedule_greedy_construct(dg, trial_weights)
  cov <- dg$get_coverage()
  if (is.null(best_cov) || cov$coverage_ratio > best_cov$coverage_ratio ||
      (cov$coverage_ratio == best_cov$coverage_ratio &&
       cov$missing_meetings < best_cov$missing_meetings)) {
    best_dg <- dg
    best_cov <- cov
  }
  if (cov$missing_meetings == 0L) break
}

schedule <- best_dg$selected_nodes_df
coverage <- data.frame(
  offering_id = data$offerings$offering_id,
  course_code = data$offerings$course_code,
  section_id = data$offerings$section_id,
  faculty_id = data$offerings$faculty_id,
  required_meetings = vapply(data$offerings$meeting_patterns,
                             function(x) max(1L, length(unlist(x))), integer(1)),
  scheduled_meetings = vapply(as.character(data$offerings$offering_id),
                              function(x) best_dg$offerings_coverage[[x]], numeric(1))
)
coverage$missing_meetings <- pmax(coverage$required_meetings - coverage$scheduled_meetings, 0L)

# Independently confirm that no selected node pair violates adjacency.
selected <- best_dg$selected_ids
has_conflict <- length(selected) > 1L && any(adjacency[selected, selected][upper.tri(adjacency[selected, selected])] == 0L)
verification <- data.frame(
  generated_at = as.character(Sys.time()),
  offerings = nrow(data$offerings),
  required_meetings = sum(coverage$required_meetings),
  scheduled_meetings = nrow(schedule),
  missing_meetings = sum(coverage$missing_meetings),
  fully_covered_offerings = sum(coverage$missing_meetings == 0L),
  conflicting_selected_pairs = has_conflict,
  stringsAsFactors = FALSE
)

write.csv(schedule[, setdiff(names(schedule), "time_slot_ids"), drop = FALSE],
          file.path(OUTPUT_DIR, paste0("final_verified_schedule_", stamp, ".csv")),
          row.names = FALSE)
write.csv(coverage, file.path(OUTPUT_DIR, paste0("final_coverage_", stamp, ".csv")), row.names = FALSE)
write.csv(verification, file.path(OUTPUT_DIR, paste0("final_verification_", stamp, ".csv")), row.names = FALSE)
saveRDS(list(data = data, nodes = nodes, selected_ids = selected,
             schedule = schedule, coverage = coverage, verification = verification),
        file.path(OUTPUT_DIR, paste0("final_verified_schedule_", stamp, ".rds")))

print(verification)
if (verification$missing_meetings != 0L || verification$fully_covered_offerings != verification$offerings || has_conflict) {
  stop("Verification failed; no complete conflict-free schedule was found.")
}
message("Verified schedule exported to outputs/.")
