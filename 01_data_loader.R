###############################################################################
# 01_data_loader.R — Data Loading & Synthetic Data Generation for TUPC UCTP
# SY 2025-2026 First Semester
###############################################################################

require_packages <- function(pkgs) {
  lib_dir <- Sys.getenv("R_UPC_LIBDIR", unset = file.path(getwd(), "R_libs"))
  if (!dir.exists(lib_dir)) {
    dir.create(lib_dir, showWarnings = FALSE, recursive = TRUE)
  }
  if (!(lib_dir %in% .libPaths())) {
    .libPaths(c(lib_dir, .libPaths()))
  }
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

require_packages(c("dplyr", "tidyr", "stringr", "readxl"))

# The operational data source is the pre-converted CSV set.  Keeping the
# inputs separate avoids loading the much larger workbook on every run.
CSV_DATA_DIR <- file.path(getwd(), "files", "Data-CourseInfo,Data-DeptRoom,Data-FacultyCourse")

generate_meeting_patterns <- function(total_units, is_lab = FALSE) {
  if (is_lab) {
    if (total_units == 3)  return(list(c(3)))
    if (total_units == 6)  return(list(c(3, 3)))
    if (total_units == 9)  return(list(c(3, 3, 3)))
    if (total_units == 12) return(list(c(4, 4, 4)))
    return(list(c(total_units)))
  } else {
    if (total_units <= 2) return(list(c(total_units)))
    if (total_units == 3) return(list(c(2, 1), c(3)))
    if (total_units == 4) return(list(c(2, 2), c(3, 1), c(4)))
    if (total_units == 5) return(list(c(3, 2), c(4, 1)))
    return(list(c(total_units)))
  }
}

# The client workbook's w/admin(0)_or_none(1) field is a three-way
# classification: 0 = with administrative duties, 1 = full time, 2 = part
# time.  Derived fields keep the limit interpretation consistent everywhere.
apply_faculty_scheduling_rules <- function(faculty) {
  admin_flag <- if ("AdminFlag" %in% names(faculty)) as.integer(faculty$AdminFlag) else
    dplyr::case_when(faculty$category == 0L ~ 0L, faculty$category == 2L ~ 2L, TRUE ~ 1L)
  faculty$AdminFlag <- admin_flag
  faculty$category <- dplyr::case_when(admin_flag == 0L ~ 0L, admin_flag == 1L ~ 1L,
                                        admin_flag == 2L ~ 2L, TRUE ~ 1L)
  faculty$category_label <- c("With Admin", "Full-Time", "Part-Time")[faculty$category + 1L]
  faculty$has_admin_function <- faculty$category == 0L
  faculty$FTE <- as.integer(faculty$FTE)
  faculty$min_teaching_hours <- faculty$FTE
  faculty$max_overtime_hours <- dplyr::case_when(faculty$category == 0L ~ 20L,
                                                   faculty$category == 1L ~ 24L,
                                                   TRUE ~ 35L)
  faculty$max_workload <- faculty$FTE + faculty$max_overtime_hours
  # Part-time waiting capacity depends on final overtime, so it is computed
  # per schedule by faculty_schedule_rule_summary().
  faculty$max_waiting_hours <- dplyr::case_when(faculty$category == 0L ~ 50L - faculty$FTE,
                                                 faculty$category == 1L ~ 17L,
                                                 TRUE ~ NA_integer_)
  faculty
}

faculty_schedule_rule_summary <- function(schedule, data) {
  faculty <- data$faculty
  total_hours <- setNames(numeric(nrow(faculty)), as.character(faculty$faculty_id))
  if (nrow(schedule)) {
    scheduled <- rowsum(as.numeric(schedule$duration), as.character(schedule$faculty_id), reorder = FALSE)
    matched_faculty <- intersect(rownames(scheduled), names(total_hours))
    total_hours[matched_faculty] <- scheduled[matched_faculty, 1]
  }
  waiting <- setNames(numeric(nrow(faculty)), names(total_hours))
  if (nrow(schedule)) for (day_schedule in split(schedule, paste(schedule$faculty_id, schedule$day, sep = "|"))) {
    fid <- as.character(day_schedule$faculty_id[1])
    waiting[fid] <- waiting[fid] + max(0, max(day_schedule$hour_end) - min(day_schedule$hour_start) - sum(day_schedule$duration))
  }
  overtime <- total_hours[as.character(faculty$faculty_id)] - as.numeric(faculty$FTE)
  waiting_limit <- ifelse(faculty$category == 0L, 50 - as.numeric(faculty$FTE),
                          ifelse(faculty$category == 1L, 17, NA_real_))
  data.frame(faculty_id = faculty$faculty_id, classification = faculty$category_label,
             FTE = as.numeric(faculty$FTE), teaching_hours = unname(total_hours[as.character(faculty$faculty_id)]),
             overtime = overtime, max_overtime = as.numeric(faculty$max_overtime_hours),
             total_waiting_time = unname(waiting[as.character(faculty$faculty_id)]),
             max_waiting_time = waiting_limit, stringsAsFactors = FALSE)
}

generate_synthetic_data <- function() {
  set.seed(2025)

  days <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")

  hour_slots <- seq(7, 20, by = 1)
  time_slots <- expand.grid(day = days, hour_start = hour_slots) %>%
    mutate(
      time_slot_id = row_number(),
      hour_end = hour_start + 1
    ) %>%
    as_tibble()

  blocked_slots <- time_slots %>%
    filter(
      (day == "Monday" & hour_start == 7) |
      (day == "Wednesday" & hour_start %in% c(11, 12))
    ) %>%
    pull(time_slot_id)

  colleges <- c("CET", "CAS", "CBA", "CCIT", "COE")
  programs <- list(
    CET  = c("BSCE", "BSEE", "BSME"),
    CAS  = c("BSBio", "BSMath", "BAComm"),
    CBA  = c("BSBA", "BSA"),
    CCIT = c("BSCS", "BSIT"),
    COE  = c("BSECE", "BSCpE")
  )
  yr_lvls <- 1:4

  course_codes <- c(
    "GEC01", "GEC02", "GEC03", "GEC04", "GEC05", "GEC06",
    "MATH101", "MATH102", "MATH201", "MATH202",
    "PHYS101", "PHYS102", "CHEM101",
    "ENG101", "ENG102",
    "PROG101", "PROG201", "DSA301",
    "EE101", "ME101", "CE101", "ECE101",
    "PE101", "PE102", "NSTP1", "NSTP2"
  )

  hard_courses <- c("MATH101", "MATH102", "MATH201", "MATH202",
                    "PHYS101", "PHYS102", "CHEM101", "DSA301",
                    "EE101", "ME101", "CE101", "ECE101")

  courses <- tibble(
    course_code = course_codes,
    course_name = paste("Course", course_codes),
    total_units = sample(c(2, 3, 4, 5), length(course_codes), replace = TRUE, prob = c(0.2, 0.5, 0.2, 0.1)),
    is_lab = sample(c(FALSE, TRUE), length(course_codes), replace = TRUE, prob = c(0.75, 0.25)),
    is_hard = course_code %in% hard_courses,
    room_type_required = ifelse(is_lab, sample(c("PhysicsLab", "CompLab", "ChemLab", "EnggLab"),
                                               length(course_codes), replace = TRUE), "Lecture"),
    requires_twice_weekly = (total_units == 3 & !is_lab)
  )

  sections <- list()
  sid <- 1
  for (clg in colleges) {
    for (prog in programs[[clg]]) {
      for (yr in yr_lvls) {
        n_regular_sections <- sample(1:2, 1)
        for (sec in 1:n_regular_sections) {
          sections[[sid]] <- tibble(
            section_id = paste0(clg, "-", prog, "-", yr, "-", LETTERS[sec]),
            program = prog,
            college = clg,
            year_level = yr,
            student_count = sample(35:45, 1),
            is_irregular = FALSE
          )
          sid <- sid + 1
        }
        if (runif(1) < 0.4) {
          sections[[sid]] <- tibble(
            section_id = paste0(clg, "-", prog, "-", yr, "-IRR"),
            program = prog,
            college = clg,
            year_level = yr,
            student_count = sample(20:35, 1),
            is_irregular = TRUE
          )
          sid <- sid + 1
        }
      }
    }
  }
  sections <- bind_rows(sections)

  ranks <- c("Instructor", "Assistant Professor", "Associate Professor", "Full Professor")
  categories <- c(0, 1, 2)
  cat_labels <- c("Admin", "Full-Time", "Part-Time")
  n_faculty <- 60
  faculty <- tibble(
    faculty_id = paste0("FAC", str_pad(1:n_faculty, 3, pad = "0")),
    faculty_name = paste("Faculty", 1:n_faculty),
    category = sample(categories, n_faculty, replace = TRUE, prob = c(0.15, 0.55, 0.30)),
    category_label = cat_labels[category + 1],
    academic_rank = sample(ranks, n_faculty, replace = TRUE, prob = c(0.4, 0.3, 0.2, 0.1)),
    AdminFlag = c(0L, 1L, 2L)[category + 1L],
    has_admin_function = (category == 0),
    FTE = case_when(
      category == 0 ~ sample(c(12, 15, 18), n(), replace = TRUE),
      category == 1 ~ sample(c(18, 21, 24), n(), replace = TRUE),
      category == 2 ~ 0
    ),
    max_workload = FTE,
    max_idle_hours = 0L,
    preferred_sections = lapply(1:n_faculty, function(i) sample(sections$section_id, sample(2:6, 1))),
    preferred_days = lapply(1:n_faculty, function(i) sample(days, sample(2:4, 1))),
    preferred_hours = lapply(1:n_faculty, function(i) sample(8:16, sample(3:6, 1)))
  )

  faculty <- apply_faculty_scheduling_rules(faculty)

  room_types <- c("Lecture", "PhysicsLab", "CompLab", "ChemLab", "EnggLab")
  n_rooms <- 35
  rooms <- tibble(
    room_id = paste0("RM", str_pad(1:n_rooms, 3, pad = "0")),
    room_name = paste("Room", 1:n_rooms),
    room_type = sample(room_types, n_rooms, replace = TRUE, prob = c(0.45, 0.15, 0.15, 0.125, 0.125)),
    capacity = sample(c(40, 45, 49, 50, 60), n_rooms, replace = TRUE, prob = c(0.2, 0.3, 0.3, 0.1, 0.1))
  )

  offerings <- list()
  oid <- 1L
  for (i in seq_len(nrow(sections))) {
    sec <- sections[i, ]
    n_courses_per_section <- sample(6:8, 1)
    offered_courses <- sample(courses$course_code, n_courses_per_section, replace = FALSE)
    for (cc in offered_courses) {
      course <- courses %>% filter(course_code == cc)
      possible_faculty <- faculty %>%
        filter(
          (category != 2) | (course$is_lab == FALSE)
        ) %>%
        slice_sample(n = 1)
      offerings[[oid]] <- tibble(
        offering_id = oid,
        course_code = cc,
        section_id = sec$section_id,
        faculty_id = possible_faculty$faculty_id,
        total_units = as.integer(course$total_units),
        is_lab = course$is_lab,
        is_hard = course$is_hard,
        room_type_required = course$room_type_required,
        requires_twice_weekly = course$requires_twice_weekly,
        meeting_patterns = list(generate_meeting_patterns(course$total_units, course$is_lab)[[1]])
      )
      oid <- oid + 1L
    }
  }
  offerings <- bind_rows(offerings)

  list(
    time_slots = time_slots,
    blocked_slots = blocked_slots,
    courses = courses,
    sections = sections,
    faculty = faculty,
    rooms = rooms,
    offerings = offerings
  )
}

build_real_tupc_data <- function() {
  read_csv_input <- function(file_name, required = TRUE) {
    path <- file.path(CSV_DATA_DIR, file_name)
    if (!file.exists(path)) {
      if (required) stop("Required CSV input is missing: ", path)
      return(NULL)
    }
    as_tibble(utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE))
  }

  message("Reading real CSV inputs from: ", CSV_DATA_DIR)
  section_course <- read_csv_input("Data-SectionCourse.csv")
  course_info    <- read_csv_input("Data-CourseInfo.csv")
  dept_room      <- read_csv_input("Data-DeptRoom.csv", required = FALSE)
  faculty_info   <- read_csv_input("Data-FacultyInfo.csv")
  faculty_course <- read_csv_input("Data-FacultyCourse.csv")

  if (is.null(section_course) || is.null(course_info) ||
      is.null(faculty_info) || is.null(faculty_course)) {
    stop("One or more required CSV inputs could not be loaded.")
  }

  colnames(course_info) <- c("Course", "HrsPerWeek", "LabLec", "Dept")
  colnames(faculty_info) <- c("Faculty", "FTE", "AdminFlag")
  colnames(section_course) <- c("Section", "Course")
  colnames(faculty_course) <- c("Faculty", "Course")
  if (!is.null(dept_room)) colnames(dept_room) <- c("Dept", "No_of_Rooms")

  days <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
  hour_slots <- seq(7, 20, by = 1)
  time_slots <- expand.grid(day = days, hour_start = hour_slots) %>%
    mutate(
      time_slot_id = row_number(),
      hour_end = hour_start + 1
    ) %>%
    as_tibble()

  blocked_slots <- time_slots %>%
    filter(
      (day == "Monday" & hour_start == 7) |
      (day == "Wednesday" & hour_start %in% c(11, 12))
    ) %>%
    pull(time_slot_id)

  set.seed(2025)

  courses <- course_info %>%
    mutate(
      course_code = paste0("C", str_pad(Course, 4, pad = "0")),
      total_units = HrsPerWeek,
      is_lab = (LabLec == 1),
      Dept = as.integer(Dept),
      hard_course_keywords = as.integer(HrsPerWeek) >= 4 & !is_lab,
      is_hard = hard_course_keywords | (Dept %in% c(18, 4, 13, 2) & as.integer(HrsPerWeek) >= 3),
      room_type_required = dplyr::case_when(
        is_lab & Dept == 18 ~ "PhysicsLab",
        is_lab & Dept == 4  ~ "CompLab",
        is_lab & Dept == 13 ~ "ChemLab",
        is_lab              ~ "EnggLab",
        TRUE                ~ "Lecture"
      ),
      requires_twice_weekly = (HrsPerWeek == 3 & !is_lab)
    ) %>%
    select(course_code, Course, HrsPerWeek, total_units, is_lab, is_hard,
           Dept, room_type_required, requires_twice_weekly)

  unique_sections <- unique(section_course$Section)
  n_sections <- length(unique_sections)
  dept_labels <- c("CET", "CAS", "CBA", "CCIT", "COE", "CAFA", "CON", "CIHM",
                   "CSSP", "CSM", "CEA", "CEM", "CHTM", "CED", "CAL", "CS",
                   "BA", "Sci", "Tech")
  sections <- tibble(
    Section = unique_sections,
    section_id = paste0("SEC", str_pad(unique_sections, 4, pad = "0")),
    program = sample(c("BSCE", "BSEE", "BSME", "BSCS", "BSIT", "BSECE",
                        "BSCpE", "BSBio", "BSMath", "BAComm", "BSBA", "BSA"),
                     n_sections, replace = TRUE),
    college = sample(dept_labels[1:10], n_sections, replace = TRUE),
    year_level = sample(1:4, n_sections, replace = TRUE),
    student_count = sample(c(30:45, rep(49, 5)), n_sections, replace = TRUE),
    is_irregular = sample(c(rep(FALSE, 9), TRUE), n_sections, replace = TRUE)
  )

  n_faculty <- max(faculty_info$Faculty, na.rm = TRUE)
  ranks <- c("Instructor", "Assistant Professor", "Associate Professor", "Full Professor")
  rank_probs <- c(0.4, 0.3, 0.2, 0.1)

  faculty <- faculty_info %>%
    mutate(
      faculty_id = paste0("FAC", str_pad(Faculty, 3, pad = "0")),
      category = dplyr::case_when(AdminFlag == 0L ~ 0L, AdminFlag == 1L ~ 1L,
                                   AdminFlag == 2L ~ 2L, TRUE ~ 1L),
      category_label = dplyr::case_when(
        category == 0 ~ "With Admin",
        category == 1 ~ "Full-Time",
        category == 2 ~ "Part-Time"
      ),
      academic_rank = sample(ranks, n(), replace = TRUE, prob = rank_probs),
      has_admin_function = (category == 0),
      FTE = as.integer(FTE),
      max_workload = as.integer(FTE), max_idle_hours = 0L
    )
  faculty <- apply_faculty_scheduling_rules(faculty)

  fac_prefs <- lapply(seq_len(nrow(faculty)), function(i) {
    list(
      preferred_sections = sample(sections$section_id, sample(2:min(6, nrow(sections)), 1)),
      preferred_days = sample(days, sample(2:4, 1)),
      preferred_hours = sample(8:16, sample(3:6, 1))
    )
  })
  faculty$preferred_sections <- lapply(fac_prefs, function(x) x$preferred_sections)
  faculty$preferred_days    <- lapply(fac_prefs, function(x) x$preferred_days)
  faculty$preferred_hours   <- lapply(fac_prefs, function(x) x$preferred_hours)

  room_types <- c("Lecture", "PhysicsLab", "CompLab", "ChemLab", "EnggLab")
  if (!is.null(dept_room)) {
    total_rooms <- sum(as.integer(dept_room$No_of_Rooms))
  } else {
    total_rooms <- 40
  }
  total_rooms <- max(total_rooms, 35)
  n_rooms <- total_rooms

  rooms <- tibble(
    room_id = paste0("RM", str_pad(1:n_rooms, 3, pad = "0")),
    room_name = paste("Room", 1:n_rooms),
    room_type = c(
      sample(c("Lecture"), floor(n_rooms * 0.50), replace = TRUE),
      sample(c("PhysicsLab", "CompLab", "ChemLab", "EnggLab"),
             n_rooms - floor(n_rooms * 0.50), replace = TRUE,
             prob = c(0.25, 0.30, 0.25, 0.20))
    ),
    capacity = sample(c(40, 45, 49, 50, 60), n_rooms, replace = TRUE,
                      prob = c(0.2, 0.3, 0.3, 0.1, 0.1)),
    Dept = NA_integer_
  )
  if (!is.null(dept_room)) {
    idx <- 1
    for (dr in seq_len(nrow(dept_room))) {
      n_r <- as.integer(dept_room$No_of_Rooms[dr])
      if (idx + n_r - 1 <= nrow(rooms)) {
        rooms$Dept[idx:(idx + n_r - 1)] <- as.integer(dept_room$Dept[dr])
      }
      idx <- idx + n_r
    }
  }

  course_to_faculty <- faculty_course %>%
    group_by(Course) %>%
    summarise(fac_list = list(unique(Faculty)), .groups = "drop")

  offerings <- list()
  oid <- 1
  for (sc_idx in seq_len(nrow(section_course))) {
    sec_num <- section_course$Section[sc_idx]
    course_num <- section_course$Course[sc_idx]

    course_row <- courses %>% filter(Course == course_num)
    sec_row    <- sections %>% filter(Section == sec_num)
    if (nrow(course_row) == 0 || nrow(sec_row) == 0) next

    fac_match <- course_to_faculty %>% filter(Course == course_num)
    if (nrow(fac_match) > 0 && length(fac_match$fac_list[[1]]) > 0) {
      possible_fac_ids <- fac_match$fac_list[[1]]
      fac_num <- sample(possible_fac_ids, 1)
    } else {
      elig_fac <- faculty %>% filter(
        category == 1 | (category == 0) | (category == 2 & !course_row$is_lab[1])
      )
      if (nrow(elig_fac) == 0) elig_fac <- faculty
      fac_num <- sample(elig_fac$Faculty, 1)
    }
    fac_r <- faculty %>% filter(Faculty == fac_num)
    if (nrow(fac_r) == 0) next

    mp_list <- generate_meeting_patterns(course_row$total_units[1], course_row$is_lab[1])
    chosen_pattern <- mp_list[[sample(length(mp_list), 1)]]

    offerings[[oid]] <- tibble(
      offering_id = oid,
      course_code = course_row$course_code[1],
      course_num = course_num,
      section_id = sec_row$section_id[1],
      section_num = sec_num,
      faculty_id = fac_r$faculty_id[1],
      faculty_num = fac_num,
      total_units = course_row$total_units[1],
      is_lab = course_row$is_lab[1],
      is_hard = course_row$is_hard[1],
      room_type_required = course_row$room_type_required[1],
      requires_twice_weekly = course_row$requires_twice_weekly[1],
      meeting_patterns = list(chosen_pattern)
    )
    oid <- oid + 1
  }
  offerings <- bind_rows(offerings)
  message("Built ", nrow(offerings), " offerings from real data (",
          nrow(section_course), " section-course pairs).")

  list(
    time_slots = time_slots,
    blocked_slots = blocked_slots,
    courses = courses,
    sections = sections,
    faculty = faculty,
    rooms = rooms,
    offerings = offerings,
    raw_data = list(
      section_course = section_course,
      course_info = course_info,
      dept_room = dept_room,
      faculty_info = faculty_info,
      faculty_course = faculty_course
    )
  )
}

read_tupc_data <- function(use_synthetic_if_missing = TRUE, use_real_data = TRUE) {
  # Scheduling.xlsx is the current client-maintained source of truth.  Do not
  # silently fall back to the legacy CSV extract when it is available.
  workbook <- file.path(getwd(), "files", "Scheduling.xlsx")
  omitted_workbook <- file.path(getwd(), "files", "Section Course Not Included.xlsx")
  load_comments_workbook <- file.path(getwd(), "files", "Faculty Load Comments.xlsx")
  if (use_real_data && file.exists(workbook)) {
    return(build_workbook_tupc_data(workbook, omitted_workbook, load_comments_workbook))
  }
  required_csv <- c("Data-SectionCourse.csv", "Data-CourseInfo.csv",
                    "Data-FacultyInfo.csv", "Data-FacultyCourse.csv")
  has_real_csv <- all(file.exists(file.path(CSV_DATA_DIR, required_csv)))

  if (use_real_data && has_real_csv) {
    return(build_real_tupc_data())
  }
  if (use_synthetic_if_missing) {
    message("Required CSV inputs not found. Generating synthetic data for testing.")
    return(generate_synthetic_data())
  }
  stop("Required CSV inputs not found in: ", CSV_DATA_DIR)
}

# Build operational data directly from the revised client workbooks.
build_workbook_tupc_data <- function(workbook, omitted_workbook, load_comments_workbook) {
  read_sheet <- function(sheet) as_tibble(readxl::read_excel(workbook, sheet = sheet))
  section_course <- read_sheet("SectionCourse") %>% transmute(Section = as.integer(Section), Course = as.integer(Course))
  omitted <- if (file.exists(omitted_workbook)) {
    as_tibble(readxl::read_excel(omitted_workbook)) %>% transmute(Section = as.integer(Section), Course = as.integer(Course))
  } else tibble(Section = integer(), Course = integer())
  # The omitted workbook adds offerings; duplicates are mappings to the same
  # offering and must never create a second class.
  section_course <- bind_rows(section_course, omitted) %>% distinct(Section, Course, .keep_all = TRUE)
  section_info <- read_sheet("SectionInfo") %>% transmute(Section = as.integer(Section), student_count = as.integer(NoOfStudents))
  course_info <- read_sheet("CourseInfo")
  dept_room <- read_sheet("DeptRoom") %>% transmute(Dept = as.integer(Dept), No_of_Rooms = as.integer(No_of_Rooms))
  faculty_info <- read_sheet("FacultyInfo") %>%
    transmute(Faculty = as.integer(Faculty), FTE = as.integer(FTE), AdminFlag = as.integer(`w/admin(0)_or_none(1)`), eligibility = as.character(eligibility))
  faculty_course <- read_sheet("FacultyCourse") %>%
    { .[, 1:2, drop = FALSE] } %>%
    setNames(c("Faculty", "Course")) %>%
    transmute(Faculty = as.integer(Faculty), Course = as.integer(Course)) %>%
    distinct()
  faculty_time <- read_sheet("FacultyTime") %>% transmute(Faculty = as.integer(Faculty), Day = as.integer(Day), Time_from = as.integer(Time_from), Time_to = as.integer(Time_to))
  faculty_section <- read_sheet("FacultySection") %>% transmute(Faculty = as.integer(Faculty), Section = as.integer(Section)) %>% distinct()
  load_comments <- if (file.exists(load_comments_workbook)) as_tibble(readxl::read_excel(load_comments_workbook)) else tibble()

  days <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
  # 19:00 is the last possible one-hour start; every selected meeting ends no
  # later than 20:00.  This is intentionally not a preference.
  time_slots <- expand.grid(day = days, hour_start = 7:19, stringsAsFactors = FALSE) %>%
    as_tibble() %>% mutate(time_slot_id = row_number(), hour_end = hour_start + 1L)
  blocked_slots <- time_slots %>%
    filter(
      (day == "Monday" & hour_start == 7L) |
        (day == "Wednesday" & hour_start %in% c(11L, 12L))
    ) %>%
    pull(time_slot_id)
  if (length(blocked_slots)) {
    message(sprintf("Blocked %d reserved time slot(s): Mon 07-08 (Flag ceremony) + Wed 11-13 (Campus break).",
                    length(blocked_slots)))
  }
  courses <- course_info %>% transmute(
    Course = as.integer(Course), course_code = paste0("C", str_pad(Course, 4, pad = "0")),
    HrsPerWeek = as.integer(HrsPerWeek), total_units = as.integer(HrsPerWeek),
    is_lab = as.integer(`Lab.1_Lec.2`) == 1L, is_hard = as.integer(Difficulty) >= 2L,
    Dept = as.integer(Dept), room_type_required = "DepartmentRoom",
    requires_twice_weekly = as.integer(HrsPerWeek) == 3L & as.integer(`Lab.1_Lec.2`) != 1L
  )
  sections <- section_info %>% mutate(
    section_id = paste0("SEC", str_pad(Section, 4, pad = "0")), program = "Unspecified",
    college = "Unspecified", year_level = NA_integer_, is_irregular = FALSE
  )
  # Rooms are departmental inventory, not interchangeable campus rooms.  The
  # source provides counts but no capacities, so 60 is recorded as the known
  # planning capacity and every assignment is still capacity-validated.
  rooms <- bind_rows(lapply(seq_len(nrow(dept_room)), function(i) tibble(
    room_id = paste0("D", str_pad(dept_room$Dept[i], 2, pad = "0"), "-R", str_pad(seq_len(dept_room$No_of_Rooms[i]), 2, pad = "0")),
    room_name = paste0("Department ", dept_room$Dept[i], " Room ", seq_len(dept_room$No_of_Rooms[i])),
    Dept = dept_room$Dept[i], room_type = "DepartmentRoom", capacity = 60L
  )))
  faculty <- faculty_info %>% mutate(
    faculty_id = paste0("FAC", str_pad(Faculty, 3, pad = "0")),
    # Scheduling.xlsx does not provide academic ranks.  Keep the preference
    # scoring neutral instead of requiring a synthetic rank field downstream.
    academic_rank = "Instructor",
    category = case_when(AdminFlag == 0L ~ 0L, AdminFlag == 1L ~ 1L, AdminFlag == 2L ~ 2L, TRUE ~ 1L),
    category_label = c("With Admin", "Full-Time", "Part-Time")[category + 1L],
    has_admin_function = AdminFlag == 0L, max_workload = as.integer(FTE),
    max_idle_hours = 0L
  )
  faculty <- apply_faculty_scheduling_rules(faculty)
  faculty$preferred_sections <- lapply(faculty$Faculty, function(f) faculty_section$Section[faculty_section$Faculty == f])
  faculty$preferred_days <- replicate(nrow(faculty), days, simplify = FALSE)
  faculty$preferred_hours <- replicate(nrow(faculty), 7:19, simplify = FALSE)

  pairs <- section_course %>% inner_join(courses, by = "Course") %>% inner_join(sections %>% select(Section, section_id, student_count), by = "Section")
  # Assign qualified instructors while balancing weekly hours.  FacultyCourse
  # is authoritative eligibility; FacultySection is used as a tie-breaker,
  # not an exclusion, because the revised omissions may extend a load.
  running_load <- setNames(rep(0L, nrow(faculty)), faculty$Faculty)
  pick_faculty <- function(course, section, hours) {
    eligible <- faculty_course$Faculty[faculty_course$Course == course]
    eligible <- intersect(eligible, faculty$Faculty)
    eligible <- eligible[!is.na(eligible)]
    if (!length(eligible)) eligible <- faculty$Faculty
    # FacultySection is historical context, not a hard qualification list.
    # Restricting to it concentrated the revised workload on a few faculty.
    pool <- eligible
    caps <- faculty$max_workload[match(pool, faculty$Faculty)]
    under_cap <- pool[running_load[as.character(pool)] + hours <= caps]
    if (length(under_cap)) pool <- under_cap
    # Guard: if pool is still empty (all faculty over max_workload), fall back
    # to the least-loaded faculty from the full eligible set so that assigned[i]
    # is never NA (which would produce a "FACNA" faculty_id).
    if (!length(pool)) pool <- eligible
    pool[which.min(running_load[as.character(pool)] / pmax(1, caps[match(pool, eligible)]))]
  }
  pairs <- pairs %>% arrange(desc(HrsPerWeek), Course, Section)
  assigned <- integer(nrow(pairs))
  for (i in seq_len(nrow(pairs))) { assigned[i] <- pick_faculty(pairs$Course[i], pairs$Section[i], pairs$HrsPerWeek[i]); running_load[as.character(assigned[i])] <- running_load[as.character(assigned[i])] + pairs$HrsPerWeek[i] }
  offerings <- pairs %>% mutate(
    offering_id = row_number(), course_num = Course, section_num = Section, faculty_num = assigned,
    faculty_id = paste0("FAC", str_pad(assigned, 3, pad = "0")),
    meeting_patterns = lapply(seq_len(n()), function(i) generate_meeting_patterns(total_units[i], is_lab[i])[[1]])
  ) %>% select(offering_id, course_code, course_num, section_id, section_num, faculty_id, faculty_num,
               total_units, is_lab, is_hard, room_type_required, requires_twice_weekly, Dept, meeting_patterns,
               student_count)

  ############################################################
  # Merge Groups: Offerings with same (course_num, faculty_num, Dept,
  # total_units, is_lab) and combined student_count <= 49 can be taught
  # as a single merged class (same time, room, faculty).  Assign
  # merge_group_id greedily so all offerings in the same group must share
  # one schedule row.
  ############################################################
  MERGE_CAP_STUDENTS <- 56L
  offerings$merge_group_id <- NA_integer_
  next_mgid <- 1L
  mg_keys <- paste(offerings$course_num, offerings$faculty_num, offerings$Dept,
                   offerings$total_units, offerings$is_lab, sep = "|")
  for (k in unique(mg_keys)) {
    idx <- which(mg_keys == k)
    if (length(idx) <= 1L) next
    # Pack greedily by largest-section-first to fill caps effectively.
    sub <- offerings[idx, c("offering_id", "student_count")] %>% arrange(desc(student_count))
    bins <- integer(nrow(sub))
    bin_sizes <- integer(0)
    for (si in seq_len(nrow(sub))) {
      placed <- FALSE
      for (bi in seq_along(bin_sizes)) {
        if (bin_sizes[bi] + sub$student_count[si] <= MERGE_CAP_STUDENTS) {
          bin_sizes[bi] <- bin_sizes[bi] + sub$student_count[si]
          bins[si] <- bi
          placed <- TRUE
          break
        }
      }
      if (!placed) {
        bin_sizes <- c(bin_sizes, sub$student_count[si])
        bins[si] <- length(bin_sizes)
      }
    }
    for (bi in unique(bins)) {
      mems <- sub$offering_id[bins == bi]
      if (length(mems) <= 1L) next
      offerings$merge_group_id[offerings$offering_id %in% mems] <- next_mgid
      next_mgid <- next_mgid + 1L
    }
  }
  n_merged <- sum(!is.na(offerings$merge_group_id))
  n_groups <- length(unique(na.omit(offerings$merge_group_id)))
  message(sprintf("Merge groups created: %d (covers %d offerings, max merged capacity = %d students)",
                  n_groups, n_merged, MERGE_CAP_STUDENTS))
  list(time_slots = time_slots, blocked_slots = blocked_slots, courses = courses, sections = sections,
       faculty = faculty, rooms = rooms, offerings = offerings,
       raw_data = list(section_course = section_course, omitted_section_course = omitted, section_info = section_info,
                       dept_room = dept_room, faculty_course = faculty_course, faculty_time = faculty_time,
                       faculty_load_comments = load_comments, section_mapping = sections %>% select(Section, section_id)))
}

message("01_data_loader.R loaded. Call read_tupc_data() to load data.")
