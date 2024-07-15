library(tidyverse)
library(readxl)

# remotes::install_github("humaniverse/geographr")
library(geographr)

# ---- Load and wrangle Ethnic Group Deprivation Index ----
# We can't share this data; please ask the researchers for a copy first then add the path here
egdi <- read_excel("<INSERT PATH TO EGDI DATA HERE>", sheet = "Data")

# Data wrangling
egdi <- 
  egdi |> 
  mutate(`Range (1 = greatest difference)` = as.numeric(`Range (1 = greatest difference)`)) |> 
  
  # Make sure LA names match official names
  mutate(`Local authority` = case_match(
    `Local authority`,
    "Birmingham1" ~ "Birmingham",
    "Bristol" ~ "Bristol, City of",
    "Herefordshire" ~ "Herefordshire, County of",
    "Kingston upon Hull" ~ "Kingston upon Hull, City of",
    "Leeds1" ~ "Leeds",
    .default = `Local authority`
  ))

# ---- Calculate numbers of LSOAs in each decile for each Local Authority ----
# This data will be used in the .xlsx version of the profiles
egdi |> 
  filter(`Most deprived group` != "NA") |> 
  select(`Local authority`, `Range (1 = greatest difference)`) |> 
  drop_na() |> 
  
  # Bin range into deciles; ranges closer to 1 would have higher deciles (and decile 10 == greatest difference)
  mutate(range_decile = ntile(`Range (1 = greatest difference)`, 10)) |> 
  # Invert deciles so 1 = greatest difference, aligned with IMD deciles
  mutate(range_decile = 11 - range_decile) |> 
  
  count(`Local authority`, range_decile) |> 
  pivot_wider(names_from = "range_decile", values_from = n) |> 
  mutate(across(where(is.integer), \(x) replace_na(x, 0))) |> 
  
  left_join(
    lookup_ltla_ltla |> distinct(ltla22_name, ltla22_code),
    by = join_by(`Local authority` == ltla22_name)
  ) |> 
  
  select(
    `Local Authority District code (2022)` = ltla22_code,
    `Local Authority District name (2022)` = `Local authority`,
    `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `10`
  ) |> 
  
  write_csv("data/egdi-ltla22.csv")

# ---- Calculate profiles for each Local Authority ----
# Describe the type of ethnic inequality in each Local Authority based on the distribution of deciles of its constituent LSOAs.
# 
# This approach is inspired by how the ONS described income deprivation in LAs as "flat", "more income deprived", "less income deprived", or "n shaped"
# which they calculated based on the distribution of LSOAs in each deprivation decile, within a Local Authority
# See https://www.ons.gov.uk/visualisations/dvc1371/#/E09000030
#
# The ONS very kindly published their data and calculations here: https://www.ons.gov.uk/peoplepopulationandcommunity/personalandhouseholdfinances/incomeandwealth/datasets/mappingincomedeprivationatalocalauthoritylevel
# (See the 'Profiles' worksheet - column AB in particular)
# I have replicated their method here
# 
# Each type of shape ("Flat", "n shape" etc.) is based on a set of scores/weights for each decile
# See cells N321:X324 in the ONS's dataset
# I copied this into a .csv file and will load it here
decile_shapes <- read_csv("data/decile-characteristics.csv") |> 
  pivot_longer(col = `1`:`10`, names_to = "Decile") |> 
  mutate(Decile = as.integer(Decile))

# Calculate deciles for range
egdi_range_deciles <- 
  egdi |> 
  filter(`Most deprived group` != "NA") |> 
  select(`Local authority`, `Range (1 = greatest difference)`) |> 
  drop_na() |> 
  mutate(range_decile = ntile(`Range (1 = greatest difference)`, 10)) |> 
  # Invert deciles so 1 = greatest difference, aligned with IMD deciles
  mutate(range_decile = 11 - range_decile) |> 
  count(`Local authority`, range_decile, name = "n_lsoa")

# Calculate the proportion of LSOAs in each decile in each LA
egdi_range_deciles_proportions <- 
  egdi_range_deciles |> 
  group_by(`Local authority`) |> 
  mutate(total_lsoa = sum(n_lsoa)) |> 
  ungroup() |> 
  mutate(prop_lsoa = n_lsoa / total_lsoa) |> 
  select(`Local authority`, range_decile, prop_lsoa)

# Some LAs do not have LSOAs with ranges in every decile, but we need to account for every decile to calculate the overall shape of the distribution
# so make a tibble with deciles 1-10 for every LA...
ltla_range_deciles <- 
  expand_grid(
    ltla22_name = lookup_ltla_ltla |> filter(str_detect(ltla22_code, "^E|^W")) |> distinct(ltla22_name) |> pull(ltla22_name),
    range_decile = 1:10
  )
#... then merge in the EGDI range deciles and the scores for each type of shape
ltla_range_shapes <- 
  ltla_range_deciles |> 
  left_join(egdi_range_deciles_proportions, by = join_by(ltla22_name == `Local authority`, range_decile)) |> 
  left_join(decile_shapes, by = join_by(range_decile == Decile)) |> 
  mutate(prop_lsoa = replace_na(prop_lsoa, 0))

# In each LA and each type of shape (flat, more inequity, less inequity, n-shaped), calculate an overall score:
# For example, "Flat" will be calculated as the sum of ([% LSOAs in decile 1] - 0.1)^2 + ([% LSOAs in decile 2] - 0.1)^2 + ...
# The type of shape with the lowest score best describes the shape of the distribution
ltla_ethnic_inequality <- 
  ltla_range_shapes |> 
  mutate(shape_value = (prop_lsoa - value)^2) |> 
  
  group_by(ltla22_name, Category) |> 
  summarise(shape_value = sum(shape_value)) |> 
  ungroup() |> 
  
  group_by(ltla22_name) |> 
  slice_min(shape_value) |> 
  ungroup() |> 
  
  select(-shape_value)

# Get LA codes
ltla_ethnic_inequality <- 
  ltla_ethnic_inequality |> 
  left_join(
    lookup_ltla_ltla |> distinct(ltla22_name, ltla22_code)
  ) |> 
  relocate(ltla22_code)

write_csv(ltla_ethnic_inequality, "data/egdi-ltla22-profiles.csv")

# Test a few different LA shapes out using this code
# egdi_range_deciles_proportions |> 
#   filter(`Local authority` == "Barking and Dagenham") |> 
#   ggplot(aes(x = factor(range_decile), y = prop_lsoa)) +
#   geom_col()
#--> All looks good
