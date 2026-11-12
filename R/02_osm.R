# 02_osm.R - Clip England's OpenStreetMap to each tile's streets
# ---------------------------------------------------------------------------
# Osmosis clips the Geofabrik England extract to a box for each tile: the tile's 60 km
# core plus 12 km (a 9.6 km walk cannot leave it), as in school_value_added R/26. One
# process per tile, OSM_PAR (default 8) at once, each with OSMOSIS_HEAP (default -Xmx3G).
# Output: data/net/<tile>/network.osm.pbf. Tiles already clipped are skipped.
# ---------------------------------------------------------------------------

source(here::here("R", "00_config.R")); java_setup()
suppressPackageStartupMessages({ library(sf) })
stopifnot(file.exists(SRC$osmosis), file.exists(SRC$osm))

FR <- readRDS(FRAME_F); tiles <- FR$tiles
todo <- tiles[!file.exists(file.path(NET, tile, "network.osm.pbf"))]
if (nzchar(Sys.getenv("TILES"))) todo <- todo[tile %in% strsplit(Sys.getenv("TILES"), ",")[[1]]]   # e.g. a test

ll_box <- function(b) st_bbox(st_transform(st_as_sfc(st_bbox(c(xmin = b$xmin - NET_BUF, ymin = b$ymin - NET_BUF, xmax = b$xmax + NET_BUF, ymax = b$ymax + NET_BUF), crs = 27700)), 4326))
# One osmosis process per tile, OSM_PAR at a time. (A single pass teed to 30 tiles ran
# about 28 times slower than one tile, so the tee was a bottleneck; separate processes
# use the cores. Each reads the 1.7 GB extract, which stays in the disk cache.)
clip <- function(tile, b) {
  tmp <- file.path(NET, tile, "network.osm.pbf.part"); dir.create(dirname(tmp), showWarnings = FALSE, recursive = TRUE)
  args <- c("--read-pbf", paste0("file=", normalizePath(SRC$osm, winslash = "/")),
            "--bounding-box", sprintf("left=%.4f", b[["xmin"]]), sprintf("right=%.4f", b[["xmax"]]), sprintf("top=%.4f", b[["ymax"]]), sprintf("bottom=%.4f", b[["ymin"]]),
            "clipIncompleteEntities=true", "--write-pbf", paste0("file=", normalizePath(tmp, winslash = "/", mustWork = FALSE)))
  t0 <- Sys.time(); st <- system2(SRC$osmosis, args, stdout = FALSE, stderr = FALSE)
  # Renamed only once the clip has finished, so a stopped clip leaves no half-written file behind
  if (st == 0) file.rename(tmp, file.path(NET, tile, "network.osm.pbf"))
  sprintf("%s: exit %s in %.1f min", tile, st, as.numeric(difftime(Sys.time(), t0, units = "mins")))
}
if (nrow(todo)) {
  Sys.setenv(JAVA_OPTS = Sys.getenv("OSMOSIS_HEAP", "-Xmx3G"))
  boxes <- lapply(seq_len(nrow(todo)), function(i) unclass(ll_box(todo[i])))
  cl <- parallel::makeCluster(min(nrow(todo), as.integer(Sys.getenv("OSM_PAR", "8"))))
  parallel::clusterExport(cl, c("NET", "SRC"))
  t0 <- Sys.time(); res <- parallel::clusterMap(cl, clip, todo$tile, boxes, .scheduling = "dynamic"); parallel::stopCluster(cl)
  message(paste(unlist(res), collapse = "\n")); message(sprintf("clipped %d tiles in %.0f min", nrow(todo), mins(t0)))
  if (!all(file.exists(file.path(NET, todo$tile, "network.osm.pbf")))) stop("osmosis failed for some tiles")
}
print(data.table(tile = tiles$tile, mb = round(file.size(file.path(NET, tiles$tile, "network.osm.pbf")) / 1024^2)))
