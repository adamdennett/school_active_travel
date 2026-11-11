# 04_assemble.R - Gather finished tiles into the national outputs, filed by local authority
# ---------------------------------------------------------------------------
# Rscript R/04_assemble.R [tile]   (no tile: every finished tile not yet gathered, then the summary)
#
# Routing works in 60 km tiles; the outputs are filed by the local authority (district or
# unitary, 2025) of the home Output Area, one folder each, e.g. la=E06000043_brighton_and_hove.
# An authority that spans two tiles has one file from each (part-<tile>-0.parquet).
# arrow::open_dataset() on any of the three folders reads all England as one table.
#
# data/out/od/la=<la>/        one row per Output Area and school within 120 minutes' walk:
#                             distances, walking and cycling times, climb and steepness each way
# data/out/profiles/la=<la>/  elev_dm: ground height in decimetres every 50 m along the walking
#                             route from home to school (the last step is shorter, to the school)
# data/out/routes/la=<la>/    the walking route as WKB, British National Grid (EPSG:27700)
# data/out/tile_summary.csv   pairs, routes and gaps by tile
# R/read_helpers.R has examples.
# ---------------------------------------------------------------------------

source(here::here("R", "00_config.R"))
suppressPackageStartupMessages({ library(arrow); library(dplyr) })
FR <- readRDS(FRAME_F)
put <- function(x, d, id) write_dataset(x, file.path(OUT, d), format = "parquet", partitioning = "la", basename_template = paste0("part-", id, "-{i}.parquet"),
                                        existing_data_behavior = "overwrite", compression = "zstd")
one <- function(id) {
  TD <- file.path(CACHE, "tiles", id); stopifnot(file.exists(file.path(TD, "DONE")))
  P <- as.data.table(read_parquet(file.path(TD, "pairs.parquet"))); B <- as.data.table(read_parquet(file.path(TD, "bike.parquet")))
  R <- open_dataset(list.files(TD, "^routes_\\d+\\.parquet$", full.names = TRUE))
  st <- as.data.table(R |> select(-elev_dm, -geom_wkb) |> collect())
  od <- merge(merge(P, B, by = c("oa21cd", "urn"), all.x = TRUE), st, by = c("oa21cd", "urn"), all.x = TRUE)
  od <- merge(merge(od, FR$oa[, .(oa21cd, la, oe = e, on = n)], by = "oa21cd"), FR$sch[, .(urn, se = e, sn = n)], by = "urn")
  od[, `:=`(straight_m = round(sqrt((oe - se)^2 + (on - sn)^2)), oe = NULL, on = NULL, se = NULL, sn = NULL)]
  od[, circuity := round(route_m / pmax(straight_m, 1), 3)]
  setcolorder(od, c("oa21cd", "urn", "straight_m", "route_m", "circuity", "walk_min_r5", "walk_min_route", "tobler_min_to_school", "tobler_min_to_home"))
  setorder(od, oa21cd, walk_min_r5)
  # A rerun replaces this tile's files and leaves other tiles' alone
  for (d in c("od", "profiles", "routes")) unlink(Sys.glob(file.path(OUT, d, "la=*", paste0("part-", id, "-*.parquet"))))
  put(od, "od", id)
  # Arrow cannot join a list column, so the authority is added to the route chunks in R,
  # 50 chunks (a million routes) at a time: a big tile leaves a handful of files per authority
  rf <- list.files(TD, "^routes_\\d+\\.parquet$", full.names = TRUE)
  for (g in split(seq_along(rf), ceiling(seq_along(rf) / 50))) {
    tb <- do.call(concat_tables, lapply(rf[g], function(x) read_parquet(x, col_select = c("oa21cd", "urn", "elev_dm", "geom_wkb"), as_data_frame = FALSE)))
    tb$la <- Array$create(FR$oa$la[match(as.vector(tb$oa21cd), FR$oa$oa21cd)])
    b <- paste0("part-", id, "-", g[1], "-{i}.parquet")
    write_dataset(tb[, c("oa21cd", "urn", "elev_dm", "la")], file.path(OUT, "profiles"), format = "parquet", partitioning = "la", basename_template = b, compression = "zstd")
    write_dataset(tb[, c("oa21cd", "urn", "geom_wkb", "la")], file.path(OUT, "routes"), format = "parquet", partitioning = "la", basename_template = b, compression = "zstd")
    rm(tb); gc(FALSE) }
  s <- data.table(tile = id, oas = FR$tiles[tile == id, oas], oas_with_pairs = uniqueN(od$oa21cd), pairs = nrow(od), routed = sum(!is.na(od$route_m)),
                  bike_lts2 = sum(!is.na(od$bike_min_lts2)), bike_lts4 = sum(!is.na(od$bike_min_lts4)), authorities = uniqueN(od$la), gathered = format(Sys.time()))
  fwrite(s, file.path(TD, "gathered.csv")); message(id, ": ", format(nrow(od), big.mark = ","), " pairs gathered into ", uniqueN(od$la), " authority folders"); s
}
arg <- commandArgs(trailingOnly = TRUE)[1]
if (!is.na(arg)) { one(arg) } else {
  done <- basename(dirname(list.files(file.path(CACHE, "tiles"), "^DONE$", recursive = TRUE, full.names = TRUE)))
  for (id in done[!file.exists(file.path(CACHE, "tiles", done, "gathered.csv"))]) one(id)
  sm <- rbindlist(lapply(done, function(id) fread(file.path(CACHE, "tiles", id, "gathered.csv"))))
  sm <- if (nrow(sm)) merge(FR$tiles[, .(tile, oas)], sm[, !"oas"], by = "tile", all.x = TRUE) else FR$tiles[, .(tile, oas)]
  fwrite(sm, file.path(OUT, "tile_summary.csv"))
  message(sum(!is.na(sm$pairs)), " of ", nrow(sm), " tiles gathered; ", format(sum(sm$pairs, na.rm = TRUE), big.mark = ","), " pairs")
}
