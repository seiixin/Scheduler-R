## ----setup, include = FALSE---------------------------------------------------
knitr::opts_chunk$set(collapse = TRUE, comment = "#>")
library(writexl)

## -----------------------------------------------------------------------------
xl_font(bold = TRUE, color = "navy", size = 12)
xl_fill(background = "#FFF2CC")
xl_border(all = "thin", color = "gray")
xl_align(horizontal = "center", vertical = "top", wrap = TRUE)
xl_num_format("#,##0.00")
xl_protection(locked = FALSE)

## -----------------------------------------------------------------------------
money <- xl_num_format("$#,##0.00") + xl_font(color = "darkgreen")
money + xl_font(bold = TRUE)     # still green, now bold

## -----------------------------------------------------------------------------
df <- data.frame(item = c("Widget", "Gadget", "Gizmo"))
df$price <- xl_cell_general(value = c(1234.5, 67.25, 890), format = money)
df$flag  <- xl_cell_general(
  value  = c(10, -5, 3),
  format = list(xl_fill(background = "lightgreen"),
                xl_fill(background = "salmon"),
                xl_fill(background = "lightgreen")))
path <- write_xlsx(df, tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
xl_cell_general(value = NA, format = xl_fill(background = "#EEEEEE"))

## -----------------------------------------------------------------------------
sheet <- xl_sheet(
  data.frame(date = as.Date("2024-01-01") + 0:2,
             revenue = c(1000.5, 2000.25, 1500.75)),
  cols = list(xl_col_spec("date", width = 12),
              xl_col_spec("revenue", width = 14, format = money)),
  rows = xl_row_spec(1, height = 20))
path <- write_xlsx(list(Sales = sheet), tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
scores <- data.frame(name = c("a", "b", "c", "d"), score = c(35, 78, 55, 92))
sheet <- xl_sheet(scores, conditional = list(
  xl_cond_cell(list(cols = "score"), "cell", ">=", 80,
               format = xl_fill(background = "lightgreen")),
  xl_cond_cell(list(cols = "score"), "cell", "<", 50,
               format = xl_fill(background = "salmon"))))
path <- write_xlsx(list(Scores = sheet), tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
xl_cond_scale(list(cols = "score"), colors = c("salmon", "lightgreen"))
xl_cond_bar(list(cols = "score"), color = "steelblue")
xl_cond_icons(list(cols = "score"), style = "3_traffic_lights")

