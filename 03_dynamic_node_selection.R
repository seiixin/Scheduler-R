###############################################################################
# 03_dynamic_node_selection.R — Dynamic Graph Reduction & Node Management
# Eliminates conflicting nodes dynamically during selection process
###############################################################################

if (!exists("require_packages")) source("02_graph_construction.R")
require_packages(c("dplyr", "tidyr"))

DynamicGraph <- setRefClass("DynamicGraph",
  fields = list(
    nodes = "tbl_df",
    adjacency = "ANY",
    active_mask = "logical",
    active_remaining = "integer",
    n_nodes = "integer",
    selected_ids = "integer",
    selected_nodes_df = "tbl_df",
    data = "list",
    offerings_coverage = "list"
  ),
  methods = list(
    initialize = function(nodes, adjacency_matrix, data_ref) {
      nodes <<- nodes
      adjacency <<- adjacency_matrix
      n_nodes <<- nrow(nodes)
      active_mask <<- rep(TRUE, n_nodes)
      active_remaining <<- n_nodes
      selected_ids <<- integer(0)
      selected_nodes_df <<- tibble()
      data <<- data_ref
      coverage <- as.list(rep(0, nrow(data_ref$offerings)))
      names(coverage) <- as.character(data_ref$offerings$offering_id)
      offerings_coverage <<- coverage
    },

    member_offering_ids_for_node = function(node_id) {
      nr <- nodes[node_id, , drop = FALSE]
      if ("member_offering_ids" %in% names(nr)) {
        m <- nr$member_offering_ids[[1]]
        if (length(m)) return(as.integer(m))
      }
      as.integer(nr$offering_id[1])
    },

    member_section_ids_for_node = function(node_id) {
      nr <- nodes[node_id, , drop = FALSE]
      if ("member_section_ids" %in% names(nr)) {
        m <- nr$member_section_ids[[1]]
        if (length(m)) return(as.character(m))
      }
      as.character(nr$section_id[1])
    },

    get_active_nodes = function() {
      which(active_mask)
    },

    get_node = function(node_id) {
      nodes %>% filter(node_id == !!node_id)
    },

    is_compatible_with_selected = function(node_id) {
      if (!active_mask[node_id]) return(FALSE)
      if (length(selected_ids) == 0) return(TRUE)
      all(adjacency[node_id, selected_ids] == 1)
    },

    get_conflicts_for_node = function(node_id) {
      if (!active_mask[node_id]) return(integer(0))
      which(adjacency[node_id, ] == 0 & active_mask)
    },

    dynamic_conflict_check = function(node_row) {
      if (nrow(selected_nodes_df) == 0) return(FALSE)
      FALSE
    },

    get_expanded_selected_nodes = function() {
      if (length(selected_ids) == 0L) return(tibble())
      rows <- list()
      k <- 1L
      for (nid in selected_ids) {
        nr <- nodes[nid, , drop = FALSE]
        memb_oids <- if ("member_offering_ids" %in% names(nr) && length(nr$member_offering_ids[[1]])) {
          as.integer(nr$member_offering_ids[[1]])
        } else as.integer(nr$offering_id[1])
        memb_students <- if ("member_student_counts" %in% names(nr) && length(nr$member_student_counts[[1]])) {
          as.integer(nr$member_student_counts[[1]])
        } else {
          sec_id <- if (length(nr$section_id)) as.character(nr$section_id[1]) else NA_character_
          sc <- data$sections$student_count[data$sections$section_id == sec_id]
          if (length(sc) && !is.na(sc)) as.integer(sc) else 40L
        }
        for (mi in seq_along(memb_oids)) {
          oid <- memb_oids[mi]
          off_row <- data$offerings[data$offerings$offering_id == oid, , drop = FALSE]
          sc_val <- if (length(memb_students) >= mi) memb_students[mi] else {
            if (nrow(off_row) && !is.null(off_row$student_count) && length(off_row$student_count) && !is.na(off_row$student_count)) {
              as.integer(off_row$student_count[1])
            } else 40L
          }
          sec_id_val <- if (nrow(off_row)) as.character(off_row$section_id[1]) else as.character(nr$section_id[1])
          course_code_val <- if (nrow(off_row)) as.character(off_row$course_code[1]) else as.character(nr$course_code[1])
          rows[[k]] <- data.frame(
            node_id = as.integer(nr$node_id[1]),
            offering_id = as.integer(oid),
            course_code = course_code_val,
            section_id = sec_id_val,
            faculty_id = as.character(nr$faculty_id[1]),
            meeting_idx = as.integer(nr$meeting_idx[1]),
            n_meetings = as.integer(nr$n_meetings[1]),
            day = as.character(nr$day[1]),
            hour_start = as.integer(nr$hour_start[1]),
            hour_end = as.integer(nr$hour_end[1]),
            duration = as.integer(nr$duration[1]),
            room_id = as.character(nr$room_id[1]),
            room_type = as.character(nr$room_type[1]),
            room_cap = as.integer(nr$room_cap[1]),
            base_weight = as.integer(nr$base_weight[1]),
            is_lab = isTRUE(nr$is_lab[1]),
            is_hard = isTRUE(nr$is_hard[1]),
            requires_twice_weekly = isTRUE(nr$requires_twice_weekly[1]),
            time_slot_ids = I(list(nr$time_slot_ids[[1]])),
            stringsAsFactors = FALSE
          )
          k <- k + 1L
        }
      }
      do.call(rbind, rows) %>% as_tibble()
    },

    select_node = function(node_id) {
      if (!active_mask[node_id]) {
        return(FALSE)
      }

      node_row <- nodes[node_id, , drop = FALSE]
      if (nrow(node_row) == 0) return(FALSE)

      if (!is_compatible_with_selected(node_id)) {
        active_mask[node_id] <<- FALSE
        active_remaining <<- active_remaining - 1L
        return(FALSE)
      }

      if (dynamic_conflict_check(node_row)) {
        active_mask[node_id] <<- FALSE
        active_remaining <<- active_remaining - 1L
        return(FALSE)
      }

      selected_ids <<- c(selected_ids, node_id)
      selected_nodes_df <<- rbind(selected_nodes_df, node_row)

      member_oids <- .self$member_offering_ids_for_node(node_id)
      for (oid in member_oids) {
        off_id_chr <- as.character(oid)
        if (!is.null(offerings_coverage[[off_id_chr]])) {
          offerings_coverage[[off_id_chr]] <<- offerings_coverage[[off_id_chr]] + 1L
        }
      }

      conf_mask <- adjacency[node_id, ] == 0L
      conf_mask[node_id] <- TRUE
      newly_deactivated <- sum(active_mask & conf_mask)
      active_mask[conf_mask] <<- FALSE
      active_remaining <<- active_remaining - newly_deactivated

      TRUE
    },

    eliminate_dynamic_conflicts = function(selected_row) {
      to_eliminate <- integer(0)
      active_count <- sum(active_mask)
      if (active_count == 0L) return(to_eliminate)
      if (active_count > 800L) return(to_eliminate)
      # For merged units, straight-hour elimination must apply to every member
      # section and the shared faculty.  Use the graph node directly if available.
      sel_nid <- as.integer(selected_row$node_id[1])
      if (!is.na(sel_nid) && sel_nid > 0L && sel_nid <= n_nodes) {
        selected_sections <- .self$member_section_ids_for_node(sel_nid)
      } else {
        selected_sections <- as.character(selected_row$section_id)[1]
      }
      selected_faculty <- as.character(selected_row$faculty_id)[1]
      selected_day <- as.character(selected_row$day)[1]
      selected_start <- as.integer(selected_row$hour_start)[1]
      selected_end <- as.integer(selected_row$hour_end)[1]
      sel_hours <- selected_start:(selected_end - 1L)
      prior_section <- tibble()
      prior_faculty <- tibble()
      if (nrow(selected_nodes_df) > 0) {
        # Gather all prior placements on this day that share ANY member section.
        all_sec_any <- character(0)
        for (i in seq_len(nrow(selected_nodes_df))) {
          nid_i <- as.integer(selected_nodes_df$node_id[i])
          if (!is.na(nid_i) && nid_i > 0L && nid_i <= n_nodes) {
            ss <- .self$member_section_ids_for_node(nid_i)
          } else ss <- as.character(selected_nodes_df$section_id[i])
          if (any(ss %in% selected_sections)) all_sec_any <- c(all_sec_any, ss)
        }
        all_sec_any <- unique(all_sec_any)
        # Instead of exact section match, build a combined view by checking
        # each existing selected node's overlap with the incoming sections.
        for (i in seq_len(nrow(selected_nodes_df))) {
          nid_i <- as.integer(selected_nodes_df$node_id[i])
          if (!is.na(nid_i) && nid_i > 0L && nid_i <= n_nodes) {
            s_i <- .self$member_section_ids_for_node(nid_i)
          } else s_i <- as.character(selected_nodes_df$section_id[i])
          if (any(s_i %in% selected_sections) && selected_nodes_df$day[i] == selected_day) {
            prior_section <- bind_rows(prior_section, selected_nodes_df[i, , drop = FALSE])
          }
          if (selected_nodes_df$faculty_id[i] == selected_faculty && selected_nodes_df$day[i] == selected_day) {
            prior_faculty <- bind_rows(prior_faculty, selected_nodes_df[i, , drop = FALSE])
          }
        }
      }
      get_hrs <- function(df) {
        hrs <- integer(0)
        for (i in seq_len(nrow(df))) {
          tids <- unlist(df$time_slot_ids[[i]])
          for (tid in tids) {
            h <- data$time_slots$hour_start[data$time_slots$time_slot_id == tid][1]
            if (!is.na(h)) hrs <- c(hrs, as.integer(h))
          }
        }
        sort(unique(hrs))
      }
      sec_hours <- get_hrs(prior_section)
      fac_hours <- get_hrs(prior_faculty)
      if (length(sec_hours) + length(sel_hours) < 4L && 
          length(fac_hours) + length(sel_hours) < 4L) {
        return(to_eliminate)
      }
      mask_sec_vec <- logical(n_nodes)
      mask_fac_vec <- as.character(nodes$faculty_id) == selected_faculty &
                     as.character(nodes$day) == selected_day & active_mask
      for (ss in selected_sections) {
        # Use member_section_ids check first; fall back to rep section_id.
        match_ss <- rep(FALSE, n_nodes)
        if ("member_section_ids" %in% names(nodes)) {
          for (aid in which(active_mask & as.character(nodes$day) == selected_day)) {
            m <- nodes$member_section_ids[[aid]]
            if (length(m) && any(as.character(ss) %in% as.character(m))) match_ss[aid] <- TRUE
          }
        }
        match_ss <- match_ss | (as.character(nodes$section_id) == as.character(ss))
        mask_sec_vec <- mask_sec_vec | match_ss
      }
      mask_sec_vec <- mask_sec_vec & as.character(nodes$day) == selected_day & active_mask
      check_idx <- unique(c(which(mask_sec_vec), which(mask_fac_vec)))
      if (length(check_idx) == 0L) return(to_eliminate)
      check_consec <- function(prior, sel, cand, lim = 4L) {
        all_h <- sort(unique(c(prior, sel, cand)))
        if (length(all_h) <= lim) return(FALSE)
        r <- rle(diff(all_h))
        any(r$values == 1L & r$lengths >= (lim - 1L))
      }
      for (aid in check_idx) {
        cand <- nodes[aid, ]
        cstart <- as.integer(cand$hour_start)[1]
        cend <- as.integer(cand$hour_end)[1]
        chrs <- cstart:(cend - 1L)
        cand_secs <- if ("member_section_ids" %in% names(cand) && length(cand$member_section_ids[[1]])) {
          as.character(cand$member_section_ids[[1]])
        } else as.character(cand$section_id[1])
        cf <- as.character(cand$faculty_id[1])
        bad <- FALSE
        if (any(cand_secs %in% selected_sections) && length(sec_hours) > 0L) {
          bad <- check_consec(sec_hours, sel_hours, chrs, 4L)
        }
        if (!bad && cf == selected_faculty && length(fac_hours) > 0L) {
          bad <- check_consec(fac_hours, sel_hours, chrs, 4L)
        }
        if (bad) to_eliminate <- c(to_eliminate, aid)
      }
      unique(to_eliminate)
    },

    undo_last_selection = function() {
      if (length(selected_ids) == 0L) return(FALSE)
      last_id <- selected_ids[length(selected_ids)]
      selected_ids <<- selected_ids[-length(selected_ids)]
      if (nrow(selected_nodes_df) > 0L) {
        selected_nodes_df <<- selected_nodes_df[-nrow(selected_nodes_df), ]
      }

      member_oids <- .self$member_offering_ids_for_node(last_id)
      for (oid in member_oids) {
        off_id_chr <- as.character(oid)
        if (!is.null(offerings_coverage[[off_id_chr]])) {
          offerings_coverage[[off_id_chr]] <<- max(0L, offerings_coverage[[off_id_chr]] - 1L)
        }
      }

      active_mask <<- rep(TRUE, n_nodes)
      for (sid in selected_ids) {
        confs <- which(adjacency[sid, ] == 0L)
        active_mask[confs] <<- FALSE
        active_mask[sid] <<- FALSE
      }
      active_remaining <<- sum(active_mask)
      TRUE
    },

    reset = function() {
      active_mask <<- rep(TRUE, n_nodes)
      active_remaining <<- n_nodes
      selected_ids <<- integer(0)
      selected_nodes_df <<- tibble()
      coverage <- as.list(rep(0L, nrow(data$offerings)))
      names(coverage) <- as.character(data$offerings$offering_id)
      offerings_coverage <<- coverage
    },

    get_coverage = function() {
      required <- vapply(seq_len(nrow(data$offerings)), function(i) {
        pat <- data$offerings$meeting_patterns[[i]]
        max(1L, length(unlist(pat)))
      }, integer(1))
      achieved <- as.integer(unlist(offerings_coverage[as.character(data$offerings$offering_id)]))
      total_offerings <- length(required)
      covered <- sum(achieved >= required)
      missing_meetings <- sum(pmax(required - achieved, 0L))
      list(
        total_offerings = total_offerings,
        covered_offerings = covered,
        coverage_ratio = covered / total_offerings,
        missing_meetings = missing_meetings,
        n_selected = length(selected_ids),
        offerings_coverage_snapshot = offerings_coverage
      )
    },

    get_valid_nodes_for_offering = function(offering_id) {
      # A merged unit hosts multiple offerings; find nodes whose member_offering_ids
      # includes the requested offering_id.
      has_memb <- "member_offering_ids" %in% names(nodes)
      matches <- rep(FALSE, nrow(nodes))
      if (has_memb) {
        for (i in which(active_mask)) {
          m <- nodes$member_offering_ids[[i]]
          if (length(m) && (as.integer(offering_id) %in% as.integer(m))) matches[i] <- TRUE
        }
      }
      matches <- matches | (as.integer(nodes$offering_id) == as.integer(offering_id))
      off_nodes <- nodes %>% filter(matches, node_id %in% which(active_mask))
      off_nodes
    },

    get_weighted_candidates = function(weight_vec = NULL) {
      if (is.null(weight_vec)) weight_vec <- nodes$base_weight
      candidates <- which(active_mask)
      if (length(candidates) == 0) return(tibble())
      tibble(node_id = candidates, weight = weight_vec[candidates]) %>%
        arrange(desc(weight))
    }
  )
)

schedule_greedy_construct <- function(dg, weight_vec = NULL, max_iter = 10000) {
  dg$reset()
  if (is.null(weight_vec)) weight_vec <- dg$nodes$base_weight

  has_unit <- "unit_key" %in% names(dg$nodes)
  if (has_unit) {
    meeting_groups <- dg$nodes %>%
      distinct(unit_key, meeting_idx)
    group_id <- function(df) paste(df$unit_key, df$meeting_idx, sep = "::")
    cand_filter <- function(uk, midx) {
      dg$nodes %>%
        filter(unit_key == !!uk, meeting_idx == !!midx,
               node_id %in% dg$get_active_nodes())
    }
  } else {
    meeting_groups <- dg$nodes %>%
      distinct(offering_id, meeting_idx)
    group_id <- function(df) paste(df$offering_id, df$meeting_idx, sep = "::")
    cand_filter <- function(oid, midx) {
      dg$nodes %>%
        filter(offering_id == !!oid, meeting_idx == !!midx,
               node_id %in% dg$get_active_nodes())
    }
  }
  failed_groups <- character(0)

  for (iter in 1:max_iter) {
    selected_groups <- if (nrow(dg$selected_nodes_df) > 0) {
      group_id(dg$selected_nodes_df)
    } else character(0)
    group_keys <- group_id(meeting_groups)
    remaining <- setdiff(group_keys, c(selected_groups, failed_groups))

    if (length(remaining) == 0) break

    active_ids <- dg$get_active_nodes()
    active_keys <- group_id(dg$nodes[active_ids, , drop = FALSE])
    available_counts <- tabulate(match(active_keys, remaining), nbins = length(remaining))
    if (any(available_counts == 0L)) {
      failed_groups <- c(failed_groups, remaining[which(available_counts == 0L)])
      next
    }
    group_key <- remaining[which.min(available_counts)]
    group_parts <- strsplit(group_key, "::", fixed = TRUE)[[1]]
    id_1 <- group_parts[1]
    midx <- as.integer(group_parts[2])

    cand <- cand_filter(id_1, midx) %>%
      mutate(eff_weight = weight_vec[node_id], tie_break = runif(n())) %>%
      arrange(desc(eff_weight), desc(tie_break))

    if (nrow(cand) == 0) {
      failed_groups <- c(failed_groups, group_key)
      next
    }

    placed <- FALSE
    for (ci in seq_len(nrow(cand))) {
      if (dg$select_node(as.integer(cand$node_id[ci]))) {
        placed <- TRUE
        break
      }
    }
    if (!placed) failed_groups <- c(failed_groups, group_key)
  }

  invisible(dg)
}

message("03_dynamic_node_selection.R loaded.")
