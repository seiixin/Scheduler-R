## ----setup, include = FALSE---------------------------------------------------
knitr::opts_chunk$set(collapse = TRUE, comment = "#>")
library(writexl)
sales <- data.frame(quarter = c("Q1", "Q2", "Q3", "Q4"),
                    revenue = c(120, 145, 133, 180),
                    cost    = c(90, 110, 105, 130))

## -----------------------------------------------------------------------------
sheet <- xl_sheet(sales,
                  chart = xl_chart("column",
                                   xl_chart_series(values = list(cols = "revenue")),
                                   title = "Revenue by quarter", at = "E2"))
path <- write_xlsx(list(Sales = sheet), tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
xl_chart_series(values = list(sheet = "Sales", cols = "revenue", rows = 1:2))

## -----------------------------------------------------------------------------
xl_chart("line",
         xl_chart_series(values = list(cols = "revenue"),
                         format = xl_border(all = "dashed", color = "#4472C4")),
         title = "Revenue", title_format = xl_font(size = 14, bold = TRUE))

## -----------------------------------------------------------------------------
xl_chart("column", xl_chart_series(values = list(cols = "revenue")),
         x_axis = xl_chart_axis(title = "Quarter", major_tick = "none"),
         y_axis = xl_chart_axis(title = "Revenue", min = 0,
                                num_format = "$#,##0",
                                major_gridlines_format =
                                  xl_border(all = "dotted", color = "gray")))

## -----------------------------------------------------------------------------
xl_chart_series(
  values       = list(cols = "revenue"),
  marker       = xl_chart_marker(type = "circle", size = 7),
  labels       = xl_chart_labels(num_format = "$#,##0", position = "above"),
  trendline    = xl_chart_trendline("linear", equation = TRUE),
  y_error_bars = xl_chart_error_bars("percentage", 5))

## -----------------------------------------------------------------------------
xl_chart("pie", xl_chart_series(values = list(cols = "revenue"),
                                points = list(xl_fill(background = "red"),
                                              NULL, NULL, NULL)))

## -----------------------------------------------------------------------------
xl_chart("column", xl_chart_series(values = list(cols = "revenue")),
         legend     = xl_chart_legend(position = "bottom"),
         data_table = xl_chart_table(show_keys = TRUE),
         plot_area_format  = xl_fill(background = "#F8F8F8"),
         chart_area_format = xl_border(all = "thin", color = "gray"))

## -----------------------------------------------------------------------------
chart <- xl_chart("column",
                  xl_chart_series(values = list(sheet = "Data",
                                                cols = "revenue"),
                                  categories = list(sheet = "Data",
                                                    cols = "quarter")),
                  title = "Revenue")
path <- write_xlsx(list(Data = sales, Overview = xl_chartsheet(chart)),
                   tempfile(fileext = ".xlsx"))

## ----eval = isTRUE(capabilities("png"))---------------------------------------
card <- as.raster(matrix(c("red", "blue", "green", "gold"), nrow = 2))
xl_sheet(sales, image = xl_image(card, at = "G2", scale = 20))

## ----eval = FALSE-------------------------------------------------------------
# xl_page_setup(header = "&L&G", header_image = list(left = logo))
# xl_sheet(sales, background_image = logo)

