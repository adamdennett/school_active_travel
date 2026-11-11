# 03_route.R - Route one tile: walking and cycling from every Output Area to every school in reach
# ---------------------------------------------------------------------------
# Rscript R/03_route.R <tile>     (one tile per process, so Java's memory is returned)
#
#   pairs   Walking times (r5r travel_time_matrix, 4.8 km/h, 120 minute limit) from each
#           of the tile's Output Areas to every school in its core plus 10 km. Pairs
#           within 120 minutes are the tile's origin-destination set.
#   bike    Cycling times at 12 km/h for the same pairs, on quiet streets only (level of
#           traffic stress 2) and on any street a bike may use (LTS 4).
#   routes  The walking route for every pair (r5r detailed_itineraries, shortest path),
#           in chunks. For each route: its length, a height profile from OS Terrain 50
#           (ground height every 50 m from home to school, bilinear from the 50 m grid,
#           in whole decimetres), the climb each way, the steepest 50 m each way, the
#           length steeper than 5% and 8% each way, walking time each way by Tobler's
#           hiking function scaled so that the flat is 4.8 km/h, and the line itself
#           (National Grid, simplified to 5 m, as WKB).
#
# Each step and each chunk is saved as it ends, in data/cache/tiles/<tile>; a rerun
# picks up where it stopped. Streets: data/net/<tile>/network.osm.pbf from R/02.
# Settings: R5R_HEAP (default 20G), R5R_THREADS (14), CHUNK (20000 pairs).
# ---------------------------------------------------------------------------

source(here::here("R", "00_config.R")); java_setup()
suppressPackageStartupMessages({ library(sf); library(r5r) })
id <- commandArgs(trailingOnly = TRUE)[1]; if (is.na(id)) id <- Sys.getenv("TILE"); stopifnot(nzchar(id))
N_THREADS <- as.numeric(Sys.getenv("R5R_THREADS", "14")); CHUNK <- as.numeric(Sys.getenv("CHUNK", "20000"))
STEPS <- strsplit(Sys.getenv("STEPS", "pairs,bike,routes"), ",")[[1]]
PROFILE_STEP <- 50
TD <- file.path(CACHE, "tiles", id); dir.create(TD, showWarnings = FALSE, recursive = TRUE)
f <- function(x) file.path(TD, x)
if (file.exists(f("DONE"))) { message(id, ": done already"); quit(save = "no") }
DEADLINE <- if (nzchar(Sys.getenv("DEADLINE"))) as.POSIXct(Sys.getenv("DEADLINE"), tz = "Europe/London") else Inf
stop_if_late <- function() if (Sys.time() > DEADLINE) { message(id, ": stopping at the deadline, ", format(Sys.time(), "%H:%M"), "; a rerun picks up from here"); quit(save = "no", status = 3) }
if (file.exists(file.path(dirname(CACHE), "PAUSE"))) DEADLINE <- Sys.time() - 1
stop_if_late()

FR <- readRDS(FRAME_F); tl <- FR$tiles[tile == id]; stopifnot(nrow(tl) == 1)
o <- FR$oa[tile == id]
s <- FR$sch[e >= tl$xmin - SCHOOL_BUF & e <= tl$xmax + SCHOOL_BUF & n >= tl$ymin - SCHOOL_BUF & n <= tl$ymax + SCHOOL_BUF]
or <- o[, .(id = oa21cd, lon, lat)]; de <- s[, .(id = as.character(urn), lon, lat)]
t00 <- Sys.time(); message("=== ", id, ": ", nrow(o), " Output Areas, ", nrow(s), " schools")
net <- build_network(file.path(NET, id), verbose = FALSE, elevation = "NONE")
message(sprintf("  network ready, %.1f min", mins(t00)))
at <- as.POSIXct(paste(ROUTE_DATE, "08:00:00"), tz = "Europe/London")

# With no transit and more origins than destinations, r5r searches backwards and can return
# the ids swapped, so origins go in blocks no larger than the destinations (as in
# school_value_added R/20 and R/27), and every result is checked.
ttm <- function(mode, ...) {
  blocks <- split(seq_len(nrow(or)), ceiling(seq_len(nrow(or)) / nrow(de)))
  x <- rbindlist(lapply(blocks, function(i) { y <- as.data.table(travel_time_matrix(net, origins = or[i], destinations = de, mode = mode, departure_datetime = at,
        time_window = 1, percentiles = 50, max_trip_duration = MAX_MIN, n_threads = N_THREADS, progress = FALSE, ...))
        if (nrow(y) && all(y$from_id %in% de$id) && all(y$to_id %in% or$id)) setnames(y, c("from_id", "to_id"), c("to_id", "from_id"))
        y }))
  stopifnot(all(x$from_id %in% or$id), all(x$to_id %in% de$id))
  setnames(x, grep("travel_time", names(x), value = TRUE)[1], "t"); x[, t := as.integer(t)][]
}

# ---- Pairs -------------------------------------------------------------------------
if ("pairs" %in% STEPS && !file.exists(f("pairs.parquet"))) { t0 <- Sys.time()
  p <- ttm("WALK", walk_speed = WALK_SPEED, max_walk_time = MAX_MIN)[t <= MAX_MIN]
  setnames(p, c("oa21cd", "urn", "walk_min_r5")); p[, urn := as.integer(urn)]; setorder(p, oa21cd, walk_min_r5)
  arrow::write_parquet(p, f("pairs.parquet"))
  message(sprintf("  pairs: %s in %.1f min (%.1f schools per Output Area; %d Output Areas with none)", format(nrow(p), big.mark = ","), mins(t0), nrow(p) / nrow(o), nrow(o) - uniqueN(p$oa21cd))) }
P <- as.data.table(arrow::read_parquet(f("pairs.parquet")))

# ---- Cycling -----------------------------------------------------------------------
stop_if_late()
if ("bike" %in% STEPS && !file.exists(f("bike.parquet"))) { t0 <- Sys.time()
  b <- P[, .(oa21cd, urn)]
  for (l in LTS) { x <- ttm("BICYCLE", bike_speed = BIKE_SPEED, max_bike_time = MAX_MIN, max_lts = l)
    x <- x[, .(oa21cd = from_id, urn = as.integer(to_id), t)]; setnames(x, "t", paste0("bike_min_lts", l))
    b <- merge(b, x, by = c("oa21cd", "urn"), all.x = TRUE) }
  arrow::write_parquet(b, f("bike.parquet"))
  message(sprintf("  cycling: %.1f min; pairs with no LTS 2 route: %.1f%%", mins(t0), 100 * mean(is.na(b$bike_min_lts2)))) }

# ---- Walking routes, height profiles and climb ---------------------------------------
if ("routes" %in% STEPS) {
  dem_r <- terra::rast(SRC$dem)
  box <- terra::ext(tl$xmin - NET_BUF, tl$xmax + NET_BUF, tl$ymin - NET_BUF, tl$ymax + NET_BUF)
  dem_r <- terra::crop(dem_r, box, snap = "out"); M <- terra::as.matrix(dem_r, wide = TRUE); ex <- as.vector(terra::ext(dem_r)); RES <- terra::res(dem_r)[1]
  # Bilinear interpolation between the centres of the 50 m cells
  z_at <- function(x, y) {
    fc <- (x - ex[1]) / RES + 0.5; fr <- (ex[4] - y) / RES + 0.5
    c0 <- pmin(pmax(floor(fc), 1), ncol(M) - 1); r0 <- pmin(pmax(floor(fr), 1), nrow(M) - 1); dc <- pmin(pmax(fc - c0, 0), 1); dr <- pmin(pmax(fr - r0, 0), 1)
    M[cbind(r0, c0)] * (1 - dc) * (1 - dr) + M[cbind(r0, c0 + 1)] * dc * (1 - dr) + M[cbind(r0 + 1, c0)] * (1 - dc) * dr + M[cbind(r0 + 1, c0 + 1)] * dc * dr }
  tob <- function(g) WALK_SPEED * exp(-3.5 * abs(g + 0.05)) / exp(-3.5 * 0.05)   # km/h; 4.8 on the flat
  profile <- function(g) {
    co <- as.data.table(st_coordinates(g))[, .(X, Y, k = L1)]
    co[, d := c(0, cumsum(sqrt(diff(X)^2 + diff(Y)^2))), by = k]
    pt <- co[, { L <- d[.N]; sx <- unique(c(seq(0, L, by = PROFILE_STEP), L))
                 if (L > 0) { u <- !duplicated(d); list(s = sx, x = approx(d[u], X[u], sx)$y, y = approx(d[u], Y[u], sx)$y) } else list(s = 0, x = X[1], y = Y[1]) }, by = k]
    pt[, z := z_at(x, y)]
    st <- pt[, { run <- diff(s); dz <- diff(z); gr <- ifelse(run > 0, dz / run, 0)
      list(route_m = round(s[.N]), z_home = round(z[1], 1), z_school = round(z[.N], 1), z_max = round(max(z), 1),
           climb_to_school_m = round(sum(pmax(dz, 0)), 1), climb_to_home_m = round(sum(pmax(-dz, 0)), 1),
           max_grad_to_school = if (length(gr)) round(max(gr), 3) else 0, max_grad_to_home = if (length(gr)) round(max(-gr), 3) else 0,
           steep5_to_school_m = round(sum(run[gr >= 0.05])), steep5_to_home_m = round(sum(run[-gr >= 0.05])),
           steep8_to_school_m = round(sum(run[gr >= 0.08])), steep8_to_home_m = round(sum(run[-gr >= 0.08])),
           tobler_min_to_school = round(sum(run / (tob(gr) * 1000 / 60)), 2), tobler_min_to_home = round(sum(run / (tob(-gr) * 1000 / 60)), 2),
           elev_dm = list(as.integer(round(z * 10)))) }, by = k]
    st }
  todo <- split(seq_len(nrow(P)), ceiling(seq_len(nrow(P)) / CHUNK)); todo <- head(todo, as.numeric(Sys.getenv("MAX_CHUNKS", "Inf")))
  for (j in seq_along(todo)) { fo <- f(sprintf("routes_%05d.parquet", j)); if (file.exists(fo)) next
    if (file.exists(file.path(dirname(CACHE), "PAUSE"))) DEADLINE <- Sys.time() - 1; stop_if_late()
    t0 <- Sys.time(); pj <- P[todo[[j]]]
    x <- detailed_itineraries(net, origins = or[match(pj$oa21cd, id)], destinations = de[match(as.character(pj$urn), id)], mode = "WALK", departure_datetime = at,
           walk_speed = WALK_SPEED, max_walk_time = MAX_MIN + 5, max_trip_duration = MAX_MIN + 5, shortest_path = TRUE, all_to_all = FALSE,
           drop_geometry = FALSE, n_threads = N_THREADS, progress = FALSE)
    t_r5 <- mins(t0)
    x <- x[!duplicated(st_drop_geometry(x)[, c("from_id", "to_id")]), ]
    g <- st_transform(st_geometry(x), 27700); st <- profile(g)
    gs <- st_simplify(g, dTolerance = 5)
    res <- data.table(oa21cd = x$from_id, urn = as.integer(x$to_id), walk_min_route = as.numeric(x$total_duration), r5_route_m = round(as.numeric(x$total_distance)), st[, !"k"])
    res[, geom_wkb := blob::as_blob(unclass(st_as_binary(gs)))]
    tb <- arrow::arrow_table(res); tb$elev_dm <- tb$elev_dm$cast(arrow::list_of(arrow::int16()))
    arrow::write_parquet(tb, fo, compression = "zstd")
    message(sprintf("  routes %d/%d: %s of %s pairs routed, r5r %.1f + profiles %.1f min", j, length(todo), format(nrow(res), big.mark = ","), format(nrow(pj), big.mark = ","), t_r5, mins(t0) - t_r5))
    rm(x, g, gs, st, res, tb); gc(FALSE) }
}

if (all(c("pairs", "bike", "routes") %in% STEPS) && !nzchar(Sys.getenv("MAX_CHUNKS"))) writeLines(format(Sys.time()), f("DONE"))
message(sprintf("%s done in %.1f min", id, mins(t00)))
