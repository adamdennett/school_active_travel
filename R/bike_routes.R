# bike_routes.R - Cycling routes for chosen pairs, worked out on demand
# ---------------------------------------------------------------------------
# The national run saves a walking route, height profile and climb for every pair, but
# only cycling TIMES (from r5r's travel-time matrix, which gives no line). This routes a
# handful of chosen pairs by bike, with the same settings as the national run, and gives
# their lines, height profiles and climb.
#
#   source(here::here("R", "bike_routes.R"))
#   bk <- bike_routes(pairs)          # pairs: a data frame with oa21cd and urn
#   bike_profiles(bk)                 # one row per 50 m point: distance_m, height_m
#
# Each pair is routed on the street network of its home Output Area's tile (data/net/<tile>,
# built by the national run; built here from the clipped streets if not yet). Loading a
# network takes about a minute and a few GB of memory (more for the London tiles). Java's
# memory limit is set once per R session, when r5r first starts (heap, default 8G).
# Settings: 12 km/h; quiet streets only (level of traffic stress 2) and any street a bike
# may use (LTS 4); routes over 60 minutes are not returned, as in the national run.
# ---------------------------------------------------------------------------

source(here::here("R", "00_config.R"))
PROFILE_STEP <- 50

bike_routes <- function(pairs, lts = LTS, heap = "8G", threads = 4) {
  if (!"rJava" %in% loadedNamespaces()) java_setup(heap) else message("Java is already running: its memory limit was set when it started")
  suppressPackageStartupMessages({ library(r5r); library(sf) })
  o <- as.data.table(arrow::read_parquet(file.path(OUT, "origins.parquet"), col_select = c("oa21cd", "lon", "lat", "tile")))
  s <- as.data.table(arrow::read_parquet(file.path(OUT, "schools.parquet"), col_select = c("urn", "lon", "lat")))
  p <- unique(as.data.table(pairs)[, .(oa21cd, urn = as.integer(urn))])
  p <- merge(p, o[, .(oa21cd, tile)], by = "oa21cd")[urn %in% s$urn]   # known Output Areas and schools only
  at <- as.POSIXct(paste(ROUTE_DATE, "08:00:00"), tz = "Europe/London")
  res <- list()
  for (tl in unique(p$tile)) {
    pt <- p[tile == tl]; t0 <- Sys.time()
    net <- build_network(file.path(NET, tl), verbose = FALSE, elevation = "NONE")
    or <- o[match(pt$oa21cd, oa21cd), .(id = oa21cd, lon, lat)]
    de <- s[match(pt$urn, urn), .(id = as.character(urn), lon, lat)]
    for (l in lts) {
      x <- detailed_itineraries(net, origins = or, destinations = de, mode = "BICYCLE", departure_datetime = at,
                                bike_speed = BIKE_SPEED, max_lts = l, max_bike_time = BIKE_MAX, max_trip_duration = BIKE_MAX,
                                shortest_path = TRUE, all_to_all = FALSE, drop_geometry = FALSE, n_threads = threads, progress = FALSE)
      if (!nrow(x)) next
      # One line per pair (a trip can come back in more than one segment)
      x <- x |> dplyr::group_by(from_id, to_id) |>
        dplyr::summarise(bike_min_route = sum(segment_duration), bike_route_m = round(sum(distance)), do_union = FALSE, .groups = "drop")
      x <- st_transform(x, 27700); st_geometry(x) <- st_line_merge(st_geometry(x))
      res[[length(res) + 1]] <- cbind(data.table(oa21cd = x$from_id, urn = as.integer(x$to_id), lts = l,
                                                 bike_min_route = round(x$bike_min_route, 1), bike_route_m = x$bike_route_m),
                                      route_heights(st_geometry(x)), geometry = st_geometry(x))
    }
    stop_r5(net); rJava::.jgc(R.gc = TRUE)
    message(sprintf("%s: %d pairs routed by bike in %.1f min", tl, nrow(pt), mins(t0)))
  }
  if (!length(res)) return(NULL)
  b <- st_sf(as.data.frame(rbindlist(res)), crs = 27700)
  b$lts_label <- ifelse(b$lts == 2, "Bike, quiet streets (LTS 2)", "Bike, any street (LTS 4)")
  b
}

# Height every 50 m along each line (OS Terrain 50, bilinear), and climb each way
route_heights <- function(g) {
  dem <- terra::rast(SRC$dem)
  bb <- st_bbox(g); dem <- terra::crop(dem, terra::ext(bb[["xmin"]] - 200, bb[["xmax"]] + 200, bb[["ymin"]] - 200, bb[["ymax"]] + 200), snap = "out")
  co <- as.data.table(st_coordinates(g)); co[, k := .SD[[ncol(.SD)]]]   # the last L column numbers the line
  co[, d := c(0, cumsum(sqrt(diff(X)^2 + diff(Y)^2))), by = k]
  pt <- co[, { L <- d[.N]; sx <- unique(c(seq(0, L, by = PROFILE_STEP), L)); u <- !duplicated(d)
               if (L > 0) list(s = sx, x = approx(d[u], X[u], sx)$y, y = approx(d[u], Y[u], sx)$y) else list(s = 0, x = X[1], y = Y[1]) }, by = k]
  pt[, z := terra::extract(dem, cbind(x, y), method = "bilinear")[[1]]]
  st <- pt[, { run <- diff(s); dz <- diff(z); gr <- ifelse(run > 0, dz / run, 0)
    list(z_home = round(z[1], 1), z_school = round(z[.N], 1), z_max = round(max(z), 1),
         climb_to_school_m = round(sum(pmax(dz, 0)), 1), climb_to_home_m = round(sum(pmax(-dz, 0)), 1),
         max_grad_to_school = if (length(gr)) round(max(gr), 3) else 0, max_grad_to_home = if (length(gr)) round(max(-gr), 3) else 0,
         steep8_to_school_m = round(sum(run[gr >= 0.08])), steep8_to_home_m = round(sum(run[-gr >= 0.08])),
         distance_m = list(s), height_m = list(round(z, 1))) }, by = k]
  st[order(k), !"k"]
}

# One row per 50 m point, for plotting
bike_profiles <- function(b) {
  d <- st_drop_geometry(b)
  rbindlist(lapply(seq_len(nrow(d)), function(i) data.table(oa21cd = d$oa21cd[i], urn = d$urn[i], mode = d$lts_label[i],
                                                             distance_m = d$distance_m[[i]], height_m = d$height_m[[i]])))
}
