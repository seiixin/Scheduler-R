## ----setup, include = FALSE---------------------------------------------------
knitr::opts_chunk$set(collapse = TRUE, comment = "#>")
library(writexl)

## -----------------------------------------------------------------------------
df <- data.frame(x = 1:3, y = c(10, 20, 30))
df$total <- xl_formula(sprintf("=A%d*B%d", 2:4, 2:4))
path <- write_xlsx(df, tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
xl_cell_general(formula = "=SUM(A2:A4*B2:B4)", array = TRUE)
xl_cell_general(formula = "=UNIQUE(A2:A10)", dynamic = TRUE)

## -----------------------------------------------------------------------------
xl_hyperlink("https://example.com", "Example")

## -----------------------------------------------------------------------------
xl_cell_general(value = 42, comment = xl_comment("Checked", author = "QA"))

## -----------------------------------------------------------------------------
xl_rich_string("Plain ", xl_rich_run("bold", xl_font(bold = TRUE)),
               " and ", xl_rich_run("red", xl_font(color = "red")))

## -----------------------------------------------------------------------------
xl_cell_general(value = list(1, NA, "text"),
                format = list(NULL, xl_fill(background = "yellow"), NULL))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(size = c("S", "M", "L")),
         validation = xl_validation(list(cols = "size"), type = "list",
                                    list = c("S", "M", "L"),
                                    input_title = "Pick a size"))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(fruit = c("apple", "pear"), qty = c(5, 12)),
         filter = xl_filter("fruit", "==", "apple"))

## -----------------------------------------------------------------------------
df <- data.frame(fruit = c("apple", "pear", "plum"), qty = c(5, 12, 7))
xl_filter_keep(df, xl_filter("qty", ">", 6))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(item = c("a", "b"), qty = c(3, 4)),
         table = xl_table(name = "Stock", total_row = TRUE,
                          columns = xl_table_column("qty", total = "sum")))

## -----------------------------------------------------------------------------
xl_sheet(data.frame(a = 1:2, b = 3:4),
         merge = xl_merge("A1:B1", "Heading",
                          format = xl_align(horizontal = "center")))

