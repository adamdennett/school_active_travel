# 02_osm.R - Clip England's OpenStreetMap to each tile's streets
# ---------------------------------------------------------------------------
# Osmosis reads the Geofabrik England extract once per pass and tees it to a box for
# each tile: the tile's 60 km core plus 12 km (a 9.6 km walk cannot leave it), as in
# school_value_added R/26. MAX_TEE tiles per pass (default 30) keeps memory in hand.
# Output: data/net/<tile>/network.osm.pbf. Tiles already clipped are skipped.
# ---------------------------------------------------------------------------

source(here::here("R", "00_config.R")); java_setup()
suppressPackageStartupMessages({ library(sf) })
stopifnot(file.exists(SRC$osmosis), file.exists(SRC$osm))
Sys.setenv(JAVA_OPTS = Sys.getenv("OSMOSIS_HEAP", "-Xmx16G"))
FR <- readRDS(FRAME_F); tiles <- FR$tiles
todo <- tiles[!file.exists(file.path(NET, tile, "network.osm.pbf"))]
if (nzchar(Sys.getenv("TILES"))) todo <- todo[tile %in% strsplit(Sys.getenv("TILES"), ",")[[1]]]   # e.g. a test
MAX_TEE <- as.integer(Sys.getenv("MAX_TEE", "30"))
ll_box <- function(b) st_bbox(st_transform(st_as_sfc(st_bbox(c(xmin = b$xmin - NET_BUF, ymin = b$ymin - NET_BUF, xmax = b$xmax + NET_BUF, ymax = b$ymax + NET_BUF), crs = 27700)), 4326))
for (pass in split(seq_len(nrow(todo)), ceiling(seq_len(nrow(todo)) / MAX_TEE))) {
  tp <- todo[pass]; tmp <- file.path(NET, tp$tile, "network.osm.pbf.part")
  args <- c("--read-pbf", paste0("file=", normalizePath(SRC$osm, winslash = "/")), "--tee", paste0("outputCount=", nrow(tp)))
  for (i in seq_len(nrow(tp))) { b <- ll_box(tp[i]); dir.create(file.path(NET, tp$tile[i]), showWarnings = FALSE, recursive = TRUE)
    args <- c(args, "--buffer", "--bounding-box", sprintf("left=%.4f", b$xmin), sprintf("right=%.4f", b$xmax), sprintf("top=%.4f", b$ymax), sprintf("bottom=%.4f", b$ymin),
              "clipIncompleteEntities=true", "--write-pbf", paste0("file=", normalizePath(tmp[i], winslash = "/", mustWork = FALSE))) }
  t0 <- Sys.time(); st <- system2(SRC$osmosis, args); message(sprintf("osmosis pass of %d tiles: exit %s in %.0f min", nrow(tp), st, mins(t0)))
  if (st != 0) stop("osmosis failed")
  # Renamed only once the pass has finished, so a stopped pass leaves no half-written file behind
  file.rename(tmp, file.path(NET, tp$tile, "network.osm.pbf"))
}
print(data.table(tile = tiles$tile, mb = round(file.size(file.path(NET, tiles$tile, "network.osm.pbf")) / 1024^2)))
