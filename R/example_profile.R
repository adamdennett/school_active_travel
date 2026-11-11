source(here::here("R", "read_helpers.R")); suppressPackageStartupMessages({library(dplyr); library(ggplot2)})
s <- arrow::read_parquet(here::here("data","out","schools.parquet"))
od <- od_open() |> filter(oa21cd == "E00085094") |> collect() |> left_join(s |> select(urn, name), by = "urn") |> arrange(walk_min_r5)
print(head(od |> select(name, straight_m, route_m, walk_min_r5, tobler_min_to_school, tobler_min_to_home, climb_to_school_m, climb_to_home_m, bike_min_lts2, bike_min_lts4), 8))
u <- od$urn[grepl("Stringer", od$name)][1]; pr <- route_profile("E00085094", u); rt <- route_line("E00085094", u)
cat("profile points", nrow(pr), " line length", round(sf::st_length(rt)), "\n")
p <- ggplot(pr, aes(distance_m / 1000, height_m)) + geom_area(fill = "#C9B6E4", alpha = .6) + geom_line(colour = "#4B2D7F", linewidth = .8) +
  labs(x = "Distance along the walking route (km)", y = "Ground height (m)", title = "Whitehawk (E00085094) to Dorothy Stringer: height every 50 m") + theme_minimal(13)
ggsave(here::here("docs", "example_profile.png"), p, width = 8, height = 3.6, dpi = 120)
