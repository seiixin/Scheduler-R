## ----setup, include = FALSE---------------------------------------------------
knitr::opts_chunk$set(collapse = TRUE, comment = "#>")
library(writexl)

## -----------------------------------------------------------------------------
sheet <- xl_sheet(
  data.frame(id = 1:3, note = c("a", "b", "c")),
  cols      = xl_col_spec("note", width = 30),
  freeze    = "A2",          # keep the header row visible
  tab_color = "steelblue",
  zoom      = 120,
  gridlines = FALSE)
path <- write_xlsx(list(Notes = sheet), tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
xl_col_spec("thumbnail", width_pixels = 100)
xl_row_spec(1, height_pixels = 40)

## -----------------------------------------------------------------------------
xl_sheet(data.frame(q1 = 1:2, q2 = 3:4, total = 4:5),
         cols    = xl_col_spec(c("q1", "q2"), level = 1),
         outline = xl_outline(symbols_right = FALSE))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(id = 1:3),
         protect = list(password = "secret", sort = TRUE))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(zip = c("01234", "02138")),
         ignore_errors = list(number_stored_as_text = "A2:A3"))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(x = 1),
         view = xl_sheet_view(active = TRUE, selection = "B2",
                              hide_zero = TRUE))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(x = 1:3),
         page = xl_page_setup(
           orientation = "landscape", paper = "A4",
           fit_to = c(1, 0),                 # one page wide, any number tall
           center_horizontally = TRUE,
           header = "&LQuarterly report&RPage &P of &N",
           repeat_rows = 1,                  # the header row, on every page
           print_area = "A1:C4"))

## -----------------------------------------------------------------------------
wb <- xl_workbook(
  list(Report = data.frame(quarter = c("Q1", "Q2"), sales = c(12000, 15000))),
  properties = xl_properties(
    title   = "Quarterly Report",
    author  = "Finance Team",
    custom  = list(Project = "Alpha", Reviewed = TRUE),
    header_format = xl_font(bold = TRUE, color = "white") +
                    xl_fill(background = "navy")))
path <- write_xlsx(wb, tempfile(fileext = ".xlsx"))

## ----eval = FALSE-------------------------------------------------------------
# write_xlsx(big, path, constant_memory = TRUE)

