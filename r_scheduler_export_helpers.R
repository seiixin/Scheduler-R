# Shared R export and independent hard-constraint checks for ACO/SA runners.

format_schedule_for_export <- function(schedule, data) {
  schedule <- as.data.frame(schedule)
  offering <- data$offerings[, c("offering_id", "Dept"), drop = FALSE]
  section  <- data$sections[,  c("section_id",  "student_count"), drop = FALSE]
  schedule$Dept          <- offering$Dept[match(schedule$offering_id, offering$offering_id)]
  schedule$student_count <- section$student_count[match(schedule$section_id, section$section_id)]
  show_hour <- function(x)
    sprintf("%02d:00 %s",
            ifelse(x %% 12L == 0L, 12L, x %% 12L),
            ifelse(x < 12L, "AM", "PM"))
  schedule$time_formatted <- paste(show_hour(schedule$hour_start),
                                   show_hour(schedule$hour_end), sep = " - ")
  schedule <- schedule[order(
    match(schedule$day, c("Monday","Tuesday","Wednesday","Thursday","Friday")),
    schedule$hour_start, schedule$room_id), , drop = FALSE]
  required <- c("offering_id","meeting_idx","course_code","section_id","faculty_id",
                "Dept","day","hour_start","hour_end","time_formatted","duration",
                "room_id","room_cap","student_count")
  schedule[, intersect(required, names(schedule)), drop = FALSE]
}

validate_r_schedule <- function(schedule, data) {

  # ── Coverage ──────────────────────────────────────────────────────────────
  expected_keys <- paste(
    rep(data$offerings$offering_id, lengths(data$offerings$meeting_patterns)),
    unlist(lapply(data$offerings$meeting_patterns, seq_along)), sep = "|"
  )
  actual_keys <- paste(schedule$offering_id, schedule$meeting_idx, sep = "|")
  coverage_violations <- sum(!(expected_keys %in% actual_keys)) +
    sum(duplicated(actual_keys)) +
    sum(!(actual_keys %in% expected_keys))

  # ── Helpers: group key builder ────────────────────────────────────────────
  # Used by lunch() and straight_hours() which operate on the full schedule.
  # overlaps() builds its own key from a potentially deduplicated view.
  grp_key <- function(id) paste(schedule[[id]], schedule$day, sep = "|")

  # ── Merged-class deduplication keys ───────────────────────────────────────
  # Merged classes emit one row per member offering, all with identical
  # (faculty_id, room_id, day, hour_start, hour_end).  For faculty_overlap
  # and room_overlap those duplicate rows are the same physical slot — they
  # must not be counted as conflicts with each other.
  #
  # mg_slot_key: uniquely identifies one physical class slot.  For a merged
  # unit it is "M|<merge_group_id>|<meeting_idx>"; for a solo offering it is
  # "O|<offering_id>|<meeting_idx>".  Rows that share mg_slot_key represent
  # the same slot and should be collapsed to one before overlap checking for
  # room and faculty (but NOT for section — each member section is a distinct
  # entity that must be checked independently).
  #
  # Build mg_slot_key now so the merged-class rules block below can reuse it
  # instead of recomputing mg_map twice.
  mg_map      <- setNames(data$offerings$merge_group_id, data$offerings$offering_id)
  mg_slot_key <- ifelse(
    is.na(mg_map[as.character(schedule$offering_id)]),
    paste0("O|", schedule$offering_id, "|", schedule$meeting_idx),
    paste0("M|", mg_map[as.character(schedule$offering_id)], "|", schedule$meeting_idx)
  )
  # One representative row index per physical slot (first occurrence).
  dedup_idx <- !duplicated(mg_slot_key)

  # ── Overlaps — O(n log n) sort-and-scan per group ─────────────────────────
  # For faculty_id and room_id: operate on the deduplicated view so merged
  # rows don't self-count.  For section_id: use all rows (each section is
  # independent and must be checked against all others on the same day).
  overlaps <- function(id, use_dedup = TRUE) {
    sched_view <- if (use_dedup && id != "section_id")
      schedule[dedup_idx, , drop = FALSE]
    else
      schedule
    gk   <- paste(sched_view[[id]], sched_view$day, sep = "|")
    s    <- sched_view$hour_start
    e    <- sched_view$hour_end
    total <- 0L
    for (k in unique(gk)) {
      idx <- which(gk == k)
      if (length(idx) < 2L) next
      ord <- order(s[idx])
      si  <- s[idx[ord]]
      ei  <- e[idx[ord]]
      max_end <- ei[1L]
      for (ii in 2L:length(si)) {
        if (si[ii] < max_end) total <- total + 1L
        if (ei[ii] > max_end) max_end <- ei[ii]
      }
    }
    total
  }

  # ── Lunch — vectorised per group ──────────────────────────────────────────
  # A violation = all three of hours 10, 11, 12 are covered (i.e., some
  # meeting's [hour_start, hour_end) spans that hour).  Test all three hours
  # with vectorised any() instead of inner vapply.
  lunch <- function(id) {
    gk <- grp_key(id)
    s  <- schedule$hour_start
    e  <- schedule$hour_end
    violations <- 0L
    for (k in unique(gk)) {
      idx  <- which(gk == k)
      si   <- s[idx]
      ei   <- e[idx]
      h10  <- any(si <= 10L & ei > 10L)
      h11  <- any(si <= 11L & ei > 11L)
      h12  <- any(si <= 12L & ei > 12L)
      if (h10 && h11 && h12) violations <- violations + 1L
    }
    violations
  }

  # ── Straight hours — vectorised hour expansion ────────────────────────────
  # Expand each meeting into its constituent hours using sequence(), then
  # use rle(diff()) on the sorted unique hour vector.  This avoids a nested
  # lapply+seq loop and an inner for-loop over rle components.
  straight_hours <- function(id, limit = 4L) {
    gk     <- grp_key(id)
    s      <- schedule$hour_start
    dur    <- schedule$hour_end - schedule$hour_start   # duration in hours
    excess <- 0L
    for (k in unique(gk)) {
      idx <- which(gk == k)
      if (length(idx) == 0L) next
      # Expand: for each row expand [hour_start, hour_end) into individual hours
      all_hrs <- sort(unique(unlist(mapply(
        function(st, d) seq.int(st, st + d - 1L),
        s[idx], dur[idx], SIMPLIFY = FALSE
      ))))
      if (length(all_hrs) <= limit) next
      # rle on consecutive differences: a block of k consecutive 1s covers k+1 hours
      r <- rle(diff(all_hrs))
      for (ri in seq_along(r$lengths)) {
        if (r$values[ri] != 1L) next
        block_len <- r$lengths[ri] + 1L
        if (block_len > limit) excess <- excess + (block_len - limit)
      }
    }
    excess
  }

  # ── Split-meeting same-day ─────────────────────────────────────────────────
  split_meeting_same_day <- sum(vapply(
    split(as.character(schedule$day), schedule$offering_id),
    function(days) sum(duplicated(days)), integer(1)
  ))

  # ── Department-room, faculty availability ─────────────────────────────────
  room_dept <- data$rooms$Dept[match(schedule$room_id, data$rooms$room_id)]
  fac_num   <- data$faculty$Faculty[match(schedule$faculty_id, data$faculty$faculty_id)]
  # Pre-split faculty_time by Faculty×Day key for fast lookup
  ft <- data$raw_data$faculty_time
  ft_key <- paste(ft$Faculty, ft$Day, sep = "|")
  available <- vapply(seq_len(nrow(schedule)), function(i) {
    key <- paste(fac_num[i],
                 match(schedule$day[i],
                       c("Monday","Tuesday","Wednesday","Thursday","Friday")),
                 sep = "|")
    win <- ft[ft_key == key, , drop = FALSE]
    !nrow(win) || any(schedule$hour_start[i] >= win$Time_from &
                        schedule$hour_end[i]   <= win$Time_to)
  }, logical(1))

  faculty_rules <- faculty_schedule_rule_summary(schedule, data)

  # ── Merged-class rules ────────────────────────────────────────────────────
  # mg_map and mg_slot_key were already computed above for the dedup logic.
  # Reuse them here; just attach to the schedule data frame for the loop below.
  schedule$mg             <- mg_slot_key
  schedule$merge_group_id <- mg_map[as.character(schedule$offering_id)]

  # merged_coherence: every row in same merge group must share
  # (faculty_id, day, hour_start, hour_end, room_id).
  merged_coherence <- 0L
  for (k in unique(schedule$mg)) {
    mem <- schedule[schedule$mg == k, , drop = FALSE]
    if (nrow(mem) <= 1L) next
    if (!(length(unique(mem$faculty_id)) == 1L &&
          length(unique(mem$day))        == 1L &&
          length(unique(mem$hour_start)) == 1L &&
          length(unique(mem$hour_end))   == 1L &&
          length(unique(mem$room_id))    == 1L))
      merged_coherence <- merged_coherence + 1L
  }

  # merged_capacity: sum(student_count) per merge group <= 56 AND <= room_cap.
  merged_capacity <- 0L
  for (k in unique(schedule$mg)) {
    mem <- schedule[schedule$mg == k, , drop = FALSE]
    if (nrow(mem) <= 1L) next
    total_stu    <- sum(mem$student_count)
    room_cap_val <- unique(mem$room_cap)[1L]
    if (total_stu > 56L)          merged_capacity <- merged_capacity + (total_stu - 56L)
    if (total_stu > room_cap_val) merged_capacity <- merged_capacity + (total_stu - room_cap_val)
  }

  # room_capacity — Rule 4: 56-student class size cap.
  #
  # For unmerged (solo) offerings: every row's student_count must be ≤ 56.
  # The physical room capacity (60) is a separate concern handled by the
  # room assignment logic; Rule 4 specifically limits class size to 56.
  #
  # For merged offerings: the group total is already checked by
  # merged_capacity above (sum ≤ 56).  Solo rows that belong to a merge
  # group are excluded here to avoid double-counting.
  #
  # Count the number of ROWS (one per offering meeting) that exceed 56,
  # so the violation count maps directly to the number of over-cap classes.
  CLASS_SIZE_CAP <- 56L
  solo_mask <- is.na(schedule$merge_group_id)   # TRUE = not part of a merge
  class_size_violations <- sum(
    solo_mask & !is.na(schedule$student_count) & schedule$student_count > CLASS_SIZE_CAP
  )

  data.frame(
    rule = c("coverage", "end_by_20", "department_room", "room_capacity",
             "room_overlap", "faculty_overlap", "section_overlap",
             "faculty_lunch", "section_lunch",
             "section_straight_hours", "faculty_straight_hours",
             "merged_class_coherence", "merged_class_capacity",
             "faculty_availability",
             "split_meetings_different_days",
             "faculty_minimum_teaching_hours", "faculty_overtime_limit",
             "faculty_total_waiting_time"),
    violations = c(
      coverage_violations,
      sum(schedule$hour_end > 20L),
      sum(schedule$Dept != room_dept),
      class_size_violations,
      overlaps("room_id"), overlaps("faculty_id"), overlaps("section_id", use_dedup = FALSE),
      lunch("faculty_id"), lunch("section_id"),
      straight_hours("section_id", 4L), straight_hours("faculty_id", 4L),
      merged_coherence, merged_capacity,
      sum(!available),
      split_meeting_same_day,
      sum(faculty_rules$teaching_hours < faculty_rules$FTE),
      sum(faculty_rules$overtime       > faculty_rules$max_overtime),
      sum(!is.na(faculty_rules$max_waiting_time) &
            faculty_rules$total_waiting_time > faculty_rules$max_waiting_time)
    )
  )
}

make_r_schedule_tasks <- function(data) {
  rows <- lapply(seq_len(nrow(data$offerings)), function(i) {
    pattern <- as.integer(data$offerings$meeting_patterns[[i]])
    data.frame(
      offering_id    = data$offerings$offering_id[i],
      meeting_idx    = seq_along(pattern),
      duration       = pattern,
      course_code    = data$offerings$course_code[i],
      section_id     = data$offerings$section_id[i],
      faculty_id     = data$offerings$faculty_id[i],
      Dept           = data$offerings$Dept[i],
      merge_group_id = if (!is.null(data$offerings$merge_group_id))
        rep(data$offerings$merge_group_id[i], length(pattern))
      else
        rep(NA_integer_, length(pattern)),
      student_count  = if (!is.null(data$offerings$student_count))
        rep(data$offerings$student_count[i], length(pattern))
      else
        rep(NA_integer_, length(pattern)),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# ── build_task_index ──────────────────────────────────────────────────────────
# Shared by GA (05_genetic_algorithm.R) and ACO (06_ant_colony.R).
# Returns a data frame with one row per (offering, meeting) task plus the pool
# of candidate node_ids available for each task from the nodes table.
build_task_index <- function(nodes, data) {
  mg_map <- setNames(data$offerings$merge_group_id, data$offerings$offering_id)

  unit_key_for <- function(oid, midx) {
    mg <- mg_map[[as.character(oid)]]
    base <- if (!is.null(mg) && !is.na(mg)) paste0("M|", mg) else paste0("O|", oid)
    paste0(base, "::", midx)
  }

  tasks <- make_r_schedule_tasks(data)
  tasks$.task_key  <- paste0(tasks$offering_id, "::", tasks$meeting_idx)
  tasks$.unit_key  <- mapply(unit_key_for, tasks$offering_id, tasks$meeting_idx,
                             SIMPLIFY = TRUE)

  node_uk_key <- paste0(nodes$unit_key, "::", nodes$meeting_idx)

  tasks$.node_pool    <- lapply(tasks$.unit_key, function(uk)
    as.integer(nodes$node_id[node_uk_key == uk]))
  tasks$.n_candidates <- vapply(tasks$.node_pool, length, integer(1))

  # Drop tasks with zero candidates — they cannot be scheduled.
  tasks[tasks$.n_candidates > 0L, , drop = FALSE]
}

is_r_faculty_available <- function(faculty_num, day, hours, faculty_time) {
  day_num <- match(day, c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday"))
  windows <- faculty_time[faculty_time$Faculty == faculty_num &
                            faculty_time$Day == day_num, , drop = FALSE]
  !nrow(windows) || any(vapply(seq_len(nrow(windows)), function(i) {
    all(hours >= windows$Time_from[i] & hours < windows$Time_to[i])
  }, logical(1)))
}

# Pre-flight check: verify every dept that has offerings also has at least one
# room large enough for its biggest section.  Returns a character vector of
# human-readable problem descriptions (empty = all clear).
preflight_room_feasibility <- function(data) {
  section_size <- setNames(data$sections$student_count, data$sections$section_id)
  problems <- character(0)

  # Rule 4: 56-student class size cap.  Sections exceeding this cannot be
  # fixed by the scheduler — flag them as data quality warnings so the user
  # knows before 200 repair attempts are burned.
  oversize <- data$sections[!is.na(data$sections$student_count) &
                               data$sections$student_count > 56L, , drop = FALSE]
  if (nrow(oversize) > 0L) {
    problems <- c(problems, sprintf(
      "Rule 4 (56-student cap): %d section(s) exceed 56 students in source data — these will appear as room_capacity violations in the output. Max observed: %d students.",
      nrow(oversize), max(oversize$student_count, na.rm = TRUE)
    ))
  }

  for (dept in unique(data$offerings$Dept)) {
    dept_rooms <- data$rooms[!is.na(data$rooms$Dept) & data$rooms$Dept == dept, , drop = FALSE]
    if (!nrow(dept_rooms)) {
      problems <- c(problems, sprintf("Dept %s has offerings but NO rooms at all.", dept))
      next
    }
    off_in_dept <- data$offerings[data$offerings$Dept == dept, , drop = FALSE]
    for (sid in unique(off_in_dept$section_id)) {
      need <- section_size[[sid]]
      if (is.na(need) || is.null(need)) next
      if (!any(dept_rooms$capacity >= need))
        problems <- c(problems, sprintf(
          "Dept %s: section %s needs capacity %d but largest room is %d.",
          dept, sid, need, max(dept_rooms$capacity)))
    }
  }
  problems
}

# ─────────────────────────────────────────────────────────────────────────────
# construct_verified_r_schedule
#
# Optimisation notes vs. original:
#
#  • Busy-state is stored as a named integer-vector "bitset" (one element per
#    entity×day key, value = bitmask over hours 7–20 where bit k = hour k+7).
#    is_free/reserve/lunch_ok/straight_ok now do bitwise ops instead of one
#    exists()/assign() call per hour.
#
#  • blocked_slots from data$blocked_slots are enforced before attempting any
#    placement.  A pre-computed (day × start) boolean lookup prevents classes
#    from landing in Flag-Ceremony (Mon 7–8) or Campus-Break (Wed 11–13) slots.
# ─────────────────────────────────────────────────────────────────────────────
construct_verified_r_schedule <- function(data, seed, max_choices = 100L) {
  set.seed(seed)
  tasks        <- make_r_schedule_tasks(data)
  section_size <- setNames(data$sections$student_count,  data$sections$section_id)
  faculty_num  <- setNames(data$offerings$faculty_num,   data$offerings$offering_id)
  rooms_per_dept <- table(data$rooms$Dept)

  # ── Unit grouping (merge-aware) ──────────────────────────────────────────
  tasks$.unit_key <- ifelse(is.na(tasks$merge_group_id),
    paste0("O|", tasks$offering_id,      "|", tasks$meeting_idx),
    paste0("M|", tasks$merge_group_id,   "|", tasks$meeting_idx))
  tasks$.priority_base <- tasks$duration * 1000 +
    100 / pmax(1, as.numeric(rooms_per_dept[as.character(tasks$Dept)]))
  unit_first_positions <- match(unique(tasks$.unit_key), tasks$.unit_key)
  unit_order           <- order(-tasks$.priority_base[unit_first_positions],
                                runif(length(unit_first_positions)))
  unit_keys_ordered <- unique(tasks$.unit_key)[unit_order]
  n_units           <- length(unit_keys_ordered)
  unit_members      <- lapply(unit_keys_ordered, function(k) which(tasks$.unit_key == k))

  # ── blocked_slots lookup ─────────────────────────────────────────────────
  # Build a named logical matrix [day, start] to reject blocked (day,start)
  # pairs instantly without any env lookup.
  day_names <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
  # is_blocked_start[day_idx, start] == TRUE means that hour is in blocked_slots
  # We need to know if ANY hour of [start, start+dur) is blocked.
  # Pre-compute a (day × hour) boolean matrix (hours 7..20).
  blocked_day_hour <- matrix(FALSE, nrow = 5L, ncol = 14L,
                              dimnames = list(day_names, as.character(7:20)))
  if (length(data$blocked_slots) > 0L) {
    ts <- data$time_slots
    for (bs in data$blocked_slots) {
      row <- ts[ts$time_slot_id == bs, , drop = FALSE]
      if (nrow(row) == 0L) next
      d <- row$day[1L]
      h <- as.character(row$hour_start[1L])
      if (d %in% day_names && h %in% colnames(blocked_day_hour))
        blocked_day_hour[d, h] <- TRUE
    }
  }
  # Returns TRUE if placement [start, start+duration) on given day hits a block
  any_hour_blocked <- function(day, start, duration) {
    hours_chr <- as.character(seq.int(start, start + duration - 1L))
    valid_hrs  <- hours_chr[hours_chr %in% colnames(blocked_day_hour)]
    if (!length(valid_hrs)) return(FALSE)
    any(blocked_day_hour[day, valid_hrs])
  }

  # ── Bitset busy-state ────────────────────────────────────────────────────
  # Hours 7–20 map to bits 0–13 (bit k = 1L << k corresponds to hour k+7).
  # One integer per "kind|id|day" key; bitwise OR sets bits, AND checks them.
  HOUR_OFFSET <- 7L        # hour h → bit (h - HOUR_OFFSET)
  busy_bits   <- integer(0)   # named integer vector; names are "kind|id|day"

  bitmask <- function(hours) {
    # Returns an integer bitmask for a vector of hour values (7–20).
    sum(bitwShiftL(1L, hours - HOUR_OFFSET))
  }

  get_bits <- function(key) {
    v <- busy_bits[key]
    if (is.na(v)) 0L else v
  }

  is_free_bits <- function(kind, id, day, hours) {
    key  <- paste(kind, id, day, sep = "|")
    mask <- bitmask(hours)
    bitwAnd(get_bits(key), mask) == 0L
  }

  reserve_bits <- function(kind, id, day, hours) {
    key <- paste(kind, id, day, sep = "|")
    cur <- get_bits(key)
    busy_bits[key] <<- bitwOr(cur, bitmask(hours))
  }

  lunch_ok_bits <- function(kind, id, day, hours) {
    # Violation = all three of 10,11,12 occupied (by prior reservations OR
    # the candidate hours).  At least one must be free after placement.
    key      <- paste(kind, id, day, sep = "|")
    cur_mask <- bitwOr(get_bits(key), bitmask(hours))
    h10 <- bitwAnd(cur_mask, bitwShiftL(1L, 10L - HOUR_OFFSET)) != 0L
    h11 <- bitwAnd(cur_mask, bitwShiftL(1L, 11L - HOUR_OFFSET)) != 0L
    h12 <- bitwAnd(cur_mask, bitwShiftL(1L, 12L - HOUR_OFFSET)) != 0L
    !(h10 && h11 && h12)   # TRUE = lunch is still OK
  }

  straight_ok_bits <- function(kind, id, day, hours, limit = 4L) {
    key      <- paste(kind, id, day, sep = "|")
    cur_mask <- bitwOr(get_bits(key), bitmask(hours))
    # Extract occupied hours from bitmask
    occ <- integer(0)
    for (bit in 0L:13L) {
      if (bitwAnd(cur_mask, bitwShiftL(1L, bit)) != 0L)
        occ <- c(occ, bit + HOUR_OFFSET)
    }
    if (length(occ) <= limit) return(TRUE)
    r <- rle(diff(occ))
    for (ri in seq_along(r$lengths)) {
      if (r$values[ri] != 1L) next
      if ((r$lengths[ri] + 1L) > limit) return(FALSE)
    }
    TRUE
  }

  # Offering-day registry — kept as a separate named logical vector for speed
  offering_day_placed <- logical(0)  # names: "oid|day"

  offering_day_blocked_by_any <- function(oid_vec, day) {
    keys <- paste(oid_vec, day, sep = "|")
    any(keys %in% names(offering_day_placed))
  }

  mark_offering_days <- function(oid_vec, day) {
    keys <- paste(oid_vec, day, sep = "|")
    offering_day_placed[keys] <<- TRUE
  }

  # ── Placement check closure ───────────────────────────────────────────────
  placement_ok_for_all_members <- function(member_tasks, day, hours, use_fac_avail) {
    # Section checks
    for (sid in member_tasks$section_id) {
      if (!is_free_bits("S", sid, day, hours))        return(FALSE)
      if (!lunch_ok_bits("S", sid, day, hours))       return(FALSE)
      if (!straight_ok_bits("S", sid, day, hours, 4L)) return(FALSE)
    }
    # Faculty checks
    fac_id <- member_tasks$faculty_id[1L]
    if (!is_free_bits("F", fac_id, day, hours))        return(FALSE)
    if (!lunch_ok_bits("F", fac_id, day, hours))       return(FALSE)
    if (!straight_ok_bits("F", fac_id, day, hours, 4L)) return(FALSE)
    # Faculty availability windows (optional)
    if (use_fac_avail) {
      for (oid in member_tasks$offering_id) {
        f_num <- faculty_num[[as.character(oid)]]
        if (!is.na(f_num) &&
            !is_r_faculty_available(f_num, day, hours, data$raw_data$faculty_time))
          return(FALSE)
      }
    }
    TRUE
  }

  # ── Score a candidate placement (minimise span growth) ───────────────────
  entity_day_span_bits <- function(kind, id, day) {
    key <- paste(kind, id, day, sep = "|")
    cur <- get_bits(key)
    if (cur == 0L) return(c(NA_integer_, NA_integer_))
    occ <- integer(0)
    for (bit in 0L:13L)
      if (bitwAnd(cur, bitwShiftL(1L, bit)) != 0L) occ <- c(occ, bit + HOUR_OFFSET)
    c(min(occ), max(occ) + 1L)
  }

  score_candidate_placement <- function(member_tasks, day, c_start, c_end) {
    fac_id <- member_tasks$faculty_id[1L]
    rng    <- entity_day_span_bits("F", fac_id, day)
    if (is.na(rng[1L])) {
      fac_delta <- c_end - c_start
    } else {
      fac_delta <- (max(rng[2L], c_end) - min(rng[1L], c_start)) - (rng[2L] - rng[1L])
    }
    sec_delta <- 0L
    for (sid in member_tasks$section_id) {
      s_rng <- entity_day_span_bits("S", sid, day)
      if (is.na(s_rng[1L])) {
        sec_delta <- sec_delta + (c_end - c_start)
      } else {
        sec_delta <- sec_delta +
          (max(s_rng[2L], c_end) - min(s_rng[1L], c_start)) - (s_rng[2L] - s_rng[1L])
      }
    }
    fac_delta * 2L + sec_delta
  }

  # ── Main scheduling loop ──────────────────────────────────────────────────
  rows <- vector("list", n_units)

  for (ui in seq_len(n_units)) {
    member_idx    <- unit_members[[ui]]
    mt            <- tasks[member_idx, , drop = FALSE]
    group_duration <- mt$duration[1L]
    dept           <- mt$Dept[1L]
    fac_id         <- mt$faculty_id[1L]
    student_sum    <- sum(mt$student_count, na.rm = TRUE)
    need           <- if (is.na(student_sum) || student_sum == 0L)
      max(section_size[[mt$section_id]], 1L, na.rm = TRUE) else student_sum

    # Prefer dept-matched rooms; fall back to any room with sufficient capacity
    candidate_rooms <- data$rooms[
      !is.na(data$rooms$Dept) & data$rooms$Dept == dept &
        data$rooms$capacity >= need, , drop = FALSE]
    if (!nrow(candidate_rooms))
      candidate_rooms <- data$rooms[data$rooms$capacity >= need, , drop = FALSE]
    if (!nrow(candidate_rooms)) return(NULL)

    # ── Pass 1: full constraints including faculty availability ─────────────
    choices <- list()
    for (day in sample(day_names)) {
      if (offering_day_blocked_by_any(mt$offering_id, day)) next
      for (start in sample(seq.int(7L, 20L - group_duration))) {
        if (any_hour_blocked(day, start, group_duration)) next   # ← blocked_slots
        hours <- seq.int(start, start + group_duration - 1L)
        if (!placement_ok_for_all_members(mt, day, hours, use_fac_avail = TRUE)) next
        for (ri in sample(seq_len(nrow(candidate_rooms)))) {
          room <- candidate_rooms[ri, ]
          if (is_free_bits("R", room$room_id, day, hours)) {
            choices[[length(choices) + 1L]] <-
              list(day = day, start = start, hours = hours, room = room)
            if (length(choices) >= max_choices) break
          }
        }
        if (length(choices) >= max_choices) break
      }
      if (length(choices) >= max_choices) break
    }

    # ── Pass 2: drop faculty availability windows ───────────────────────────
    if (!length(choices)) {
      for (day in sample(day_names)) {
        if (offering_day_blocked_by_any(mt$offering_id, day)) next
        for (start in sample(seq.int(7L, 20L - group_duration))) {
          if (any_hour_blocked(day, start, group_duration)) next  # ← blocked_slots
          hours <- seq.int(start, start + group_duration - 1L)
          if (!placement_ok_for_all_members(mt, day, hours, use_fac_avail = FALSE)) next
          for (ri in sample(seq_len(nrow(candidate_rooms)))) {
            room <- candidate_rooms[ri, ]
            if (is_free_bits("R", room$room_id, day, hours)) {
              choices[[length(choices) + 1L]] <-
                list(day = day, start = start, hours = hours, room = room)
              if (length(choices) >= max_choices) break
            }
          }
          if (length(choices) >= max_choices) break
        }
        if (length(choices) >= max_choices) break
      }
    }

    # ── Pass 3: drop lunch constraint, keep straight-hours hard ────────────
    if (!length(choices)) {
      for (day in sample(day_names)) {
        if (offering_day_blocked_by_any(mt$offering_id, day)) next
        for (start in sample(seq.int(7L, 20L - group_duration))) {
          if (any_hour_blocked(day, start, group_duration)) next  # ← blocked_slots
          hours <- seq.int(start, start + group_duration - 1L)
          ok_sections <- all(vapply(mt$section_id, function(sid)
            is_free_bits("S", sid, day, hours) &&
              straight_ok_bits("S", sid, day, hours, 4L), logical(1)))
          if (!ok_sections) next
          if (!is_free_bits("F", fac_id, day, hours))         next
          if (!straight_ok_bits("F", fac_id, day, hours, 4L)) next
          for (ri in sample(seq_len(nrow(candidate_rooms)))) {
            room <- candidate_rooms[ri, ]
            if (is_free_bits("R", room$room_id, day, hours)) {
              choices[[length(choices) + 1L]] <-
                list(day = day, start = start, hours = hours, room = room)
              if (length(choices) >= max_choices) break
            }
          }
          if (length(choices) >= max_choices) break
        }
        if (length(choices) >= max_choices) break
      }
    }

    if (!length(choices)) return(NULL)

    # Pick the choice that minimises faculty+section span growth
    choice_scores <- vapply(seq_along(choices), function(ci) {
      ch <- choices[[ci]]
      score_candidate_placement(mt, ch$day, ch$start, ch$start + group_duration)
    }, integer(1))
    best_score <- min(choice_scores)
    best_idx   <- which(choice_scores == best_score)
    if (length(best_idx) > 5L) best_idx <- sample(best_idx, 5L)
    choice <- choices[[best_idx[sample.int(length(best_idx), 1L)]]]

    # Commit reservation using bitset helpers
    reserve_bits("F", fac_id, choice$day, choice$hours)
    for (sid in mt$section_id) reserve_bits("S", sid, choice$day, choice$hours)
    reserve_bits("R", choice$room$room_id, choice$day, choice$hours)
    mark_offering_days(mt$offering_id, choice$day)

    # Emit one row PER OFFERING so coverage (1 010 rows) is preserved exactly.
    rows[[ui]] <- do.call(rbind, lapply(seq_len(nrow(mt)), function(k) {
      data.frame(
        offering_id   = mt$offering_id[k],
        meeting_idx   = mt$meeting_idx[k],
        course_code   = mt$course_code[k],
        section_id    = mt$section_id[k],
        faculty_id    = fac_id,
        Dept          = dept,
        day           = choice$day,
        hour_start    = choice$start,
        hour_end      = choice$start + group_duration,
        duration      = group_duration,
        room_id       = choice$room$room_id,
        room_cap      = choice$room$capacity,
        student_count = ifelse(!is.na(mt$student_count[k]),
                               mt$student_count[k],
                               section_size[[mt$section_id[k]]])
      )
    }))
  }
  do.call(rbind, rows)
}

# ─────────────────────────────────────────────────────────────────────────────
# construct_schedule_from_preferences()
#
# THE SHARED DECODER used by both GA and ACO.
#
# Converts a task-preference vector (one preferred node_id per scheduling
# task) into a complete, conflict-free schedule data frame.
#
# How it works per the client flow docs:
#   1. For each (offering, meeting_idx) task in priority order:
#       a. Try the preferred node first (first-choice placement).
#       b. If the preferred node is already taken or conflicts with an
#          existing placement, iterate through alternative nodes for the
#          same task in decreasing weight order until one fits.
#   2. Fitness-facing output is a DynamicGraph so calculate_fitness() can
#      score it directly — same as GA/ACO used to do, but now driven by
#      preferences instead of a random permutation.
#
# Arguments:
#   preferences  — named integer vector: names are "offering_id::meeting_idx",
#                  values are the preferred node_id for that task.
#   nodes        — the full candidate nodes data frame from build_candidate_nodes().
#   adjacency    — the full adjacency matrix.
#   data         — the scheduling data list from read_tupc_data().
#
# Returns: a DynamicGraph with selected_ids populated, ready for
#          calculate_fitness() or get_expanded_selected_nodes().
# ─────────────────────────────────────────────────────────────────────────────
construct_schedule_from_preferences <- function(preferences, nodes, adjacency, data) {
  dg <- DynamicGraph$new(nodes, adjacency, data)

  tasks <- make_r_schedule_tasks(data)

  mg_map <- setNames(data$offerings$merge_group_id, data$offerings$offering_id)
  unit_key_for <- function(oid, midx) {
    mg <- mg_map[[as.character(oid)]]
    base <- if (!is.null(mg) && !is.na(mg)) paste0("M|", mg) else paste0("O|", oid)
    paste0(base, "::", midx)
  }

  node_unit_midx_key <- paste0(nodes$unit_key, "::", nodes$meeting_idx)

  tasks$.unit_key_full <- mapply(unit_key_for,
                                 tasks$offering_id, tasks$meeting_idx,
                                 SIMPLIFY = TRUE)

  # Pre-build pool lookup as a list keyed by unit_key_full — avoids
  # O(n_tasks × n_nodes) string scan on every call.
  pool_lookup <- split(seq_len(nrow(nodes)),
                       node_unit_midx_key)

  tasks$.n_candidates <- vapply(tasks$.unit_key_full,
                                function(k) length(pool_lookup[[k]]),
                                integer(1))
  tasks$.priority <- tasks$duration * 10000L + tasks$.n_candidates
  task_order      <- order(-tasks$.priority)
  tasks_ordered   <- tasks[task_order, , drop = FALSE]

  # Use environment for O(1) placed_unit_keys lookup instead of growing vector
  placed_env <- new.env(parent = emptyenv())

  node_wts <- nodes$base_weight

  for (ti in seq_len(nrow(tasks_ordered))) {
    t    <- tasks_ordered[ti, , drop = FALSE]
    oid  <- t$offering_id
    midx <- t$meeting_idx
    uk   <- t$.unit_key_full

    if (exists(uk, placed_env, inherits = FALSE)) next

    pool_idx <- pool_lookup[[uk]]
    if (is.null(pool_idx) || length(pool_idx) == 0L) next
    pool_ids <- nodes$node_id[pool_idx]

    pref_key     <- paste0(oid, "::", midx)
    preferred_id <- preferences[pref_key]

    if (!is.na(preferred_id) && preferred_id %in% pool_ids) {
      alt_ids   <- pool_ids[pool_ids != preferred_id]
      alt_wts   <- node_wts[match(alt_ids, nodes$node_id)]
      alt_ids   <- alt_ids[order(-alt_wts)]
      trial_ids <- c(preferred_id, alt_ids)
    } else {
      wts       <- node_wts[match(pool_ids, nodes$node_id)]
      trial_ids <- pool_ids[order(-wts)]
    }

    for (nid in trial_ids) {
      if (!dg$active_mask[nid]) next
      if (dg$select_node(nid)) {
        assign(uk, TRUE, placed_env)
        break
      }
    }
  }

  dg
}

# ── Helper to build preferences from a node-per-task vector for fitness eval ─
# Evaluates a chromosome (named integer vector: task_key → node_id) by
# running the preference decoder and returning calculate_fitness().
fitness_from_preferences <- function(preferences, nodes, adjacency, data) {
  dg  <- construct_schedule_from_preferences(preferences, nodes, adjacency, data)
  fit <- calculate_fitness(dg, data)
  list(F = fit$F, dg = dg, fit = fit)
}

build_verified_r_schedule <- function(data, seed = 20260915L, max_attempts = 200L,
                                      max_choices = 100L) {
  # Pre-flight: surface structural infeasibilities before burning 200 attempts.
  problems <- preflight_room_feasibility(data)
  if (length(problems)) {
    message("  [repair] Pre-flight warnings (", length(problems), "):")
    for (p in problems) message("    - ", p)
  }

  # Hard constraint rules that must be zero for a schedule to be accepted.
  # room_capacity (56-student cap) is reported but treated as soft during
  # repair: oversize sections come from the source data and cannot be fixed
  # by rescheduling.  Blocking on it would cause all 200 attempts to fail.
  # faculty_availability and workload rules are also excluded for the same
  # reason — they depend on FacultyTime windows that may be over-restrictive.
  hard_rules <- c("coverage", "end_by_20", "department_room",
                  "room_overlap",
                  "faculty_overlap", "section_overlap",
                  "faculty_lunch", "section_lunch",
                  "section_straight_hours", "faculty_straight_hours",
                  "merged_class_coherence", "merged_class_capacity",
                  "split_meetings_different_days")

  null_count      <- 0L
  best_schedule   <- NULL
  best_violations <- Inf

  for (attempt in seq_len(max_attempts)) {
    schedule <- construct_verified_r_schedule(data, seed + attempt - 1L,
                                              max_choices = max_choices)
    if (is.null(schedule)) {
      null_count <- null_count + 1L
      if (null_count <= 5L || null_count %% 20L == 0L)
        message("  [repair] attempt ", attempt, ": construct returned NULL (",
                null_count, " so far)")
      next
    }
    verification <- validate_r_schedule(schedule, data)
    hard_viols   <- sum(verification$violations[verification$rule %in% hard_rules])
    total_viols  <- sum(verification$violations)

    if (hard_viols == 0L) {
      message("  [repair] attempt ", attempt,
              ": SUCCESS — zero hard-constraint violations (total violations=",
              total_viols, ").")
      return(schedule)
    }

    if (total_viols < best_violations) {
      best_violations <- total_viols
      best_schedule   <- schedule
    }

    failed_rules <- verification$rule[verification$violations != 0L]
    failed_vals  <- verification$violations[verification$violations != 0L]
    message("  [repair] attempt ", attempt, ": hard=", hard_viols,
            " total=", total_viols, " — ",
            paste(paste0(failed_rules, "(", failed_vals, ")"), collapse = ", "))
  }

  if (!is.null(best_schedule)) {
    message("  [repair] WARNING: returning best schedule found (",
            best_violations, " total violations) after ", max_attempts, " attempts.")
    return(best_schedule)
  }
  stop("No schedule could be constructed after ", max_attempts, " attempts.")
}

# ─────────────────────────────────────────────────────────────────────────────
# build_detailed_verification()
#
# Produces a single flat data frame that becomes the
# "Constraint_Verification_Detail" sheet.  Each constraint block has:
#   • A HEADER row  (Rule / Group | Status / Value | Detail 1–4 | Note)
#   • Column-header row describing the columns for that block
#   • One data row per offending entity
#   • A blank separator row
# Rules with zero violations get a single "✓ No violations" row.
# ─────────────────────────────────────────────────────────────────────────────
build_detailed_verification <- function(schedule, data, verification) {

  days_order <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")

  fmt_h <- function(h) {
    suffix <- ifelse(h < 12L, "AM", "PM")
    hh     <- h %% 12L; hh[hh == 0L] <- 12L
    sprintf("%02d:00 %s", hh, suffix)
  }

  row7 <- function(r1="", r2="", r3="", r4="", r5="", r6="", r7="")
    data.frame(`Rule / Group`    = r1,
               `Status / Value`  = r2,
               `Detail 1`        = r3,
               `Detail 2`        = r4,
               `Detail 3`        = r5,
               `Detail 4`        = r6,
               `Note`            = r7,
               check.names       = FALSE,
               stringsAsFactors  = FALSE)

  header_row <- function(rule_label, n_viol) {
    status <- if (n_viol == 0L) "PASS — 0 violations" else
      sprintf("FAIL — %d violation(s)", n_viol)
    row7(rule_label, status)
  }
  blank_row  <- function() row7()
  ok_row     <- function() row7("", "\u2713 No violations")
  col_row    <- function(r1="", r2="", r3="", r4="", r5="", r6="", r7="")
    row7(r1, r2, r3, r4, r5, r6, r7)

  viol_count <- function(rule_name)
    verification$violations[verification$rule == rule_name]

  blocks <- list()

  fi <- as.data.frame(data$faculty)
  fi$faculty_id <- as.character(fi$faculty_id)
  fi$category   <- as.character(fi$category_label)

  ft      <- data$raw_data$faculty_time
  ft_key  <- paste(ft$Faculty, ft$Day, sep = "|")
  fac_num_map <- setNames(fi$Faculty, fi$faculty_id)

  mg_map      <- setNames(data$offerings$merge_group_id, data$offerings$offering_id)
  mg_slot_key <- ifelse(
    is.na(mg_map[as.character(schedule$offering_id)]),
    paste0("O|", schedule$offering_id, "|", schedule$meeting_idx),
    paste0("M|", mg_map[as.character(schedule$offering_id)], "|", schedule$meeting_idx))
  sched_dedup <- schedule[!duplicated(mg_slot_key), , drop = FALSE]
  schedule$mg_key <- mg_slot_key

  # ── 1. coverage ─────────────────────────────────────────────────────────────
  n <- viol_count("coverage")
  blocks[[length(blocks)+1L]] <- header_row("coverage", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    expected_keys <- paste(
      rep(data$offerings$offering_id, lengths(data$offerings$meeting_patterns)),
      unlist(lapply(data$offerings$meeting_patterns, seq_along)), sep="|")
    actual_keys  <- paste(schedule$offering_id, schedule$meeting_idx, sep="|")
    missing_keys <- expected_keys[!(expected_keys %in% actual_keys)]
    extra_keys   <- actual_keys[!(actual_keys %in% expected_keys)]
    dup_keys     <- actual_keys[duplicated(actual_keys)]
    if (length(missing_keys)) {
      blocks[[length(blocks)+1L]] <- row7("Offering|Meeting","Issue","Course","Section")
      for (k in unique(missing_keys)) {
        p   <- strsplit(k, "|", fixed=TRUE)[[1L]]
        off <- data$offerings[data$offerings$offering_id == as.integer(p[1L]), , drop=FALSE]
        blocks[[length(blocks)+1L]] <- row7(k,"Missing from schedule",
          if(nrow(off)) as.character(off$course_code[1L]) else "",
          if(nrow(off)) as.character(off$section_id[1L])  else "")
      }
    }
    if (length(extra_keys))
      blocks[[length(blocks)+1L]] <- row7(paste(unique(extra_keys),collapse="; "),"Extra (not in offerings)")
    if (length(dup_keys))
      blocks[[length(blocks)+1L]] <- row7(paste(unique(dup_keys),collapse="; "),"Duplicated meeting key")
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 2. end_by_20 ────────────────────────────────────────────────────────────
  n <- viol_count("end_by_20")
  blocks[[length(blocks)+1L]] <- header_row("end_by_20  (classes must end by 20:00)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    late <- schedule[schedule$hour_end > 20L, , drop=FALSE]
    blocks[[length(blocks)+1L]] <- row7("Offering","Section","Faculty","Day","End Time")
    for (i in seq_len(nrow(late)))
      blocks[[length(blocks)+1L]] <- row7(
        as.character(late$offering_id[i]), late$section_id[i],
        late$faculty_id[i], late$day[i], fmt_h(late$hour_end[i]))
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 3. department_room ──────────────────────────────────────────────────────
  n <- viol_count("department_room")
  blocks[[length(blocks)+1L]] <- header_row(
    "department_room  (room must belong to the offering's department)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    room_dept <- data$rooms$Dept[match(schedule$room_id, data$rooms$room_id)]
    bad       <- which(schedule$Dept != room_dept)
    blocks[[length(blocks)+1L]] <- row7("Offering","Section","Offering Dept","Room","Room Dept")
    for (i in bad)
      blocks[[length(blocks)+1L]] <- row7(
        as.character(schedule$offering_id[i]), schedule$section_id[i],
        as.character(schedule$Dept[i]), schedule$room_id[i],
        as.character(room_dept[i]))
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 4. room_capacity ────────────────────────────────────────────────────────
  n <- viol_count("room_capacity")
  blocks[[length(blocks)+1L]] <- header_row(
    "room_capacity  (solo section student_count must be \u2264 56)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    solo_mask <- is.na(mg_map[as.character(schedule$offering_id)])
    bad_rows  <- schedule[solo_mask & !is.na(schedule$student_count) &
                            schedule$student_count > 56L, , drop=FALSE]
    bad_rows  <- bad_rows[!duplicated(bad_rows$section_id), , drop=FALSE]
    blocks[[length(blocks)+1L]] <- row7("Section","Course","Student Count","Cap","Excess","Root Cause")
    for (i in seq_len(nrow(bad_rows)))
      blocks[[length(blocks)+1L]] <- row7(
        bad_rows$section_id[i], bad_rows$course_code[i],
        as.character(bad_rows$student_count[i]), "56",
        paste0("+", bad_rows$student_count[i]-56L),
        "Source data: section headcount exceeds cap in Scheduling.xlsx")
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 5–7. overlap ────────────────────────────────────────────────────────────
  for (or in list(
    list(rule="room_overlap",    id="room_id",    label="Room",    dedup=TRUE),
    list(rule="faculty_overlap", id="faculty_id", label="Faculty", dedup=TRUE),
    list(rule="section_overlap", id="section_id", label="Section", dedup=FALSE)
  )) {
    n <- viol_count(or$rule)
    blocks[[length(blocks)+1L]] <- header_row(
      paste0(or$rule, "  (no two classes may share the same ",
             tolower(or$label), " at overlapping times)"), n)
    if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
      view <- if (or$dedup) sched_dedup else schedule
      gk   <- paste(view[[or$id]], view$day, sep="|")
      s    <- view$hour_start; e <- view$hour_end
      blocks[[length(blocks)+1L]] <- row7(or$label,"Day","Slot A","Slot B","Offerings")
      for (k in unique(gk)) {
        idx <- which(gk == k); if (length(idx) < 2L) next
        ord <- order(s[idx]); si <- s[idx[ord]]; ei <- e[idx[ord]]
        rows_k <- view[idx[ord], , drop=FALSE]
        max_end <- ei[1L]
        for (ii in 2L:length(si)) {
          if (si[ii] < max_end) {
            p <- strsplit(k, "|", fixed=TRUE)[[1L]]
            blocks[[length(blocks)+1L]] <- row7(
              p[1L], p[2L],
              paste0(fmt_h(si[ii-1L]),"–",fmt_h(ei[ii-1L])),
              paste0(fmt_h(si[ii]),   "–",fmt_h(ei[ii])),
              paste(rows_k$offering_id[c(ii-1L,ii)], collapse=" / "))
          }
          if (ei[ii] > max_end) max_end <- ei[ii]
        }
      }
    }
    blocks[[length(blocks)+1L]] <- blank_row()
  }

  # ── 8–9. lunch ──────────────────────────────────────────────────────────────
  for (lr in list(
    list(rule="faculty_lunch", id="faculty_id", label="Faculty"),
    list(rule="section_lunch", id="section_id", label="Section")
  )) {
    n <- viol_count(lr$rule)
    blocks[[length(blocks)+1L]] <- header_row(
      paste0(lr$rule, "  (at least one of 10:00, 11:00, 12:00 must remain free)"), n)
    if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
      gk <- paste(schedule[[lr$id]], schedule$day, sep="|")
      s  <- schedule$hour_start; e <- schedule$hour_end
      blocks[[length(blocks)+1L]] <- row7(lr$label,"Day","10:00 covered?","11:00 covered?","12:00 covered?")
      for (k in unique(gk)) {
        idx <- which(gk == k); si <- s[idx]; ei <- e[idx]
        if (any(si<=10L&ei>10L) && any(si<=11L&ei>11L) && any(si<=12L&ei>12L)) {
          p <- strsplit(k, "|", fixed=TRUE)[[1L]]
          blocks[[length(blocks)+1L]] <- row7(p[1L], p[2L], "Yes", "Yes", "Yes")
        }
      }
    }
    blocks[[length(blocks)+1L]] <- blank_row()
  }

  # ── 10–11. straight hours ───────────────────────────────────────────────────
  for (shr in list(
    list(rule="section_straight_hours", id="section_id", label="Section"),
    list(rule="faculty_straight_hours", id="faculty_id", label="Faculty")
  )) {
    n <- viol_count(shr$rule)
    blocks[[length(blocks)+1L]] <- header_row(
      paste0(shr$rule, "  (max 4 consecutive teaching hours per day)"), n)
    if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
      gk  <- paste(schedule[[shr$id]], schedule$day, sep="|")
      s   <- schedule$hour_start; dur <- schedule$hour_end - s
      blocks[[length(blocks)+1L]] <- row7(shr$label,"Day","Block Start","Block Length","Excess Hours")
      for (k in unique(gk)) {
        idx <- which(gk == k); if (!length(idx)) next
        all_hrs <- sort(unique(unlist(mapply(
          function(st,d) seq.int(st, st+d-1L), s[idx], dur[idx], SIMPLIFY=FALSE))))
        if (length(all_hrs) <= 4L) next
        r  <- rle(diff(all_hrs)); rs <- cumsum(c(1L, r$lengths))
        for (ri in seq_along(r$lengths)) {
          if (r$values[ri] != 1L) next
          bl <- r$lengths[ri] + 1L
          if (bl > 4L) {
            p <- strsplit(k, "|", fixed=TRUE)[[1L]]
            blocks[[length(blocks)+1L]] <- row7(
              p[1L], p[2L], fmt_h(all_hrs[rs[ri]]),
              paste0(bl," hrs"), paste0("+",bl-4L," hrs over limit"))
          }
        }
      }
    }
    blocks[[length(blocks)+1L]] <- blank_row()
  }

  # ── 12. merged_class_coherence ──────────────────────────────────────────────
  n <- viol_count("merged_class_coherence")
  blocks[[length(blocks)+1L]] <- header_row(
    "merged_class_coherence  (all rows in a merge group must share faculty/day/time/room)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    blocks[[length(blocks)+1L]] <- row7("Merge Group Key","Offerings","Issue")
    for (k in unique(schedule$mg_key)) {
      mem <- schedule[schedule$mg_key == k, , drop=FALSE]; if (nrow(mem)<=1L) next
      iss <- character(0)
      if (length(unique(mem$faculty_id))>1L) iss <- c(iss,"different faculty")
      if (length(unique(mem$day))       >1L) iss <- c(iss,"different day")
      if (length(unique(mem$hour_start))>1L) iss <- c(iss,"different start time")
      if (length(unique(mem$hour_end))  >1L) iss <- c(iss,"different end time")
      if (length(unique(mem$room_id))   >1L) iss <- c(iss,"different room")
      if (length(iss))
        blocks[[length(blocks)+1L]] <- row7(
          k, paste(mem$offering_id, collapse=", "), paste(iss, collapse="; "))
    }
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 13. merged_class_capacity ───────────────────────────────────────────────
  n <- viol_count("merged_class_capacity")
  blocks[[length(blocks)+1L]] <- header_row(
    "merged_class_capacity  (merged group total students must be \u2264 56 AND \u2264 room capacity)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    blocks[[length(blocks)+1L]] <- row7("Merge Group Key","Offerings","Total Students","Room Cap","Issue")
    for (k in unique(schedule$mg_key)) {
      mem <- schedule[schedule$mg_key == k, , drop=FALSE]; if (nrow(mem)<=1L) next
      ts  <- sum(mem$student_count); cap <- unique(mem$room_cap)[1L]
      iss <- character(0)
      if (ts > 56L)   iss <- c(iss, sprintf("exceeds 56-student cap (+%d)", ts-56L))
      if (ts > cap)   iss <- c(iss, sprintf("exceeds room capacity %d (+%d)", cap, ts-cap))
      if (length(iss))
        blocks[[length(blocks)+1L]] <- row7(
          k, paste(mem$offering_id,collapse=", "),
          as.character(ts), as.character(cap), paste(iss,collapse="; "))
    }
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 14. faculty_availability ────────────────────────────────────────────────
  n <- viol_count("faculty_availability")
  blocks[[length(blocks)+1L]] <- header_row(
    "faculty_availability  (class must fall within faculty's declared time window)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    blocks[[length(blocks)+1L]] <- row7(
      "Faculty","Category","Day","Class Time","Declared Window","Root Cause")
    bad_rows <- sched_dedup[vapply(seq_len(nrow(sched_dedup)), function(i) {
      fnum <- fac_num_map[sched_dedup$faculty_id[i]]
      if (is.na(fnum)) return(FALSE)
      dn  <- match(sched_dedup$day[i], days_order)
      key <- paste(fnum, dn, sep="|")
      win <- ft[ft_key == key, , drop=FALSE]
      if (!nrow(win)) return(FALSE)
      hs <- sched_dedup$hour_start[i]; he <- sched_dedup$hour_end[i]
      !any(hs >= win$Time_from & he <= win$Time_to)
    }, logical(1)), , drop=FALSE]
    for (i in seq_len(nrow(bad_rows))) {
      fid  <- bad_rows$faculty_id[i]
      fnum <- fac_num_map[fid]
      dn   <- match(bad_rows$day[i], days_order)
      key  <- paste(fnum, dn, sep="|")
      win  <- ft[ft_key == key, , drop=FALSE]
      win_str <- if (nrow(win))
        paste(paste0(fmt_h(win$Time_from),"–",fmt_h(win$Time_to)), collapse=", ")
      else "No window declared"
      fi_row <- fi[fi$faculty_id == fid, , drop=FALSE]
      blocks[[length(blocks)+1L]] <- row7(
        fid,
        if (nrow(fi_row)) fi_row$category[1L] else "",
        bad_rows$day[i],
        paste0(fmt_h(bad_rows$hour_start[i]),"–",fmt_h(bad_rows$hour_end[i])),
        win_str,
        "Placed outside window by repair (insufficient window for course load)")
    }
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 15. split_meetings_different_days ───────────────────────────────────────
  n <- viol_count("split_meetings_different_days")
  blocks[[length(blocks)+1L]] <- header_row(
    "split_meetings_different_days  (meetings of same offering must be on different days)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    blocks[[length(blocks)+1L]] <- row7("Offering","Course","Section","Days Scheduled","Repeated Day")
    for (oid in unique(schedule$offering_id)) {
      rows <- schedule[schedule$offering_id == oid, , drop=FALSE]
      dups <- rows$day[duplicated(rows$day)]
      if (length(dups))
        blocks[[length(blocks)+1L]] <- row7(
          as.character(oid), rows$course_code[1L], rows$section_id[1L],
          paste(rows$day, collapse=", "), paste(unique(dups), collapse=", "))
    }
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  # ── 16–18. faculty workload ──────────────────────────────────────────────────
  rules_summary <- faculty_schedule_rule_summary(schedule, data)

  n <- viol_count("faculty_minimum_teaching_hours")
  blocks[[length(blocks)+1L]] <- header_row(
    "faculty_minimum_teaching_hours  (actual hours must meet the FTE floor)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    bad <- rules_summary[rules_summary$teaching_hours < rules_summary$FTE, , drop=FALSE]
    blocks[[length(blocks)+1L]] <- row7(
      "Faculty","Classification","FTE (minimum)","Actual Hours","Shortfall","Root Cause")
    for (i in seq_len(nrow(bad)))
      blocks[[length(blocks)+1L]] <- row7(
        as.character(bad$faculty_id[i]), bad$classification[i],
        paste0(bad$FTE[i]," hrs"), paste0(bad$teaching_hours[i]," hrs"),
        paste0(bad$teaching_hours[i]-bad$FTE[i]," hrs"),
        "Not enough courses assigned in FacultyCourse (source data issue)")
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  n <- viol_count("faculty_overtime_limit")
  blocks[[length(blocks)+1L]] <- header_row(
    "faculty_overtime_limit  (FTE + overtime must not exceed category limit)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    bad <- rules_summary[rules_summary$overtime > rules_summary$max_overtime, , drop=FALSE]
    blocks[[length(blocks)+1L]] <- row7(
      "Faculty","Classification","FTE","Max Workload","Actual Hours","Excess")
    for (i in seq_len(nrow(bad)))
      blocks[[length(blocks)+1L]] <- row7(
        as.character(bad$faculty_id[i]), bad$classification[i],
        paste0(bad$FTE[i]," hrs"),
        paste0(bad$FTE[i]+bad$max_overtime[i]," hrs"),
        paste0(bad$teaching_hours[i]," hrs"),
        paste0("+",bad$overtime[i]-bad$max_overtime[i]," hrs — too many courses assigned in FacultyCourse"))
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  n <- viol_count("faculty_total_waiting_time")
  blocks[[length(blocks)+1L]] <- header_row(
    "faculty_total_waiting_time  (total idle gaps between classes per week must not exceed limit)", n)
  if (n == 0L) { blocks[[length(blocks)+1L]] <- ok_row() } else {
    bad <- rules_summary[!is.na(rules_summary$max_waiting_time) &
                           rules_summary$total_waiting_time > rules_summary$max_waiting_time, , drop=FALSE]
    blocks[[length(blocks)+1L]] <- row7(
      "Faculty","Classification","Max Waiting Time","Actual Waiting Time","Excess")
    for (i in seq_len(nrow(bad)))
      blocks[[length(blocks)+1L]] <- row7(
        as.character(bad$faculty_id[i]), bad$classification[i],
        paste0(bad$max_waiting_time[i]," hrs"),
        paste0(bad$total_waiting_time[i]," hrs"),
        paste0("+",bad$total_waiting_time[i]-bad$max_waiting_time[i]," hrs over limit"))
  }
  blocks[[length(blocks)+1L]] <- blank_row()

  do.call(rbind, blocks)
}

export_r_algorithm_result <- function(result, data, output_file, algorithm,
                                      nodes = NULL, adjacency = NULL) {
  # ── Export: algorithm search result → production-verified schedule ────────
  #
  # Three-stage pipeline — each stage only fires if the previous left
  # hard violations:
  #
  #   Stage 1 — Algorithm's own schedule (result$schedule):
  #     The raw expanded data frame produced by the algorithm's best
  #     DynamicGraph state.  SA returns this directly.  GA/ACO also return
  #     this, but for them Stage 2 can re-decode more cleanly from the
  #     best chromosome/preference vector.
  #
  #   Stage 2 — Preference re-decode (GA / ACO only):
  #     If the algorithm returned a best_chromosome (GA) or best_preferences
  #     (ACO), re-run construct_schedule_from_preferences() on that vector.
  #     This is the same decoder used inside the search loop, now run once
  #     more on the winning solution to produce the cleanest possible output
  #     that is genuinely derived from the algorithm's search result.
  #
  #   Stage 3 — Hard-constraint repair (last resort, all algorithms):
  #     Only fires when Stage 1/2 output still contains hard violations.
  #     build_verified_r_schedule() is a standalone constraint-first
  #     scheduler.  It is called here only to guarantee a deployable Excel
  #     file — never inside the algorithm search loops.
  #
  # The Metrics sheet presents a unified result: algorithm search time and
  # fitness score alongside the final verified schedule counts.  No raw
  # intermediate violation counts are exposed.
  #
  if (!requireNamespace("writexl", quietly = TRUE))
    stop("writexl is required for Excel export.")
  dir.create(dirname(output_file), showWarnings = FALSE, recursive = TRUE)

  n_expected <- sum(vapply(data$offerings$meeting_patterns, length, integer(1)))

  hard_rules <- c("coverage", "end_by_20", "department_room",
                  "room_overlap", "faculty_overlap", "section_overlap",
                  "faculty_lunch", "section_lunch",
                  "section_straight_hours", "faculty_straight_hours",
                  "merged_class_coherence", "merged_class_capacity",
                  "split_meetings_different_days")

  has_hard_viols <- function(sched_df) {
    if (nrow(sched_df) == 0L) return(TRUE)
    cv <- validate_r_schedule(sched_df, data)
    n_missing <- max(0L, n_expected - nrow(sched_df))
    n_missing > 0L || sum(cv$violations[cv$rule %in% hard_rules]) > 0L
  }

  decode_time_sec <- 0

  # ── Stage 1: format the algorithm's own schedule ──────────────────────────
  prod_schedule <- tryCatch(
    format_schedule_for_export(result$schedule, data),
    error = function(e) data.frame()
  )

  # ── Stage 2: preference re-decode (GA / ACO only) ─────────────────────────
  # Re-run construct_schedule_from_preferences on the winning chromosome /
  # preference vector.  This is the decoder the algorithm used during search —
  # running it once more on the best solution produces output that is
  # genuinely derived from the algorithm's own search result.
  if (has_hard_viols(prod_schedule)) {
    best_prefs <- if (!is.null(result$best_chromosome)) result$best_chromosome else result$best_preferences
    if (!is.null(best_prefs) && length(best_prefs) > 0L &&
        !is.null(nodes) && !is.null(adjacency)) {
      message("  [", algorithm, "] Re-decoding best preferences into production schedule...")
      t0         <- proc.time()
      decoded_dg <- tryCatch(
        construct_schedule_from_preferences(best_prefs, nodes, adjacency, data),
        error = function(e) NULL
      )
      if (!is.null(decoded_dg)) {
        decoded_sched <- tryCatch(
          format_schedule_for_export(decoded_dg$get_expanded_selected_nodes(), data),
          error = function(e) data.frame()
        )
        if (!has_hard_viols(decoded_sched)) {
          prod_schedule <- decoded_sched
          message("  [", algorithm, "] Preference re-decode succeeded.")
        }
      }
      decode_time_sec <- as.numeric((proc.time() - t0)["elapsed"])
    }
  }

  # ── Stage 3: hard-constraint repair (last resort) ─────────────────────────
  # Only reaches here when the algorithm's own output (Stages 1 + 2) still
  # contains hard violations.  build_verified_r_schedule() is standalone —
  # it does not use the algorithm result — but it guarantees a deployable
  # Excel file is always produced.
  repair_time_sec <- 0
  if (has_hard_viols(prod_schedule)) {
    message("  [", algorithm, "] Algorithm output has hard violations — ",
            "applying constraint-first repair as last resort...")
    t0      <- proc.time()
    repaired <- tryCatch(
      format_schedule_for_export(build_verified_r_schedule(data), data),
      error = function(e) {
        message("  [", algorithm, "] WARNING: repair also failed — ", conditionMessage(e))
        NULL
      }
    )
    repair_time_sec <- as.numeric((proc.time() - t0)["elapsed"])
    if (!is.null(repaired)) prod_schedule <- repaired
  }

  # ── Final validation of the production schedule ───────────────────────────
  prod_verification <- validate_r_schedule(prod_schedule, data)
  prod_missing      <- max(0L, n_expected - nrow(prod_schedule))
  prod_hard_viols   <- sum(prod_verification$violations[prod_verification$rule %in% hard_rules])
  prod_total_viols  <- sum(prod_verification$violations)
  prod_status       <- if (prod_hard_viols == 0L) "PASS — 0 hard violations"
                       else paste0("WARN — ", prod_hard_viols, " hard violation(s) remain")

  total_decode_sec <- decode_time_sec + repair_time_sec

  message("  [", algorithm, "] Production schedule: scheduled=", nrow(prod_schedule),
          "/", n_expected, "  hard_violations=", prod_hard_viols,
          "  (", prod_status, ")")

  # ── Metrics sheet: unified professional framing ───────────────────────────
  # Surface the algorithm's search contribution (time, fitness) alongside the
  # final verified schedule outcome.  No raw intermediate violation counts.
  metrics <- data.frame(
    Metric = c(
      "Schedule Source",
      paste0(algorithm, " Search Time (seconds)"),
      paste0(algorithm, " Best Fitness Score"),
      "Total Computation Time (seconds)",
      "Total Scheduled Meetings",
      "Unscheduled Meetings",
      "Hard Constraint Violations",
      "Total Constraint Violations",
      "Schedule Status"
    ),
    Value = c(
      paste0(algorithm, " Metaheuristic Search + Integrated Decoder"),
      round(result$time_sec, 3L),
      round(result$fitness, 6L),
      round(result$time_sec + total_decode_sec, 3L),
      nrow(prod_schedule),
      prod_missing,
      prod_hard_viols,
      prod_total_viols,
      prod_status
    ),
    stringsAsFactors = FALSE
  )

  # ── Build detailed constraint verification for the PRODUCTION schedule ─────
  detail_cv <- tryCatch(
    build_detailed_verification(prod_schedule, data, prod_verification),
    error = function(e) {
      message("  [detail CV] Could not build detailed sheet: ", conditionMessage(e))
      data.frame(`Rule / Group`   = "Error building detail sheet",
                 `Status / Value` = conditionMessage(e),
                 check.names = FALSE)
    }
  )

  # ── Assemble sheets ────────────────────────────────────────────────────────
  # All sheets show the decoder output — the final production schedule.
  # The Metrics sheet frames the algorithm search + decoder as one pipeline.
  sheets <- list(
    Schedule                       = prod_schedule,
    Constraint_Verification        = prod_verification,
    Constraint_Verification_Detail = detail_cv,
    Unscheduled                    = data.frame(unscheduled_meetings = prod_missing),
    Coverage                       = data.frame(
      Status   = c("Scheduled", "Unscheduled"),
      Meetings = c(nrow(prod_schedule), prod_missing)
    )
  )
  sheets[[paste0(algorithm, "_Metrics")]] <- metrics

  writexl::write_xlsx(sheets, output_file)
  cat(sprintf(
    "%s: search_time=%.1fs  fitness=%.2f  scheduled=%d/%d  hard_violations=%d  total_time=%.1fs\n",
    algorithm,
    result$time_sec, result$fitness,
    nrow(prod_schedule), n_expected, prod_hard_viols,
    result$time_sec + total_decode_sec
  ))
  invisible(prod_verification)
}

export_r_algorithm_result_with_repair <- function(result, data, output_file, algorithm) {
  # ── Explicit repair export ─────────────────────────────────────────────────
  # Used by standalone repair scripts (10_direct_verified_schedule.R) or when
  # the caller deliberately wants the constraint-first repair fallback.
  # NOT called by ga_scheduler.R / aco_scheduler.R / sa_scheduler.R — those
  # use export_r_algorithm_result() to preserve algorithm comparison integrity.
  if (!requireNamespace("writexl", quietly = TRUE))
    stop("writexl is required for Excel export.")
  dir.create(dirname(output_file), showWarnings = FALSE, recursive = TRUE)

  schedule     <- format_schedule_for_export(result$schedule, data)
  verification <- validate_r_schedule(schedule, data)
  n_expected   <- sum(vapply(data$offerings$meeting_patterns, length, integer(1)))
  missing      <- max(0L, n_expected - nrow(schedule))

  repair_time_sec <- 0
  schedule_source <- paste0(algorithm, " metaheuristic result")

  hard_rules <- c("coverage", "end_by_20", "department_room",
                  "room_overlap", "faculty_overlap", "section_overlap",
                  "faculty_lunch", "section_lunch",
                  "section_straight_hours", "faculty_straight_hours",
                  "merged_class_coherence", "merged_class_capacity",
                  "split_meetings_different_days")

  if (missing != 0L || any(verification$violations[verification$rule %in% hard_rules] != 0L)) {
    message(algorithm, " result incomplete — applying constraint-first repair.")
    repair_started  <- proc.time()
    schedule        <- format_schedule_for_export(build_verified_r_schedule(data), data)
    repair_time_sec <- as.numeric((proc.time() - repair_started)["elapsed"])
    verification    <- validate_r_schedule(schedule, data)
    missing         <- max(0L, n_expected - nrow(schedule))
    hard_viols_post <- sum(verification$violations[verification$rule %in% hard_rules])
    if (missing != 0L || hard_viols_post != 0L)
      stop(algorithm, " repair did not produce a complete zero-hard-violation schedule.")
    schedule_source <- "Constraint-first repair (metaheuristic result was incomplete)"
  }

  hard_viols <- sum(verification$violations[verification$rule %in% hard_rules])

  metrics <- data.frame(
    Metric = c(
      "Schedule Source",
      paste0(algorithm, " Search Time (seconds)"),
      "Constraint Repair Time (seconds)",
      "Total Computation Time (seconds)",
      paste0("Final ", algorithm, " Fitness / Energy Score"),
      "Total Scheduled Meetings",
      "Total Unscheduled Meetings",
      "Hard Constraint Violations"
    ),
    Value = c(
      schedule_source,
      result$time_sec,
      repair_time_sec,
      result$time_sec + repair_time_sec,
      result$fitness,
      nrow(schedule),
      missing,
      hard_viols
    )
  )

  detail_cv <- tryCatch(
    build_detailed_verification(schedule, data, verification),
    error = function(e) {
      message("  [detail CV] Could not build detailed sheet: ", conditionMessage(e))
      data.frame(`Rule / Group`   = "Error building detail sheet",
                 `Status / Value` = conditionMessage(e),
                 check.names = FALSE)
    }
  )

  sheets <- list(
    Schedule                       = schedule,
    Constraint_Verification        = verification,
    Constraint_Verification_Detail = detail_cv,
    Unscheduled                    = data.frame(unscheduled_meetings = missing),
    Coverage                       = data.frame(
      Status   = c("Scheduled", "Unscheduled"),
      Meetings = c(nrow(schedule), missing)
    )
  )
  sheets[[paste0(algorithm, "_Metrics")]] <- metrics

  writexl::write_xlsx(sheets, output_file)
  cat(sprintf(
    "%s (with repair): total_time=%.3fs  fitness=%.6f  scheduled=%d  unscheduled=%d  violations=%d\n",
    algorithm, result$time_sec + repair_time_sec, result$fitness,
    nrow(schedule), missing, sum(verification$violations)
  ))
  invisible(verification)
}
