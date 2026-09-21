###############################################################################
# 02_graph_construction.R — Graph-Based Representation for TUPC UCTP
# Builds Vertex-Weighted Compatibility Graph via Adjacency Matrix
###############################################################################

if (!exists("require_packages")) source("01_data_loader.R")
require_packages(c("dplyr", "tidyr", "Matrix"))

build_candidate_nodes <- function(data, max_nodes = Inf, sample_seed = 2025,
                                  max_rooms_per_offering = 6, max_starts_per_day = 6) {
  offerings     <- data$offerings
  time_slots    <- data$time_slots
  rooms         <- data$rooms
  blocked       <- data$blocked_slots
  sections      <- data$sections
  has_merge     <- !is.null(offerings$merge_group_id)

  nid <- 1L
  set.seed(sample_seed)

  ################################################################
  # Build scheduling units. When merge_group_id is assigned the
  # unit spans all member offerings; otherwise it covers just one
  # offering.  Candidate nodes are generated once per unit so
  # merged offerings always share the exact same (day, start,
  # room, faculty) placement options.
  ################################################################
  if (has_merge) {
    units <- list()
    seen_unit_keys <- character(0)
    unit_member_offerings <- list()
    unit_merged_student <- list()
    for (o in seq_len(nrow(offerings))) {
      off <- offerings[o, ]
      mgid <- off$merge_group_id
      uk <- if (!is.null(mgid) && !is.na(mgid)) paste0("M|", mgid) else paste0("O|", off$offering_id)
      if (!(uk %in% seen_unit_keys)) {
        seen_unit_keys <- c(seen_unit_keys, uk)
        new_idx <- length(seen_unit_keys)
        units[[new_idx]] <- list(
          unit_key = uk,
          is_merged = grepl("^M\\|", uk),
          merge_group_id = if (grepl("^M\\|", uk)) as.integer(sub("^M\\|", "", uk)) else NA_integer_,
          rep_offering = off
        )
        unit_member_offerings[[new_idx]] <- integer(0L)
        unit_merged_student[[new_idx]] <- integer(0L)
      }
      ui <- which(seen_unit_keys == uk)
      unit_member_offerings[[ui]] <- c(unit_member_offerings[[ui]], as.integer(off$offering_id))
      sc <- if (!is.null(off$student_count) && length(off$student_count) && !is.na(off$student_count)) as.integer(off$student_count) else 40L
      unit_merged_student[[ui]] <- c(unit_merged_student[[ui]], sc)
    }
  } else {
    units <- lapply(seq_len(nrow(offerings)), function(o) {
      list(unit_key = paste0("O|", offerings$offering_id[o]),
           is_merged = FALSE, merge_group_id = NA_integer_,
           rep_offering = offerings[o, ])
    })
    unit_member_offerings <- lapply(offerings$offering_id, function(x) as.integer(x))
    unit_merged_student <- lapply(seq_len(nrow(offerings)), function(o) {
      sc <- offerings$student_count[o]
      if (is.null(sc) || length(sc) == 0L || is.na(sc)) 40L else as.integer(sc)
    })
  }

  required_meetings <- sum(vapply(seq_len(length(units)), function(ui) {
    pat <- units[[ui]]$rep_offering$meeting_patterns
    if (is.list(pat) && length(pat) >= 1L) {
      p1 <- pat[[1L]]
      if (is.list(p1) && length(p1) >= 1L) length(as.integer(p1[[1L]]))
      else if (is.vector(p1) || is.factor(p1)) length(as.integer(p1))
      else length(as.integer(pat))
    } else length(as.integer(pat))
  }, integer(1)))
  nodes_per_meeting <- if (is.finite(max_nodes)) {
    max(1L, floor(max_nodes / max(1L, required_meetings)))
  } else {
    Inf
  }

  all_nodes <- list()
  all_slots <- list()
  unit_member_offerings_col <- list()
  unit_member_section_col <- list()
  unit_member_student_col <- list()

  for (ui in seq_len(length(units))) {
    unit <- units[[ui]]
    off <- unit$rep_offering
    member_oids <- unit_member_offerings[[ui]]
    member_stu_counts <- unit_merged_student[[ui]]
    merged_student_sum <- as.integer(sum(member_stu_counts))
    # Collect all section_ids for members for later adjacency conflict checks
    member_sec_ids <- character(0)
    for (moid in member_oids) {
      moff <- offerings[offerings$offering_id == moid, , drop = FALSE]
      if (nrow(moff)) member_sec_ids <- c(member_sec_ids, as.character(moff$section_id[1]))
    }
    member_sec_ids <- unique(member_sec_ids)

    pat_list <- off$meeting_patterns
    pattern <- NULL
    if (is.list(pat_list)) {
      if (length(pat_list) >= 1L) {
        p1 <- pat_list[[1L]]
        if (is.list(p1) && length(p1) >= 1L) pattern <- as.integer(p1[[1L]])
        else if (is.vector(p1) || is.factor(p1)) pattern <- as.integer(p1)
      }
    } else {
      pattern <- as.integer(pat_list)
    }
    if (length(pattern) == 0L || any(is.na(pattern))) {
      tu <- as.integer(off$total_units)
      if (length(tu) == 0L || is.na(tu[1L])) tu <- 3L
      pattern <- tu[1L]
    }
    n_meetings <- length(pattern)

    req_type <- off$room_type_required
    if (length(req_type) == 0L || is.na(req_type) || is.null(req_type)) req_type <- "Lecture"
    req_type <- as.character(req_type)[1L]

    room_candidates <- rooms %>%
      filter(room_type == req_type |
             (room_type == "Lecture" & req_type == "Lecture"))

    # For merged units use the combined student count for room capacity.
    need_capacity <- if (unit$is_merged) merged_student_sum else {
      sc1 <- member_stu_counts[1]
      if (length(sc1) == 0L || is.na(sc1)) 40L else sc1
    }
    room_candidates <- room_candidates %>% filter(as.integer(capacity) >= need_capacity)
    if (nrow(room_candidates) == 0L) next
    if (nrow(room_candidates) > max_rooms_per_offering) {
      room_candidates <- room_candidates %>%
        slice_sample(n = max_rooms_per_offering)
    }
    room_candidates <- as.data.frame(room_candidates)
    room_candidates <- room_candidates[sample.int(nrow(room_candidates)), , drop = FALSE]

    eligible_time <- as.data.frame(time_slots %>%
      filter(!time_slot_id %in% blocked))
    eligible_time$day <- as.character(eligible_time$day)

    days_list <- sample(unique(eligible_time$day))
    if (length(days_list) == 0L) next

    sec_id_rep <- as.character(off$section_id[1])
    if (length(sec_id_rep) == 0L || is.na(sec_id_rep)) sec_id_rep <- "UNKSEC"

    for (m in 1:n_meetings) {
      meeting_node_count <- 0L
      per_day_budget <- if (is.finite(nodes_per_meeting)) {
        max(1L, ceiling(nodes_per_meeting / max(1L, length(days_list))))
      } else {
        Inf
      }
      meeting_len <- as.integer(pattern[m])
      if (is.na(meeting_len) || meeting_len < 1L) meeting_len <- 1L

      for (d in days_list) {
        day_node_count <- 0L
        day_slots <- eligible_time[eligible_time$day == d, , drop = FALSE]
        if (nrow(day_slots) == 0L) next
        day_slots <- day_slots[order(as.integer(day_slots$hour_start)), , drop = FALSE]
        starts <- sort(unique(as.integer(day_slots$hour_start)))
        if (length(starts) == 0L) next

        valid_starts <- integer(0L)
        valid_slot_list <- list()
        for (s in starts) {
          sched_hours <- as.integer(s + 0L:(meeting_len - 1L))
          if (max(sched_hours) > max(starts)) next
          slot_mask <- as.integer(day_slots$hour_start) %in% sched_hours
          if (sum(slot_mask) != meeting_len) next
          slot_ids <- as.integer(day_slots$time_slot_id[slot_mask])
          if (length(slot_ids) != meeting_len) next
          if (any(slot_ids %in% as.integer(blocked))) next
          valid_starts <- c(valid_starts, s)
          valid_slot_list[[length(valid_slot_list) + 1L]] <- slot_ids
        }
        if (length(valid_starts) == 0L) next

        day_order <- sample.int(length(valid_starts))
        valid_starts <- valid_starts[day_order]
        valid_slot_list <- valid_slot_list[day_order]

        if (length(valid_starts) > max_starts_per_day) {
          keep_idx <- sort(sample.int(length(valid_starts), max_starts_per_day))
          valid_starts <- valid_starts[keep_idx]
          valid_slot_list <- valid_slot_list[keep_idx]
        }

        room_order <- sample.int(nrow(room_candidates))
        for (vs in seq_along(valid_starts)) {
          s <- valid_starts[vs]
          slot_ids <- valid_slot_list[[vs]]
          sched_hours <- as.integer(s + 0L:(meeting_len - 1L))
          for (r in room_order) {
            rm_row <- room_candidates[r, , drop = FALSE]
            rn <- list(
              node_id              = nid,
              offering_id          = as.integer(off$offering_id)[1L],
              course_code          = if (length(off$course_code) && !is.na(off$course_code)) as.character(off$course_code)[1L] else "",
              section_id           = sec_id_rep,
              faculty_id           = if (length(off$faculty_id) && !is.na(off$faculty_id)) as.character(off$faculty_id)[1L] else "",
              meeting_idx          = as.integer(m),
              n_meetings           = as.integer(n_meetings),
              day                  = d,
              hour_start           = as.integer(min(sched_hours)),
              hour_end             = as.integer(max(sched_hours) + 1L),
              duration             = as.integer(meeting_len),
              room_id              = as.character(rm_row$room_id)[1L],
              room_type            = as.character(rm_row$room_type)[1L],
              room_cap             = as.integer(rm_row$capacity)[1L],
              base_weight          = 100L,
              is_lab               = isTRUE(as.logical(off$is_lab)),
              is_hard              = isTRUE(as.logical(off$is_hard)),
              requires_twice_weekly = isTRUE(as.logical(off$requires_twice_weekly)),
              unit_key             = unit$unit_key,
              is_merged_unit       = unit$is_merged,
              merge_group_id       = unit$merge_group_id
            )
            all_nodes[[length(all_nodes) + 1L]] <- rn
            all_slots[[length(all_slots) + 1L]] <- slot_ids
            unit_member_offerings_col[[length(unit_member_offerings_col) + 1L]] <- as.integer(member_oids)
            unit_member_section_col[[length(unit_member_section_col) + 1L]] <- as.character(member_sec_ids)
            unit_member_student_col[[length(unit_member_student_col) + 1L]] <- as.integer(member_stu_counts)
            nid <- nid + 1L
            meeting_node_count <- meeting_node_count + 1L
            day_node_count <- day_node_count + 1L
            if (day_node_count >= per_day_budget || meeting_node_count >= nodes_per_meeting) break
          }
          if (meeting_node_count >= nodes_per_meeting) break
          if (day_node_count >= per_day_budget) break
        }
        if (meeting_node_count >= nodes_per_meeting) break
      }
      if (meeting_node_count >= nodes_per_meeting) next
    }
  }

  if (length(all_nodes) == 0L) {
    nodes <- tibble(
      node_id = integer(0), offering_id = integer(0),
      course_code = character(0), section_id = character(0),
      faculty_id = character(0), meeting_idx = integer(0),
      n_meetings = integer(0), day = character(0),
      hour_start = integer(0), hour_end = integer(0),
      duration = integer(0), room_id = character(0),
      room_type = character(0), room_cap = integer(0),
      time_slot_ids = structure(list(), class = "AsIs"),
      base_weight = integer(0),
      is_lab = logical(0), is_hard = logical(0),
      requires_twice_weekly = logical(0),
      unit_key = character(0), is_merged_unit = logical(0),
      merge_group_id = integer(0),
      member_offering_ids = structure(list(), class = "AsIs"),
      member_section_ids = structure(list(), class = "AsIs"),
      member_student_counts = structure(list(), class = "AsIs")
    )
    message("Generated 0 candidate nodes.")
    return(nodes)
  }

  nodes <- tibble(
    node_id              = as.integer(vapply(all_nodes, function(r) r$node_id, numeric(1))),
    offering_id          = as.integer(vapply(all_nodes, function(r) r$offering_id, numeric(1))),
    course_code          = vapply(all_nodes, function(r) r$course_code, character(1)),
    section_id           = vapply(all_nodes, function(r) r$section_id, character(1)),
    faculty_id           = vapply(all_nodes, function(r) r$faculty_id, character(1)),
    meeting_idx          = as.integer(vapply(all_nodes, function(r) r$meeting_idx, numeric(1))),
    n_meetings           = as.integer(vapply(all_nodes, function(r) r$n_meetings, numeric(1))),
    day                  = vapply(all_nodes, function(r) r$day, character(1)),
    hour_start           = as.integer(vapply(all_nodes, function(r) r$hour_start, numeric(1))),
    hour_end             = as.integer(vapply(all_nodes, function(r) r$hour_end, numeric(1))),
    duration             = as.integer(vapply(all_nodes, function(r) r$duration, numeric(1))),
    room_id              = vapply(all_nodes, function(r) r$room_id, character(1)),
    room_type            = vapply(all_nodes, function(r) r$room_type, character(1)),
    room_cap             = as.integer(vapply(all_nodes, function(r) r$room_cap, numeric(1))),
    base_weight          = as.integer(vapply(all_nodes, function(r) r$base_weight, numeric(1))),
    is_lab               = vapply(all_nodes, function(r) r$is_lab, logical(1)),
    is_hard              = vapply(all_nodes, function(r) r$is_hard, logical(1)),
    requires_twice_weekly = vapply(all_nodes, function(r) r$requires_twice_weekly, logical(1)),
    unit_key             = vapply(all_nodes, function(r) r$unit_key, character(1)),
    is_merged_unit       = vapply(all_nodes, function(r) r$is_merged_unit, logical(1)),
    merge_group_id       = as.integer(vapply(all_nodes, function(r) {
      if (length(r$merge_group_id) && !is.na(r$merge_group_id)) r$merge_group_id else NA_integer_
    }, numeric(1))),
    time_slot_ids        = I(all_slots),
    member_offering_ids  = I(unit_member_offerings_col),
    member_section_ids   = I(unit_member_section_col),
    member_student_counts = I(unit_member_student_col)
  )
  nodes$node_id <- seq_len(nrow(nodes))
  # Cap enforcement uses unit_key + meeting_idx as the scheduling group so
  # merged units are treated as one group, not split across offerings.
  if (is.finite(max_nodes) && nrow(nodes) > max_nodes) {
    group_key <- if ("unit_key" %in% names(nodes)) {
      paste(nodes$unit_key, nodes$meeting_idx, sep = "::")
    } else {
      paste(nodes$offering_id, nodes$meeting_idx, sep = "::")
    }
    groups <- split(seq_len(nrow(nodes)), group_key)
    minimum_needed <- length(groups)
    if (minimum_needed > max_nodes) {
      stop("max_nodes (", max_nodes, ") is below the ", minimum_needed,
           " candidates required to represent every offering meeting. Increase MAX_NODES.")
    }
    chosen <- vapply(groups, function(idx) sample(idx, 1L), integer(1))
    remaining <- unlist(lapply(groups, function(idx) idx[-1L]), use.names = FALSE)
    if (length(chosen) < max_nodes && length(remaining) > 0L) {
      chosen <- c(chosen, remaining[seq_len(min(max_nodes - length(chosen), length(remaining)))])
    }
    chosen <- sort(as.integer(chosen))
    nodes <- nodes[chosen, , drop = FALSE]
    nodes$node_id <- seq_len(nrow(nodes))
  }
  # Coverage: every offering must have every meeting represented. For merged
  # units, one node covers multiple offerings.
  covered_offering_meetings <- character(0)
  for (i in seq_len(nrow(nodes))) {
    moids <- nodes$member_offering_ids[[i]]
    for (oid in moids) {
      covered_offering_meetings <- c(covered_offering_meetings,
                                     paste(oid, nodes$meeting_idx[i], sep = "::"))
    }
  }
  covered_offering_meetings <- unique(covered_offering_meetings)
  required_groups <- unlist(lapply(seq_len(nrow(offerings)), function(i) {
    paste(offerings$offering_id[i], seq_len(max(1L, length(unlist(offerings$meeting_patterns[[i]])))), sep = "::")
  }), use.names = FALSE)
  missing_groups <- setdiff(required_groups, covered_offering_meetings)
  if (length(missing_groups) > 0L) {
    stop("Candidate generation omitted ", length(missing_groups),
         " offering-meeting(s); scheduling cannot proceed with incomplete coverage.")
  }
  n_units <- if ("unit_key" %in% names(nodes)) length(unique(nodes$unit_key)) else nrow(offerings)
  message("Generated ", nrow(nodes), " candidate nodes (", n_units, " scheduling units) from ", nrow(offerings), " offerings.")
  nodes
}

check_hard_conflict <- function(nodeA, nodeB) {
  # Same unit_key + same meeting_idx = same scheduling unit cannot be placed
  # twice (duplicate selection).
  if ("unit_key" %in% names(nodeA) && "unit_key" %in% names(nodeB) &&
      !is.na(nodeA$unit_key[1]) && !is.na(nodeB$unit_key[1]) &&
      nodeA$unit_key[1] == nodeB$unit_key[1] &&
      nodeA$meeting_idx[1] == nodeB$meeting_idx[1]) return(TRUE)
  # Fallback: same offering_id + same meeting_idx = duplicate placement.
  if (nodeA$offering_id == nodeB$offering_id &&
      nodeA$meeting_idx == nodeB$meeting_idx) return(TRUE)
  # Split meeting check: if ANY member offering is shared by A and B and
  # meeting_idx differs, they must be on different days.
  share_member <- FALSE
  if (!is.null(nodeA$member_offering_ids) && length(nodeA$member_offering_ids[[1]]) &&
      !is.null(nodeB$member_offering_ids) && length(nodeB$member_offering_ids[[1]])) {
    share_member <- length(intersect(nodeA$member_offering_ids[[1]], nodeB$member_offering_ids[[1]])) > 0
  } else {
    share_member <- nodeA$offering_id == nodeB$offering_id
  }
  if (share_member && nodeA$meeting_idx != nodeB$meeting_idx && nodeA$day == nodeB$day) return(TRUE)

  time_overlap <- length(intersect(nodeA$time_slot_ids[[1]], nodeB$time_slot_ids[[1]])) > 0
  if (!time_overlap) return(FALSE)

  # Section overlap: any shared member section between A and B = conflict.
  sections_A <- if (!is.null(nodeA$member_section_ids) && length(nodeA$member_section_ids[[1]])) {
    nodeA$member_section_ids[[1]]
  } else nodeA$section_id[1]
  sections_B <- if (!is.null(nodeB$member_section_ids) && length(nodeB$member_section_ids[[1]])) {
    nodeB$member_section_ids[[1]]
  } else nodeB$section_id[1]
  any_shared_section <- length(intersect(as.character(sections_A), as.character(sections_B))) > 0

  same_faculty  <- nodeA$faculty_id == nodeB$faculty_id
  same_room     <- nodeA$room_id == nodeB$room_id

  if (any_shared_section || same_faculty || same_room) return(TRUE)

  FALSE
}

build_adjacency_matrix <- function(nodes, verbose = TRUE, use_sparse = TRUE) {
  n <- nrow(nodes)
  if (verbose) message("Building adjacency matrix for ", n, " nodes...")

  if (n == 0L) {
    empty_mat <- matrix(integer(0), nrow = 0L, ncol = 0L)
    if (use_sparse && requireNamespace("Matrix", quietly = TRUE)) {
      return(Matrix::Matrix(empty_mat, sparse = TRUE))
    }
    return(empty_mat)
  }

  required_cols <- c("day", "hour_start", "hour_end", "faculty_id", "section_id",
                     "room_id", "offering_id", "meeting_idx")
  for (cc in required_cols) if (!(cc %in% colnames(nodes))) stop("Missing column in nodes: ", cc)

  day_chr   <- as.character(nodes$day)
  fs_chr    <- as.character(nodes$faculty_id)
  sec_chr   <- as.character(nodes$section_id)
  rm_chr    <- as.character(nodes$room_id)
  hst_int   <- as.integer(nodes$hour_start)
  hen_int   <- as.integer(nodes$hour_end)
  off_int   <- as.integer(nodes$offering_id)
  midx_int  <- as.integer(nodes$meeting_idx)

  has_unit <- "unit_key" %in% names(nodes)
  unit_chr  <- if (has_unit) as.character(nodes$unit_key) else as.character(off_int)
  unit_meeting <- paste(unit_chr, midx_int, sep = "-")

  # Merge-aware: build a list of char-vec section-sets per node and offering-sets
  # per node, so we can detect overlap between merged units without scanning
  # nested lists inside the hot loop.
  sec_sets <- if ("member_section_ids" %in% names(nodes)) {
    lapply(nodes$member_section_ids, function(x) if (length(x)) as.character(x) else as.character(sec_chr))
  } else {
    as.list(sec_chr)
  }
  off_sets <- if ("member_offering_ids" %in% names(nodes)) {
    lapply(nodes$member_offering_ids, function(x) if (length(x)) as.character(x) else as.character(off_int))
  } else {
    as.list(as.character(off_int))
  }
  # Precompute section sets as hashable strings for vectorized overlap detection.
  sec_hash <- vapply(sec_sets, function(s) paste(sort(unique(s)), collapse = "|"), character(1))
  off_hash <- vapply(off_sets, function(o) paste(sort(unique(o)), collapse = "|"), character(1))

  adj_matrix <- matrix(1L, nrow = n, ncol = n)
  diag(adj_matrix) <- 0L
  for (i in seq_len(n)) {
    time_overlap <- day_chr == day_chr[i] &
      hst_int < hen_int[i] & hen_int > hst_int[i]
    same_faculty <- fs_chr != "" & fs_chr[i] != "" & fs_chr == fs_chr[i]
    same_room <- rm_chr != "" & rm_chr[i] != "" & rm_chr == rm_chr[i]

    # Section overlap: any shared section id between sets (merged-aware).
    # Quick shortcut: use hash for identical sets; then fall back to explicit
    # string matching on the union of sections from both nodes.
    same_section <- logical(n)
    if (sec_hash[i] != "") {
      # Nodes with identical hash share the exact section set (covers merged
      # pairs). Nodes with different hash may still share 1 section in common.
      same_section_hash <- sec_hash == sec_hash[i]
      # Build individual per-section membership flags.
      secs_i <- sec_sets[[i]]
      same_section_any <- rep(FALSE, n)
      for (sc in secs_i) {
        same_section_any <- same_section_any | vapply(sec_sets, function(ss) sc %in% ss, logical(1))
      }
      same_section <- same_section_hash | same_section_any
    } else {
      same_section <- sec_chr != "" & sec_chr[i] != "" & sec_chr == sec_chr[i]
    }

    # Same-day split meeting: any shared offering id + different meeting idx + same day.
    same_day_split_meeting <- logical(n)
    offs_i <- off_sets[[i]]
    for (oi in offs_i) {
      share_off <- vapply(off_sets, function(os) oi %in% os, logical(1))
      same_day_split_meeting <- same_day_split_meeting |
        (share_off & midx_int != midx_int[i] & day_chr == day_chr[i])
    }

    conflicts <- unit_meeting == unit_meeting[i] | same_day_split_meeting |
      (time_overlap & (same_faculty | same_section | same_room))
    adj_matrix[i, conflicts] <- 0L
  }

  if (use_sparse && requireNamespace("Matrix", quietly = TRUE)) {
    adj_matrix <- Matrix::Matrix(adj_matrix, sparse = TRUE)
  }

  if (verbose) {
    n_edges <- sum(adj_matrix) / 2
    message("Adjacency matrix complete: ", n, " nodes, ", n_edges, " compatible edges.")
    if (n > 1) message("Density: ", round(2 * n_edges / (n * (n - 1)), 4))
  }

  adj_matrix
}

.node_member_section_ids <- function(node) {
  if (!is.null(nrow(node)) && nrow(node) > 0L) {
    if ("member_section_ids" %in% names(node) && is.list(node$member_section_ids)) {
      v <- node$member_section_ids[[1]]
      if (length(v) > 0L) return(as.character(v))
    }
    return(as.character(node$section_id[1]))
  } else {
    if (!is.null(node$member_section_ids) && length(node$member_section_ids)) {
      v <- if (is.list(node$member_section_ids)) node$member_section_ids[[1]] else node$member_section_ids
      if (length(v) > 0L) return(as.character(v))
    }
    return(as.character(node$section_id[1]))
  }
}

.nodes_all_member_section_ids <- function(nodes_df) {
  if (nrow(nodes_df) == 0L) return(character(0))
  has_m <- "member_section_ids" %in% names(nodes_df) && is.list(nodes_df$member_section_ids)
  out <- character(0)
  for (i in seq_len(nrow(nodes_df))) {
    if (has_m) {
      v <- nodes_df$member_section_ids[[i]]
      if (length(v) > 0L) { out <- c(out, as.character(v)); next }
    }
    out <- c(out, as.character(nodes_df$section_id[i]))
  }
  unique(out)
}

.nodes_hours_for_member_sections <- function(nodes_df, target_sections, data, new_slots = NULL) {
  if (nrow(nodes_df) == 0L && is.null(new_slots)) return(numeric(0))
  has_m <- "member_section_ids" %in% names(nodes_df) && is.list(nodes_df$member_section_ids)
  all_hours <- numeric(0)
  if (nrow(nodes_df) > 0L) {
    for (r in seq_len(nrow(nodes_df))) {
      mems <- if (has_m) {
        v <- nodes_df$member_section_ids[[r]]
        if (length(v) > 0L) as.character(v) else as.character(nodes_df$section_id[r])
      } else as.character(nodes_df$section_id[r])
      if (!any(mems %in% target_sections)) next
      tids <- unlist(nodes_df$time_slot_ids[[r]])
      all_hours <- c(all_hours, sapply(tids, function(sid) data$time_slots$hour_start[data$time_slots$time_slot_id == sid][1]))
    }
  }
  if (!is.null(new_slots)) {
    all_hours <- c(all_hours, sapply(new_slots, function(sid) data$time_slots$hour_start[data$time_slots$time_slot_id == sid][1]))
  }
  all_hours
}

detect_straight_hour_conflict <- function(selected_nodes, new_node, data, limit_straight = 4) {
  if (nrow(selected_nodes) == 0) return(FALSE)
  new_slots <- new_node$time_slot_ids[[1]]

  new_section_ids <- .node_member_section_ids(new_node)
  new_faculty_id <- new_node$faculty_id[1]

  sec_related <- selected_nodes %>% filter(day == new_node$day)
  if (length(new_section_ids) && nrow(sec_related) > 0L) {
    sec_hours <- .nodes_hours_for_member_sections(sec_related, new_section_ids, data, new_slots)
    sec_hours <- unique(sec_hours)
    if (length(sec_hours) > limit_straight) {
      sec_hours <- sort(sec_hours)
      runs <- rle(diff(sec_hours))
      consec_idx <- which(runs$values == 1 & runs$lengths >= limit_straight)
      if (length(consec_idx) > 0) return(TRUE)
    }
  }

  fac_related <- selected_nodes %>% filter(faculty_id == new_faculty_id, day == new_node$day)
  if (nrow(fac_related) > 0L) {
    fac_hours <- numeric(0)
    for (r in seq_len(nrow(fac_related))) {
      tids <- unlist(fac_related$time_slot_ids[[r]])
      fac_hours <- c(fac_hours, sapply(tids, function(sid) data$time_slots$hour_start[data$time_slots$time_slot_id == sid][1]))
    }
    fac_hours <- c(fac_hours, sapply(new_slots, function(sid) data$time_slots$hour_start[data$time_slots$time_slot_id == sid][1]))
    fac_hours <- unique(fac_hours)
    if (length(fac_hours) > limit_straight) {
      fac_hours <- sort(fac_hours)
      runs <- rle(diff(fac_hours))
      consec_idx <- which(runs$values == 1 & runs$lengths >= limit_straight)
      if (length(consec_idx) > 0) return(TRUE)
    }
  }
  FALSE
}

check_lunch_break_violation <- function(selected_nodes, new_node, data) {
  new_section_ids <- .node_member_section_ids(new_node)
  new_faculty_id <- new_node$faculty_id[1]
  new_slots <- new_node$time_slot_ids[[1]]

  entities_section <- lapply(new_section_ids, function(sid) {
    list(col = "section_id", val = sid, is_sec = TRUE)
  })
  entities_faculty <- list(list(col = "faculty_id", val = new_faculty_id, is_sec = FALSE))
  entities_to_check <- c(entities_section, entities_faculty)

  for (e in entities_to_check) {
    is_sec <- isTRUE(e$is_sec); val <- e$val
    if (is_sec) {
      day_nodes <- selected_nodes %>% filter(day == new_node$day)
      all_hours <- .nodes_hours_for_member_sections(day_nodes, as.character(val), data, new_slots)
    } else {
      related <- selected_nodes %>% filter(faculty_id == val, day == new_node$day)
      all_hours <- numeric(0)
      for (r in seq_len(nrow(related))) {
        tids <- unlist(related$time_slot_ids[[r]])
        all_hours <- c(all_hours, sapply(tids, function(sid) data$time_slots$hour_start[data$time_slots$time_slot_id == sid][1]))
      }
      all_hours <- c(all_hours, sapply(new_slots, function(sid) data$time_slots$hour_start[data$time_slots$time_slot_id == sid][1]))
    }
    all_hours <- sort(unique(all_hours))
    if (length(all_hours) == 0) next
    if (all(c(10L, 11L, 12L) %in% all_hours)) {
      return(TRUE)
    }
  }
  FALSE
}

check_max_consecutive_gap_students <- function(selected_nodes, new_node, data, max_gap = 2) {
  new_section_ids <- .node_member_section_ids(new_node)
  new_slots <- new_node$time_slot_ids[[1]]
  day_nodes <- selected_nodes %>% filter(day == new_node$day)
  if (nrow(day_nodes) == 0L) return(FALSE)

  for (sid in new_section_ids) {
    all_hours <- .nodes_hours_for_member_sections(day_nodes, as.character(sid), data, new_slots)
    all_hours <- sort(unique(all_hours))
    if (length(all_hours) <= 1L) next
    gaps <- diff(all_hours) - 1L
    if (any(gaps > max_gap)) return(TRUE)
  }
  FALSE
}

check_workload_limit <- function(selected_nodes, new_node, data) {
  fac_val <- new_node$faculty_id[1]
  faculty_row <- data$faculty %>% filter(faculty_id == fac_val)
  if (nrow(faculty_row) == 0) return(FALSE)

  related <- selected_nodes %>% filter(faculty_id == fac_val)
  if (nrow(related) > 0L) {
    key <- paste(related$day, related$hour_start, related$hour_end, sep = "|")
    related <- related[!duplicated(key), , drop = FALSE]
  }
  total_hours <- sum(related$duration) + new_node$duration[1]
  if (total_hours > faculty_row$max_workload[1]) return(TRUE)
  FALSE
}

check_merged_capacity <- function(selected_nodes, new_node, data, max_cap = 56) {
  new_room_id <- new_node$room_id[1]
  new_day <- new_node$day[1]
  new_start <- new_node$hour_start[1]
  new_end <- new_node$hour_end[1]

  sec_nodes <- selected_nodes %>%
    filter(room_id == new_room_id, day == new_day,
           hour_start < new_end, hour_end > new_start) %>%
    bind_rows(new_node)
  if (nrow(sec_nodes) <= 1L) return(FALSE)

  has_m <- "member_student_counts" %in% names(sec_nodes) && is.list(sec_nodes$member_student_counts)
  total_students <- 0
  for (i in seq_len(nrow(sec_nodes))) {
    if (has_m) {
      v <- sec_nodes$member_student_counts[[i]]
      if (length(v) > 0L) { total_students <- total_students + sum(v); next }
    }
    sid_val <- sec_nodes$section_id[i]
    srow <- data$sections %>% filter(section_id == sid_val)
    if (nrow(srow) > 0L) total_students <- total_students + srow$student_count[1]
  }
  total_students > max_cap
}

message("02_graph_construction.R loaded.")
