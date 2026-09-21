## ----setup, include = FALSE---------------------------------------------------
knitr::opts_chunk$set(collapse = TRUE, comment = "#>")
library(writexl)

## -----------------------------------------------------------------------------
path <- write_xlsx(iris, tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
path <- write_xlsx(list(Flowers = iris, Cars = mtcars[1:5, 1:4]),
                   tempfile(fileext = ".xlsx"))

## -----------------------------------------------------------------------------
tmp <- write_xlsx(data.frame(x = c(1.5, NA)), na = "not measured")

## -----------------------------------------------------------------------------
money <- xl_num_format("$#,##0.00") + xl_font(bold = TRUE)

## -----------------------------------------------------------------------------
xl_sheet(iris, autofilter = "A1:E151")                   # A1 text
xl_sheet(iris, filter = xl_filter("Species", "==", "setosa"))  # by column

## ----eval = requireNamespace("readxl", quietly = TRUE)------------------------
readxl::read_xlsx(write_xlsx(head(iris, 3), tempfile(fileext = ".xlsx")))

