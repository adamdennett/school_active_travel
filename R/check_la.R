# check_la.R - Look over one authority's outputs
# ---------------------------------------------------------------------------
# LA=E06000043_brighton_and_hove Rscript R/check_la.R
# Prints what each file holds and how complete it is, and draws docs/check_<la>.png:
# every walking route to secondary schools within 30 minutes, coloured by climb to school.
# ---------------------------------------------------------------------------
source(here::here("R", "read_helpers.R")); source(here::here("R", "00_config.R"))
suppressPackageStartupMessages({ library(dplyr); library(ggplot2); library(sf) })
a <- Sys.getenv("LA", "E06000043_brighton_and_hove")
s <- as.data.table(arrow::read_parquet(out_dir("schools.parquet"))); o <- as.data.table(arrow::read_parquet(out_dir("origins.parquet")))[la == a]
od <- as.data.table(od_open() |> filter(la == a) |> collect())
cat("\n==", a, "==\nfiles:\n"); for (d in c("od", "profiles", "routes")) { f <- list.files(out_dir(d, paste0("la=", a)), full.names = TRUE); cat(sprintf("  %-9s %s  (%.1f MB)\n", d, paste(basename(f), collapse = ", "), sum(file.size(f)) / 1e6)) }
cat(sprintf("Output Areas %d, with a school in reach %d; pairs %s; schools reached %d\n", nrow(o), uniqueN(od$oa21cd), format(nrow(od), big.mark = ","), uniqueN(od$urn)))
od <- merge(od, s[, .(urn, name, serves_primary, serves_secondary, independent)], by = "urn")
cat("per Output Area: primary schools in reach (median)", od[serves_primary == TRUE, .N, by = oa21cd][, median(N)], "; secondary", od[serves_secondary == TRUE, .N, by = oa21cd][, median(N)], "\n")
cat("missing: route", sum(is.na(od$route_m)), "; LTS 2 bike", sum(is.na(od$bike_min_lts2)), "; LTS 4 bike", sum(is.na(od$bike_min_lts4)), "\n\ncolumns of od:\n"); print(str(od[, !c("name")], give.attr = FALSE, vec.len = 2))
pr <- arrow::open_dataset(out_dir("profiles")) |> filter(la == a) |> collect()
cat("\nprofiles:", nrow(pr), "rows; points per profile (median)", median(lengths(pr$elev_dm)), "\n")
near <- od[serves_secondary == TRUE & walk_min_r5 <= 30]
rt <- arrow::open_dataset(out_dir("routes")) |> filter(la == a) |> collect() |> as.data.table()
rt <- merge(rt, near[, .(oa21cd, urn, climb_to_school_m)], by = c("oa21cd", "urn"))
g <- st_sf(climb = rt$climb_to_school_m, geometry = st_as_sfc(structure(lapply(rt$geom_wkb, as.raw), class = "WKB"), crs = 27700))
p <- ggplot(g) + geom_sf(aes(colour = pmin(climb, 80)), linewidth = 0.15, alpha = 0.5) + scale_colour_viridis_c(option = "magma", direction = -1, name = "Climb to school (m)") +
  geom_point(data = s[urn %in% near$urn], aes(e, n), shape = 21, fill = "white", size = 2) + coord_sf(datum = NA) +
  labs(title = paste0(o$lad25nm[1], ": walking routes to secondary schools within 30 minutes"), x = NULL, y = NULL) + theme_minimal(12)
ggsave(here::here("docs", paste0("check_", a, ".png")), p, width = 9, height = 6.5, dpi = 110)
cat("map: docs/check_", a, ".png (", nrow(rt), " routes)\n", sep = "")
