# 00_config.R - Paths, constants and shared helpers
# ---------------------------------------------------------------------------
# The large source files (England OpenStreetMap, OS Terrain 50, Census 2021, GIAS)
# were downloaded for the school_value_added project and are read from there rather
# than copied. Set SVA_DIR if that project is not a sibling of this one.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({ library(data.table) })

SVA <- normalizePath(Sys.getenv("SVA_DIR", here::here("..", "school_value_added")), winslash = "/", mustWork = TRUE)
SRC <- list(
  osm     = file.path(SVA, "data-raw", "r5", "src", "england-latest.osm.pbf"),   # Geofabrik England extract
  dem     = file.path(SVA, "data", "cache", "journey", "terrain50_gb.vrt"),      # OS Terrain 50, 50 m grid
  gias    = file.path(SVA, "data-raw", "gias", "edubasealldata20260610.csv"),    # Get Information about Schools, 10 June 2026
  oa_pwc  = file.path(SVA, "data", "cache", "oa_pwc_2021.rds"),                  # ONS population-weighted OA centroids, 2021
  census  = file.path(SVA, "data-raw", "census2021"),                            # Census 2021 topic summaries (Nomis bulk)
  ons     = file.path(SVA, "data-raw", "census2021", "ons_custom"),              # ONS lookups: OA-LSOA-MSOA, LSOA-LAD/UTLA, RUC
  oac     = file.path(SVA, "data-raw", "oac2021", "uk_oac_final.csv"),           # 2021 Output Area Classification
  osmosis = Sys.getenv("OSM_MERGE_TOOL", file.path(dirname(SVA), "osmosis-0.49.2", "bin", "osmosis.bat"))
)

CACHE <- here::here("data", "cache"); OUT <- here::here("data", "out"); NET <- here::here("data", "net"); LOGS <- here::here("logs")
for (d in c(CACHE, OUT, NET, LOGS)) dir.create(d, showWarnings = FALSE, recursive = TRUE)
FRAME_F <- file.path(CACHE, "frame.rds")

# Reach: every school within 120 minutes' walk at 4.8 km/h, that is 9.6 km along the
# walking route. A route of 9.6 km never leaves a 9.6 km circle round its start, so a
# tile's schools are those within its core plus 10 km, and its streets the core plus 12 km.
WALK_SPEED <- 4.8; MAX_MIN <- 120; REACH_M <- WALK_SPEED * 1000 * MAX_MIN / 60
TILE_M <- 60000; SCHOOL_BUF <- 10000; NET_BUF <- 12000
BIKE_SPEED <- 12; LTS <- c(2L, 4L)   # quiet streets only, and any street a bike may use
BIKE_MAX <- 60L     # cycling search, minutes: 12 km at 12 km/h, a quarter more than the 9.6 km walking reach
ROUTE_DATE <- as.Date("2026-11-17")  # a Tuesday in term; walking and cycling do not depend on it

java_setup <- function(heap = Sys.getenv("R5R_HEAP", "20G")) {
  JH <- Sys.getenv("JAVA_HOME")
  if (!nzchar(JH) || !dir.exists(JH)) { JH <- file.path(Sys.getenv("LOCALAPPDATA"), "R", "cache", "R", "rJavaEnv", "installed", "windows", "x64", "21"); Sys.setenv(JAVA_HOME = JH) }
  options(java.parameters = paste0("-Xmx", heap))
  proj_db <- system.file("proj", package = "terra"); if (nzchar(proj_db)) Sys.setenv(PROJ_LIB = proj_db, PROJ_DATA = proj_db)
}
mins <- function(t0) as.numeric(difftime(Sys.time(), t0, units = "mins"))
