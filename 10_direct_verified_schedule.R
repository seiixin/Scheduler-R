###############################################################################
# Constraint-first production scheduler and independent validation/export.
###############################################################################
source("01_data_loader.R")
source("r_scheduler_export_helpers.R")
OUTPUT_DIR <- file.path(getwd(), "outputs"); dir.create(OUTPUT_DIR, showWarnings=FALSE, recursive=TRUE)
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
data <- read_tupc_data(use_real_data=TRUE, use_synthetic_if_missing=FALSE)

validate_schedule <- function(s, data) {
  expected <- make_r_schedule_tasks(data) %>% dplyr::count(offering_id, name = "required_meetings")
  actual <- s %>% dplyr::count(offering_id, name = "scheduled_meetings")
  coverage <- dplyr::left_join(expected, actual, by = "offering_id") %>%
    dplyr::mutate(scheduled_meetings = dplyr::coalesce(scheduled_meetings, 0L),
                  missing_meetings = required_meetings - scheduled_meetings)
  list(coverage = coverage, violations = validate_r_schedule(s, data),
       faculty_load = faculty_schedule_rule_summary(s, data))
}
schedule <- build_verified_r_schedule(data, seed = 20260915L, max_attempts = 200L, max_choices = 100L)
check<-validate_schedule(schedule,data);if(any(check$violations$violations!=0L)){print(check$violations);stop("Constraint validation failed; schedule was not exported.")}
verification<-data.frame(generated_at=as.character(Sys.time()),offerings=nrow(data$offerings),required_meetings=sum(check$coverage$required_meetings),scheduled_meetings=nrow(schedule),missing_meetings=sum(check$coverage$missing_meetings),fully_covered_offerings=sum(check$coverage$missing_meetings==0L),hard_constraint_violations=0L)
base<-file.path(OUTPUT_DIR,paste0("updated_verified_schedule_",stamp));write.csv(schedule,paste0(base,".csv"),row.names=FALSE);write.csv(check$coverage,file.path(OUTPUT_DIR,paste0("updated_coverage_",stamp,".csv")),row.names=FALSE);write.csv(check$violations,file.path(OUTPUT_DIR,paste0("updated_constraint_verification_",stamp,".csv")),row.names=FALSE);write.csv(check$faculty_load,file.path(OUTPUT_DIR,paste0("updated_faculty_load_",stamp,".csv")),row.names=FALSE);writexl::write_xlsx(list(Schedule=schedule,Coverage=check$coverage,Constraint_Verification=check$violations,Faculty_Load=check$faculty_load),paste0(base,".xlsx"));write.csv(verification,file.path(OUTPUT_DIR,paste0("updated_verification_",stamp,".csv")),row.names=FALSE);print(verification)
