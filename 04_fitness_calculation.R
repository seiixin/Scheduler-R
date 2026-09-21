###############################################################################
# 04_fitness_calculation.R — Objective Function F = Σ Adjusted Weights
# Soft Constraint Bonuses + Penalties applied to Vertex-Weighted Graph
###############################################################################

if (!exists("require_packages")) source("03_dynamic_node_selection.R")
require_packages(c("dplyr", "tidyr"))

expand_raw_schedule_nodes <- function(schedule_nodes) {
  if (nrow(schedule_nodes) == 0L) return(schedule_nodes)
  has_member <- "member_offering_ids" %in% names(schedule_nodes) &&
    is.list(schedule_nodes$member_offering_ids)
  if (!has_member) return(schedule_nodes)
  need_expand <- any(vapply(schedule_nodes$member_offering_ids,
    function(v) length(v) > 1L, logical(1)))
  if (!need_expand) return(schedule_nodes)
  rows <- vector("list", nrow(schedule_nodes))
  for (i in seq_len(nrow(schedule_nodes))) {
    rep_row <- schedule_nodes[i, , drop = FALSE]
    m_offerings <- rep_row$member_offering_ids[[1]]
    m_sections  <- if ("member_section_ids" %in% names(rep_row) && is.list(rep_row$member_section_ids)) {
      rep_row$member_section_ids[[1]]
    } else rep(rep_row$section_id[1], length(m_offerings))
    m_student   <- if ("member_student_counts" %in% names(rep_row) && is.list(rep_row$member_student_counts)) {
      rep_row$member_student_counts[[1]]
    } else rep(rep_row$student_count[1], length(m_offerings))
    l <- length(m_offerings)
    if (l == 1L) { rows[[i]] <- rep_row; next }
    exp_row <- rep_row[rep(1L, l), , drop = FALSE]
    exp_row$offering_id <- m_offerings
    exp_row$section_id  <- m_sections
    if ("student_count" %in% names(exp_row)) exp_row$student_count <- m_student
    rownames(exp_row) <- NULL
    rows[[i]] <- exp_row
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

collapse_schedule_for_faculty_workload <- function(schedule_nodes) {
  if (nrow(schedule_nodes) == 0L) return(schedule_nodes)
  required <- c("faculty_id", "day", "hour_start", "hour_end", "duration")
  if (!all(required %in% names(schedule_nodes))) return(schedule_nodes)
  key <- paste(schedule_nodes$faculty_id, schedule_nodes$day,
               schedule_nodes$hour_start, schedule_nodes$hour_end, sep = "|")
  schedule_nodes[!duplicated(key), required, drop = FALSE]
}

node_member_section_ids <- function(node) {
  if ("member_section_ids" %in% names(node) && is.list(node$member_section_ids)) {
    v <- node$member_section_ids[[1]]
    if (length(v)) return(v)
  }
  as.character(node$section_id[1])
}

get_rank_multiplier <- function(academic_rank, has_admin_function = FALSE) {
  # Base-R lookup instead of dplyr::case_when — same semantics, zero overhead.
  base_mult <- switch(academic_rank,
    "Instructor"         = 1.0,
    "Assistant Professor" = 3.0,
    "Associate Professor" = 2.0,
    "Full Professor"     = 4.0,
    1.0
  )
  if (isTRUE(has_admin_function)) base_mult * 2 else base_mult
}

# ── Fast faculty lookup cache ─────────────────────────────────────────────────
# Built once per session by build_faculty_cache(); used by
# calculate_vertex_adjusted_weight_fast() and precompute_node_weights().
# The cache avoids a dplyr filter on data$faculty for every single node.
.faculty_cache <- NULL

build_faculty_cache <- function(data) {
  fac <- as.data.frame(data$faculty)
  n   <- nrow(fac)
  ids <- as.character(fac$faculty_id)

  ranks <- if ("academic_rank" %in% names(fac))
    as.character(fac$academic_rank) else rep("Instructor", n)
  admin <- if ("has_admin_function" %in% names(fac))
    as.logical(fac$has_admin_function) else rep(FALSE, n)

  rank_mult <- vapply(seq_len(n), function(i)
    get_rank_multiplier(ranks[i], admin[i]), numeric(1))

  pref_sec  <- fac$preferred_sections
  pref_days <- fac$preferred_days
  pref_hrs  <- fac$preferred_hours

  cache <- list(
    ids       = ids,
    rank_mult = setNames(rank_mult, ids),
    pref_sec  = setNames(pref_sec,  ids),
    pref_days = setNames(pref_days, ids),
    pref_hrs  = setNames(pref_hrs,  ids)
  )
  cache
}

# Returns cache, building it on first call per session.
get_faculty_cache <- function(data) {
  if (is.null(.faculty_cache) ||
      length(.faculty_cache$ids) != nrow(data$faculty)) {
    .faculty_cache <<- build_faculty_cache(data)
  }
  .faculty_cache
}

calculate_vertex_adjusted_weight <- function(node, data) {
  # Kept for backward compatibility — internally delegates to the cached path.
  base_w <- node$base_weight[1]
  fid    <- as.character(node$faculty_id[1])
  cache  <- get_faculty_cache(data)

  if (!(fid %in% cache$ids))
    return(list(weight = base_w, details = c("No faculty match"), penalty = 0, bonus = 0))

  rank_mult <- cache$rank_mult[[fid]]
  adjustments <- 0
  details <- character(0)

  member_sections <- node_member_section_ids(node)
  pref_sec  <- cache$pref_sec[[fid]]
  if (length(intersect(member_sections, pref_sec)) > 0L) {
    bonus <- (2 * rank_mult) * length(intersect(member_sections, pref_sec))
    adjustments <- adjustments + bonus
    details <- c(details, paste0("PrefSection(+", bonus, ")"))
  }

  pref_days <- cache$pref_days[[fid]]
  pref_hrs  <- cache$pref_hrs[[fid]]
  if (node$day[1] %in% pref_days && node$hour_start[1] %in% pref_hrs) {
    bonus <- 2 * rank_mult
    adjustments <- adjustments + bonus
    details <- c(details, paste0("PrefDayTime(+", bonus, ")"))
  }

  bad_hours <- c(7L, 16L, 17L, 18L, 19L, 20L)
  if (isTRUE(node$is_hard[1]) && !(node$hour_start[1] %in% bad_hours)) {
    adjustments <- adjustments + 5
    details <- c(details, "HardGoodTime(+5)")
  }

  list(weight = base_w + adjustments, details = details, penalty = 0, bonus = adjustments)
}

# ── Vectorised node-weight computation ───────────────────────────────────────
# Replaces the per-row loop + per-row dplyr filter in the original.
# Called by run_SA, run_GA, run_ACO once per run, and once per rebuild in SA.
precompute_node_weights <- function(nodes, data) {
  cache     <- get_faculty_cache(data)
  n         <- nrow(nodes)
  base_w    <- as.integer(nodes$base_weight)
  fid_chr   <- as.character(nodes$faculty_id)
  day_chr   <- as.character(nodes$day)
  hst_int   <- as.integer(nodes$hour_start)
  is_hard   <- as.logical(nodes$is_hard)
  bad_hours <- c(7L, 16L, 17L, 18L, 19L, 20L)

  # Pre-fetch rank_mult vector aligned to nodes
  rank_mult_vec <- vapply(fid_chr, function(fid) {
    v <- cache$rank_mult[[fid]]
    if (is.null(v)) 1.0 else v
  }, numeric(1))

  # Preferred-section bonus: check per-node whether any member section
  # matches the faculty preference list.
  has_member <- "member_section_ids" %in% names(nodes) && is.list(nodes$member_section_ids)
  pref_sec_bonus <- vapply(seq_len(n), function(i) {
    fid <- fid_chr[i]
    ps  <- cache$pref_sec[[fid]]
    if (is.null(ps) || length(ps) == 0L) return(0)
    secs <- if (has_member) {
      v <- nodes$member_section_ids[[i]]
      if (length(v)) as.character(v) else as.character(nodes$section_id[i])
    } else as.character(nodes$section_id[i])
    n_match <- length(intersect(secs, ps))
    if (n_match == 0L) 0 else (2 * rank_mult_vec[i]) * n_match
  }, numeric(1))

  # Preferred day+time bonus: vectorised over nodes
  pref_dt_bonus <- vapply(seq_len(n), function(i) {
    fid <- fid_chr[i]
    pd  <- cache$pref_days[[fid]]
    ph  <- cache$pref_hrs[[fid]]
    if (is.null(pd) || is.null(ph)) return(0)
    if (day_chr[i] %in% pd && hst_int[i] %in% ph) 2 * rank_mult_vec[i] else 0
  }, numeric(1))

  # Hard-course good-time bonus: fully vectorised
  hard_bonus <- ifelse(is_hard & !(hst_int %in% bad_hours), 5, 0)

  as.numeric(base_w + pref_sec_bonus + pref_dt_bonus + hard_bonus)
}

# ── calculate_schedule_penalties — base-R hot paths ─────────────────────────
# Replaces the nested dplyr filter loops that dominated fitness calculation
# runtime. Every logical operation is now done on plain vectors.
calculate_schedule_penalties <- function(schedule_nodes, data) {

  if (nrow(schedule_nodes) == 0L)
    return(list(penalty = 0, details = character(0), breakdown = list()))

  schedule_nodes <- expand_raw_schedule_nodes(schedule_nodes)

  sn_sec  <- as.character(schedule_nodes$section_id)
  sn_fac  <- as.character(schedule_nodes$faculty_id)
  sn_oid  <- as.integer(schedule_nodes$offering_id)
  sn_day  <- as.character(schedule_nodes$day)
  sn_hst  <- as.integer(schedule_nodes$hour_start)
  sn_hen  <- as.integer(schedule_nodes$hour_end)
  sn_hard <- as.logical(schedule_nodes$is_hard)
  sn_cc   <- as.character(schedule_nodes$course_code)
  sn_rm   <- as.character(schedule_nodes$room_id)

  total_penalty  <- 0
  penalty_details <- character(0)

  # ── Consecutive Hard Courses Penalty ──────────────────────────────────────
  sec_day_key <- paste(sn_sec, sn_day, sep = "|")
  for (k in unique(sec_day_key)) {
    idx <- which(sec_day_key == k)
    if (length(idx) < 2L) next
    # Expand hours
    hour_vec  <- unlist(mapply(function(s, e) seq.int(s, e - 1L), sn_hst[idx], sn_hen[idx], SIMPLIFY = FALSE))
    hard_vec  <- unlist(mapply(function(s, e, h) rep(h, e - s), sn_hst[idx], sn_hen[idx], sn_hard[idx], SIMPLIFY = FALSE))
    ord       <- order(hour_vec)
    hour_vec  <- hour_vec[ord]
    hard_vec  <- hard_vec[ord]
    n_h       <- length(hour_vec)
    for (i in seq_len(n_h - 1L)) {
      if (hard_vec[i] && hard_vec[i + 1L] && (hour_vec[i + 1L] - hour_vec[i] == 1L)) {
        total_penalty   <- total_penalty + 10
        penalty_details <- c(penalty_details,
          paste0("ConsecHard(", k, ",", hour_vec[i], "h)(-10)"))
      }
    }
  }

  # ── Minimize Preparations per Faculty ─────────────────────────────────────
  for (fid in unique(sn_fac)) {
    n_prep <- length(unique(sn_cc[sn_fac == fid]))
    if (n_prep > 1L) {
      pen <- (n_prep - 1L) * 2L
      total_penalty   <- total_penalty + pen
      penalty_details <- c(penalty_details,
        paste0("Preparations(", fid, ",", n_prep, "preps)(-", pen, ")"))
    }
  }

  # ── Room Switch Penalty ────────────────────────────────────────────────────
  for (oid in unique(sn_oid)) {
    n_rooms <- length(unique(sn_rm[sn_oid == oid]))
    if (n_rooms > 1L) {
      pen <- (n_rooms - 1L) * 1L
      total_penalty   <- total_penalty + pen
      penalty_details <- c(penalty_details,
        paste0("RoomSwitch(Offering", oid, ")(-", pen, ")"))
    }
  }

  # ── Split Meetings Same Day ────────────────────────────────────────────────
  for (oid in unique(sn_oid)) {
    days_for_oid   <- sn_day[sn_oid == oid]
    same_day_excess <- sum(duplicated(days_for_oid))
    if (same_day_excess > 0L) {
      pen <- same_day_excess * 1000000L
      total_penalty   <- total_penalty + pen
      penalty_details <- c(penalty_details,
        paste0("SplitMeetingSameDay(Offering", oid, ",", same_day_excess, ")(-", pen, ")"))
    }
  }

  # ── Max Straight Hours (section + faculty) ─────────────────────────────────
  hard_pen_per_excess <- 1000000L
  limit_straight      <- 4L
  for (entity_col in c("section_id", "faculty_id")) {
    ent_vec <- if (entity_col == "section_id") sn_sec else sn_fac
    ent_day_key <- paste(ent_vec, sn_day, sep = "|")
    for (k in unique(ent_day_key)) {
      idx <- which(ent_day_key == k)
      hour_vec <- sort(unique(unlist(mapply(
        function(s, e) seq.int(s, e - 1L), sn_hst[idx], sn_hen[idx], SIMPLIFY = FALSE
      ))))
      if (length(hour_vec) <= limit_straight) next
      r <- rle(diff(hour_vec))
      run_starts <- cumsum(c(1L, r$lengths))
      for (ri in seq_along(r$lengths)) {
        if (r$values[ri] != 1L) next
        block_len <- r$lengths[ri] + 1L
        if (block_len > limit_straight) {
          excess  <- block_len - limit_straight
          pen     <- excess * hard_pen_per_excess
          total_penalty   <- total_penalty + pen
          run_first_hour  <- hour_vec[run_starts[ri]]
          pen_str <- format(pen, scientific = FALSE)
          penalty_details <- c(penalty_details,
            paste0("StraightHoursExcess(", k, ",",
                   run_first_hour, "h+", block_len, "h,excess=", excess, ")(-", pen_str, ")"))
        }
      }
    }
  }

  # ── Breakdown summary ──────────────────────────────────────────────────────
  # total_penalty is the authoritative accumulator; breakdown is informational.
  consec_pen   <- sum(grepl("ConsecHard",         penalty_details)) * (-10L)
  split_pen    <- sum(grepl("SplitMeetingSameDay", penalty_details)) * (-1000000L)
  straight_pen <- sum(grepl("StraightHoursExcess", penalty_details)) * (-1000000L)
  room_pen     <- sum(grepl("RoomSwitch",          penalty_details)) * (-1L)
  # Preparations: each entry encodes its own penalty value; re-derive from
  # the accumulated total rather than guessing the per-entry amount.
  prep_pen <- -(total_penalty +
                  sum(grepl("ConsecHard",         penalty_details)) * 10L +
                  sum(grepl("RoomSwitch",          penalty_details)) * 1L +
                  sum(grepl("SplitMeetingSameDay", penalty_details)) * 1000000L +
                  sum(grepl("StraightHoursExcess", penalty_details)) * 1000000L)

  breakdown <- list(
    consecutive_hard      = consec_pen,
    preparations          = prep_pen,
    room_switch           = room_pen,
    split_meeting_days    = split_pen,
    straight_hours_excess = straight_pen
  )

  list(penalty = total_penalty, details = penalty_details, breakdown = breakdown)
}

calculate_coverage_penalty <- function(dg, data) {
  cov <- dg$get_coverage()
  uncovered <- cov$total_offerings - cov$covered_offerings
  pen <- cov$missing_meetings * 1000000
  list(penalty = pen, uncovered = uncovered, missing_meetings = cov$missing_meetings,
       coverage_ratio = cov$coverage_ratio)
}

calculate_faculty_workload_penalty <- function(schedule_nodes, data) {
  total_penalty <- 0
  details <- c()
  wl_nodes <- collapse_schedule_for_faculty_workload(expand_raw_schedule_nodes(schedule_nodes))
  rules <- faculty_schedule_rule_summary(wl_nodes, data)
  hard_penalty_per_hour <- 1000000
  for (i in seq_len(nrow(rules))) {
    row <- rules[i, ]
    underload      <- max(0, row$FTE - row$teaching_hours)
    overtime_excess <- max(0, row$overtime - row$max_overtime)
    waiting_excess  <- if (is.na(row$max_waiting_time)) 0 else max(0, row$total_waiting_time - row$max_waiting_time)
    if (underload > 0) {
      pen <- underload * hard_penalty_per_hour
      total_penalty <- total_penalty + pen
      details <- c(details, paste0("MinTeachingHours(", row$faculty_id, ",", underload, "h)(-", pen, ")"))
    }
    if (overtime_excess > 0) {
      pen <- overtime_excess * hard_penalty_per_hour
      total_penalty <- total_penalty + pen
      details <- c(details, paste0("OvertimeLimit(", row$faculty_id, ",", overtime_excess, "h)(-", pen, ")"))
    }
    if (waiting_excess > 0) {
      pen <- waiting_excess * hard_penalty_per_hour
      total_penalty <- total_penalty + pen
      details <- c(details, paste0("WaitingTimeLimit(", row$faculty_id, ",", waiting_excess, "h)(-", pen, ")"))
    }
  }
  list(penalty = total_penalty, details = details, rule_summary = rules)
}

calculate_fitness <- function(dg, data, verbose = FALSE) {
  schedule_nodes <- dg$selected_nodes_df

  if (nrow(schedule_nodes) == 0L) {
    sum_vertex    <- 0
    vertex_weights <- list()
  } else {
    # Use pre-cached weights from precompute_node_weights rather than calling
    # calculate_vertex_adjusted_weight row-by-row (avoids a dplyr filter per node).
    w_vec <- precompute_node_weights(schedule_nodes, data)
    sum_vertex <- sum(w_vec)
    # Retain vertex_breakdown list for API compatibility; build it cheaply.
    vertex_weights <- lapply(seq_len(nrow(schedule_nodes)), function(i)
      list(weight = w_vec[i], details = character(0), penalty = 0, bonus = w_vec[i] - schedule_nodes$base_weight[i]))
  }

  sched_pen <- calculate_schedule_penalties(schedule_nodes, data)
  cov_pen   <- calculate_coverage_penalty(dg, data)
  wl_pen    <- calculate_faculty_workload_penalty(schedule_nodes, data)

  total_penalty <- sched_pen$penalty + cov_pen$penalty + wl_pen$penalty
  F <- sum_vertex - total_penalty

  if (verbose) {
    cat(sprintf("Fitness F = %.2f\n", F))
    cat(sprintf("  Σ Vertex Weights: %.2f\n", sum_vertex))
    cat(sprintf("  - Schedule Penalties: %d\n", sched_pen$penalty))
    cat(sprintf("  - Coverage Penalty: %d (%.1f%% covered)\n",
      cov_pen$penalty, cov_pen$coverage_ratio * 100))
    cat(sprintf("  - Workload Penalty: %d\n", wl_pen$penalty))
  }

  list(
    F = F,
    sum_vertex_weights = sum_vertex,
    schedule_penalty = sched_pen$penalty,
    schedule_penalty_details = sched_pen$details,
    coverage_penalty = cov_pen$penalty,
    coverage_ratio = cov_pen$coverage_ratio,
    uncovered_offerings = cov_pen$uncovered,
    workload_penalty = wl_pen$penalty,
    faculty_rule_summary = wl_pen$rule_summary,
    n_selected = nrow(schedule_nodes),
    vertex_breakdown = vertex_weights
  )
}

fitness_from_solution <- function(node_ids, nodes, adjacency, data) {
  dg <- DynamicGraph$new(nodes, adjacency, data)
  for (nid in node_ids) {
    if (!dg$select_node(nid)) break
  }
  calculate_fitness(dg, data)
}

message("04_fitness_calculation.R loaded.")
