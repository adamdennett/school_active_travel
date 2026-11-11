# 01_frame.R - Origins, schools and tiles for routing all of England
# ---------------------------------------------------------------------------
# Origins: every Output Area in England (Census 2021, 178,605), placed at the ONS
#   population-weighted centroid, with children by age band (TS007a), cars or vans
#   (TS045), household deprivation (TS011), rural-urban class (RUC 2021) and the
#   2021 Output Area Classification.
# Schools: every open mainstream school in England from GIAS (10 June 2026), state-
#   funded and independent, that teaches some primary ages (lowest age 10 or under,
#   highest 7 or over) or some secondary ages (lowest 14 or under, highest 12 or over).
#   Special schools, alternative provision, pupil referral units, colleges and
#   sixth-form-only schools are left out.
# Tiles: a 60 km grid on the National Grid. A tile routes its own Output Areas to the
#   schools within its core plus 10 km, on streets within its core plus 12 km.
# Also: each Output Area's three nearest primary and secondary schools in a straight
#   line, at any distance, so places with nothing walkable are still described.
# Output: data/cache/frame.rds; data/out/origins.parquet, schools.parquet, oa_nearest.parquet
# ---------------------------------------------------------------------------

source(here::here("R", "00_config.R"))
suppressPackageStartupMessages({ library(sf) })
num <- function(x) suppressWarnings(as.numeric(x))
cen <- function(topic) fread(file.path(SRC$census, topic, paste0("census2021-", topic, "-oa.csv")), check.names = FALSE)

# ---- Origins ---------------------------------------------------------------------
oa <- as.data.table(readRDS(SRC$oa_pwc))[startsWith(oa21cd, "E"), .(oa21cd, e = num(easting), n = num(northing))]
stopifnot(!anyNA(oa$e))
lk <- fread(file.path(SRC$ons, "oa_lsoa_msoa_2021.csv")); setnames(lk, c("oa21cd", "lsoa21cd", "msoa21cd"))
lad <- fread(file.path(SRC$ons, "lsoa_lad23.csv")); utla <- fread(file.path(SRC$ons, "lsoa_utla23.csv")); ruc <- fread(file.path(SRC$ons, "lsoa_ruc21.csv"))
oa <- merge(oa, lk, by = "oa21cd", all.x = TRUE)
oa <- merge(oa, lad[, .(lsoa21cd = LSOA21CD, lad23nm = LAD23NM)], by = "lsoa21cd", all.x = TRUE)
oa <- merge(oa, utla[, .(lsoa21cd = LSOA21CD, utla23nm = UTLA23NM)], by = "lsoa21cd", all.x = TRUE)
oa <- merge(oa, ruc[, .(lsoa21cd = LSOA21CD, ruc21 = RUC21NM)], by = "lsoa21cd", all.x = TRUE)
a <- cen("ts007a"); a <- a[, .(oa21cd = `geography code`, people = `Age: Total`, age_0_4 = `Age: Aged 4 years and under`, age_5_9 = `Age: Aged 5 to 9 years`, age_10_14 = `Age: Aged 10 to 14 years`, age_15_19 = `Age: Aged 15 to 19 years`)]
c45 <- cen("ts045"); c45 <- c45[, .(oa21cd = `geography code`, households = `Number of cars or vans: Total: All households`, hh_no_car = `Number of cars or vans: No cars or vans in household`, hh_1_car = `Number of cars or vans: 1 car or van in household`, hh_2_cars = `Number of cars or vans: 2 cars or vans in household`, hh_3plus_cars = `Number of cars or vans: 3 or more cars or vans in household`)]
c11 <- cen("ts011"); setnames(c11, c("date", "geography", "oa21cd", "hh_dep_total", "hh_dep_0", "hh_dep_1", "hh_dep_2", "hh_dep_3", "hh_dep_4")); c11 <- c11[, !c("date", "geography", "hh_dep_total")]
oac <- fread(SRC$oac, colClasses = "character")[, .(oa21cd = GeographyCode, lad25cd = LAD25Code, lad25nm = LAD25Name, oac_supergroup = Supergroup, oac_group = Group, oac_subgroup = Subgroup)]
oa <- Reduce(function(x, y) merge(x, y, by = "oa21cd", all.x = TRUE), list(oa, a, c45, c11, oac))
xy <- st_coordinates(st_transform(st_as_sf(oa, coords = c("e", "n"), crs = 27700), 4326)); oa[, `:=`(lon = xy[, 1], lat = xy[, 2])]
# Outputs are filed by the local authority (district or unitary, 2025) of the home Output Area
oa[, la := paste0(lad25cd, "_", gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", tolower(lad25nm))))]
stopifnot(nrow(oa) == 178605, !anyNA(oa$age_10_14), !anyNA(oa$lad23nm), !anyNA(oa$lad25cd))
message(nrow(oa), " Output Areas; ", sum(is.na(oa$oac_supergroup)), " without an OAC code")

# ---- Schools ---------------------------------------------------------------------
g <- fread(SRC$gias, encoding = "Latin-1", colClasses = "character")
g <- g[grepl("^Open", `EstablishmentStatus (name)`) & !`GOR (name)` %in% c("Wales (pseudo)", "Not Applicable", "")]
keep_grp <- c("Academies", "Free Schools", "Local authority maintained schools", "Independent schools")
g <- g[`EstablishmentTypeGroup (name)` %in% keep_grp & !grepl("special|alternative provision|16 to 19|studio", `TypeOfEstablishment (name)`, ignore.case = TRUE)]
s <- g[, .(urn = as.integer(URN), name = EstablishmentName, type = `TypeOfEstablishment (name)`, type_group = `EstablishmentTypeGroup (name)`,
           phase = `PhaseOfEducation (name)`, low_age = num(StatutoryLowAge), high_age = num(StatutoryHighAge), gender = `Gender (name)`,
           religion = `ReligiousCharacter (name)`, admissions = `AdmissionsPolicy (name)`, sixth_form = `OfficialSixthForm (name)`, boarders = `Boarders (name)`,
           pupils = num(NumberOfPupils), capacity = num(SchoolCapacity), pct_fsm = num(PercentageFSM), trust = `Trusts (name)`,
           la = `LA (name)`, urban_rural = `UrbanRural (name)`, postcode = Postcode, e = num(Easting), n = num(Northing))]
s[, `:=`(independent = type_group == "Independent schools",
         serves_primary = fifelse(!is.na(low_age) & !is.na(high_age), low_age <= 10 & high_age >= 7, phase %in% c("Primary", "Middle deemed primary", "All-through")),
         serves_secondary = fifelse(!is.na(low_age) & !is.na(high_age), low_age <= 14 & high_age >= 12, phase %in% c("Secondary", "Middle deemed secondary", "All-through")),
         selective = grepl("^Selective", admissions), faith = !religion %in% c("None", "Does not apply", "Not applicable", ""))]
n_nocoord <- s[is.na(e) | e == 0, .N]; s <- s[!is.na(e) & e > 0 & (serves_primary | serves_secondary)]
xy <- st_coordinates(st_transform(st_as_sf(s, coords = c("e", "n"), crs = 27700), 4326)); s[, `:=`(lon = xy[, 1], lat = xy[, 2])]
message(nrow(s), " schools (", s[serves_primary == TRUE, .N], " teach primary ages, ", s[serves_secondary == TRUE, .N], " secondary, ", s[independent == TRUE, .N], " independent); ", n_nocoord, " dropped for want of a location")

# ---- Tiles ------------------------------------------------------------------------
oa[, tile := sprintf("x%02d_y%02d", as.integer(e %/% TILE_M), as.integer(n %/% TILE_M))]
tiles <- oa[, .(oas = .N, kids = sum(age_5_9 + age_10_14), cx = as.integer(e[1] %/% TILE_M), cy = as.integer(n[1] %/% TILE_M)), by = tile]
tiles[, `:=`(xmin = cx * TILE_M, ymin = cy * TILE_M, xmax = (cx + 1) * TILE_M, ymax = (cy + 1) * TILE_M)]
in_box <- function(x, b, buf) x$e >= b$xmin - buf & x$e <= b$xmax + buf & x$n >= b$ymin - buf & x$n <= b$ymax + buf
tiles[, schools := vapply(seq_len(.N), function(i) sum(in_box(s, tiles[i], SCHOOL_BUF)), 1L)]
# Pairs within REACH_M in a straight line, an upper bound on what routing finds; orders the run
nb <- nabor::knn(as.matrix(s[, .(e, n)]), as.matrix(oa[, .(e, n)]), k = 400, radius = REACH_M)
oa[, pairs_ub := rowSums(nb$nn.idx > 0)]
tiles <- merge(tiles, oa[, .(pairs_ub = sum(pairs_ub)), by = tile], by = "tile")[order(-pairs_ub)]
message(nrow(tiles), " tiles; straight-line pairs within ", REACH_M / 1000, " km: ", format(sum(tiles$pairs_ub), big.mark = ","), " (", sum(nb$nn.idx[, 400] > 0), " Output Areas hit the 400 cap)")

# ---- Nearest schools in a straight line, at any distance ---------------------------
nearest <- function(flag, lab) { ss <- s[get(flag) == TRUE]; k <- nabor::knn(as.matrix(ss[, .(e, n)]), as.matrix(oa[, .(e, n)]), k = 3)
  rbindlist(lapply(1:3, function(j) data.table(oa21cd = oa$oa21cd, stage = lab, rank = j, urn = ss$urn[k$nn.idx[, j]], straight_m = round(k$nn.dists[, j])))) }
near <- rbind(nearest("serves_primary", "primary"), nearest("serves_secondary", "secondary"))

saveRDS(list(oa = oa, sch = s, tiles = tiles, built = Sys.time()), FRAME_F)
arrow::write_parquet(oa[, !c("pairs_ub")], file.path(OUT, "origins.parquet"))
arrow::write_parquet(s, file.path(OUT, "schools.parquet"))
arrow::write_parquet(near, file.path(OUT, "oa_nearest.parquet"))
print(tiles[1:10, .(tile, oas, schools, pairs_ub)])
