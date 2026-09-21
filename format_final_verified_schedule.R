# Accepts an optional command-line argument: Rscript format_final_verified_schedule.R <input.xlsx>
# Falls back to the most recently modified schedule xlsx in outputs/.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1L && file.exists(args[1L])) {
  input_file <- args[1L]
} else {
  candidates <- list.files("outputs", pattern = "_schedule.*\\.xlsx$", full.names = TRUE)
  if (!length(candidates)) stop("No schedule xlsx found in outputs/. Run aco_scheduler.R or sa_scheduler.R first.")
  input_file <- candidates[which.max(file.mtime(candidates))]
}
base_name  <- sub("\\.xlsx$", "", basename(input_file))
output_file <- file.path("outputs", paste0(base_name, "_formatted.xlsx"))

.libPaths(c(normalizePath("R_libs"), .libPaths()))
if (!requireNamespace("readxl", quietly = TRUE) || !requireNamespace("writexl", quietly = TRUE)) {
  stop("readxl and writexl are required.")
}

# Preserve every audit sheet while replacing only the client-facing Schedule.
sheets <- readxl::excel_sheets(input_file)
workbook <- stats::setNames(lapply(sheets, function(x) as.data.frame(readxl::read_excel(input_file, sheet = x))), sheets)
schedule <- workbook[["Schedule"]]
day_order <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")

format_hour <- function(hour) {
  suffix <- ifelse(hour < 12, "AM", "PM")
  display_hour <- hour %% 12
  display_hour[display_hour == 0] <- 12
  sprintf("%02d:00 %s", display_hour, suffix)
}

schedule$day <- factor(schedule$day, levels = day_order, ordered = TRUE)
schedule$time_formatted <- paste(format_hour(schedule$hour_start),
                                 format_hour(schedule$hour_end), sep = " - ")
schedule <- schedule[order(schedule$day, schedule$hour_start, schedule$hour_end,
                           schedule$course_code, schedule$section_id), , drop = FALSE]
schedule$day <- as.character(schedule$day)

# Place the new review column directly after hour_end.
names_before <- names(schedule)
column_order <- append(setdiff(names_before, "time_formatted"), "time_formatted",
                       after = match("hour_end", setdiff(names_before, "time_formatted")))
workbook[["Schedule"]] <- schedule[, column_order, drop = FALSE]
writexl::write_xlsx(workbook, output_file)
message("Formatted ", output_file, " (", nrow(schedule), " Schedule rows).")
