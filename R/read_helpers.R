# read_helpers.R - Reading the outputs
# ---------------------------------------------------------------------------
# source(here::here("R", "read_helpers.R"))
#   od <- od_open()                                             # all England, lazy
#   bh <- od_open() |> dplyr::filter(la == "E06000043_brighton_and_hove") |> dplyr::collect()
#   pr <- route_profile("E00085094", 136843)                    # one route's height profile
#   plot(pr$distance_m, pr$height_m, type = "l")
#   rt <- route_line("E00085094", 136843)                       # the route as an sf line
# Outputs are filed by the local authority of the home Output Area (column la in
# origins.parquet); filtering on la first opens only that authority's files.
# ---------------------------------------------------------------------------

out_dir <- function(...) here::here("data", "out", ...)
od_open <- function() arrow::open_dataset(out_dir("od"))
la_of <- function(oa) { o <- arrow::read_parquet(out_dir("origins.parquet"), col_select = c("oa21cd", "la")); o$la[match(oa, o$oa21cd)] }

route_profile <- function(oa, urn, step = 50) {
  a <- la_of(oa)
  x <- arrow::open_dataset(out_dir("profiles")) |> dplyr::filter(la == a, oa21cd == oa, urn == !!urn) |> dplyr::collect()
  if (!nrow(x)) return(NULL)
  len <- od_open() |> dplyr::filter(la == a, oa21cd == oa, urn == !!urn) |> dplyr::pull(route_m)
  z <- x$elev_dm[[1]] / 10; d <- pmin(seq(0, by = step, length.out = length(z)), len); d[length(d)] <- len
  data.frame(distance_m = d, height_m = z)
}

route_line <- function(oa, urn) {
  a <- la_of(oa)
  x <- arrow::open_dataset(out_dir("routes")) |> dplyr::filter(la == a, oa21cd == oa, urn == !!urn) |> dplyr::collect()
  if (!nrow(x)) return(NULL)
  sf::st_sf(oa21cd = oa, urn = urn, geometry = sf::st_as_sfc(structure(lapply(x$geom_wkb, as.raw), class = "WKB"), crs = 27700))
}
