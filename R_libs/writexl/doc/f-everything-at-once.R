## ----setup, include = FALSE---------------------------------------------------
knitr::opts_chunk$set(collapse = TRUE, comment = "#>")
library(writexl)

## -----------------------------------------------------------------------------
sales <- data.frame(
  quarter = c("Q1", "Q2", "Q3", "Q4"),
  revenue = c(120000, 145000, 133000, 180000),
  cost    = c(90000, 110000, 105000, 130000),
  region  = c("North", "South", "North", "South"),
  stringsAsFactors = FALSE)

## -----------------------------------------------------------------------------
money <- xl_num_format("$#,##0") + xl_font(color = "darkgreen")

styled <- xl_sheet(
  sales,
  cols = list(xl_col_spec("quarter", width = 10),
              xl_col_spec(c("revenue", "cost"), width = 14, format = money)),
  rows = xl_row_spec(1, height = 18),
  conditional = list(
    xl_cond_cell(list(cols = "revenue"), "cell", ">=", 1.4e5,
                 format = xl_fill(background = "lightgreen")),
    xl_cond_bar(list(cols = "cost"), color = "steelblue")),
  freeze = "A2", tab_color = "steelblue")

## -----------------------------------------------------------------------------
cells <- data.frame(item = c("Widget", "Gadget", "Gizmo"),
                    stringsAsFactors = FALSE)
cells$price   <- xl_cell_general(value = c(1234.5, 67.25, 890), format = money)
cells$margin  <- xl_formula(sprintf("=B%d*0.3", 2:4))
cells$link    <- xl_hyperlink(rep("https://ropensci.org", 3), "rOpenSci")
cells$note    <- xl_cell_general(
  value   = c("ok", NA, "check"),
  comment = list(xl_comment("Reviewed", author = "QA"), NULL, NULL),
  format  = list(NULL, xl_fill(background = "#EEEEEE"), NULL))
# a rich string is one cell's worth of text, so it goes in a list alongside
# the other rows' values
cells$rich    <- xl_cell_general(value = list(
  xl_rich_string("Plain ", xl_rich_run("bold", xl_font(bold = TRUE)),
                 " and ", xl_rich_run("red", xl_font(color = "red"))),
  "plain text", NA))

content <- xl_sheet(
  cells,
  merge = xl_merge("A5:C5", "A merged heading",
                   format = xl_align(horizontal = "center") +
                            xl_font(bold = TRUE)),
  validation = xl_validation(list(cols = "item"), type = "list",
                             list = c("Widget", "Gadget", "Gizmo"),
                             input_title = "Pick one"),
  ignore_errors = list(number_stored_as_text = "A2:A4"))

## -----------------------------------------------------------------------------
filtered <- xl_sheet(sales, filter = xl_filter("region", "==", "North"))

tabled <- xl_sheet(sales[, c("quarter", "revenue")],
                   table = xl_table(name = "Revenue", style = "medium 9",
                                    total_row = TRUE,
                                    columns = xl_table_column("revenue",
                                                              total = "sum")))

## -----------------------------------------------------------------------------
printed <- xl_sheet(
  sales,
  page = xl_page_setup(orientation = "landscape", paper = "A4",
                       fit_to = c(1, 0), center_horizontally = TRUE,
                       header = "&LwritexlShowcase&RPage &P of &N",
                       repeat_rows = 1),
  view = xl_sheet_view(hide_zero = TRUE),
  outline = xl_outline(symbols_below = FALSE),
  protect = list(password = "secret", sort = TRUE))

## -----------------------------------------------------------------------------
charted <- xl_sheet(
  sales,
  chart = list(
    xl_chart("column",
             list(xl_chart_series(values = list(cols = "revenue"),
                                  categories = list(cols = "quarter"),
                                  labels = xl_chart_labels(num_format = "$#,##0",
                                                           position = "outside_end")),
                  xl_chart_series(values = list(cols = "cost"),
                                  categories = list(cols = "quarter"))),
             title = "Revenue and cost",
             title_format = xl_font(size = 13, bold = TRUE),
             x_axis = xl_chart_axis(title = "Quarter"),
             y_axis = xl_chart_axis(title = "Dollars", min = 0,
                                    num_format = "$#,##0"),
             legend = xl_chart_legend(position = "bottom"),
             series_gap = 60, at = "G2"),
    xl_chart("pie",
             xl_chart_series(values = list(cols = "revenue"),
                             categories = list(cols = "quarter"),
                             labels = xl_chart_labels(show_percentage = TRUE),
                             points = list(xl_fill(background = "#C00000"),
                                           NULL, NULL, NULL)),
             title = "Share of revenue", at = "G20"),
    xl_chart("scatter_straight_markers",
             xl_chart_series(values = list(cols = "revenue"),
                             categories = list(cols = "cost"),
                             marker = xl_chart_marker("circle", size = 7),
                             trendline = xl_chart_trendline("linear",
                                                            equation = TRUE),
                             y_error_bars = xl_chart_error_bars("percentage", 5)),
             title = "Revenue against cost", at = "P2")))

overview <- xl_chartsheet(
  xl_chart("line",
           xl_chart_series(values = list(sheet = "Charts", cols = "revenue"),
                           categories = list(sheet = "Charts",
                                             cols = "quarter")),
           title = "Revenue, full page",
           y_axis = xl_chart_axis(title = "Revenue", min = 0)),
  tab_color = "red")

## -----------------------------------------------------------------------------
have_png <- isTRUE(capabilities("png")) &&
  requireNamespace("grDevices", quietly = TRUE)

## ----eval = have_png----------------------------------------------------------
card <- as.raster(matrix(c("#4472C4", "#ED7D31", "#A5A5A5", "#FFC000"),
                         nrow = 2))
pictured <- xl_sheet(sales[, 1:2], image = xl_image(card, at = "D2",
                                                    scale = 30,
                                                    description = "A test card"))

## ----eval = !have_png, echo = FALSE-------------------------------------------
# pictured <- xl_sheet(sales[, 1:2])

## -----------------------------------------------------------------------------
wb <- xl_workbook(
  list(Formatted = styled,
       Content   = content,
       Filtered  = filtered,
       Table     = tabled,
       Printed   = printed,
       Charts    = charted,
       Picture   = pictured,
       Overview  = overview),
  properties = xl_properties(
    title    = "writexl showcase",
    author   = "writexl",
    subject  = "Every feature in one workbook",
    custom   = list(Generated = Sys.Date(), Reviewed = FALSE),
    header_format = xl_font(bold = TRUE, color = "white") +
                    xl_fill(background = "#1F3864")))

showcase <- write_xlsx(wb, tempfile(fileext = ".xlsx"))

## ----eval = have_png----------------------------------------------------------
embedded <- write_xlsx(
  list(Embedded = xl_sheet(sales[, 1:2],
                           image = xl_image(card, at = "D2", embed = TRUE))),
  tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
sheets <- c("Formatted", "Content", "Filtered", "Table", "Printed",
            "Charts", "Picture", "Overview")
data.frame(sheet = sheets,
           shows = c("formats, conditional rules, frozen pane",
                     "formulas, links, comments, rich text, merge, validation",
                     "an autofilter with its rows hidden",
                     "a worksheet table with a total row",
                     "page setup, outline symbols, protection",
                     "a column, a pie and a scatter chart",
                     "a picture anchored to a cell",
                     "a chartsheet: one chart, no cells"))

## -----------------------------------------------------------------------------
file.size(showcase)

