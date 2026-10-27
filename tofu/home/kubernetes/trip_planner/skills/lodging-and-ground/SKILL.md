---
name: lodging-and-ground
description: Lodging (hotels and rentals) and ground transport (car rental, ferries, rail and buses) search for a trip. Use for every stay and every surface link between stops.
---

# Lodging and ground transport

## Lodging sources

Run these in parallel for each stay (city, check-in, check-out, guests):

| Source | Tools | Use |
|---|---|---|
| trivago (`trivago`) | `trivago-accommodation-search` (by destination or landmark), `trivago-accommodation-radius-search` (by coordinates), `trivago-destination-price-trends` | Live metasearch prices across booking sites; radius search when the user names a neighborhood, venue, or address; price trends for "when is it cheaper" questions (trends are estimates, not quotes) |
| Skiplagged (`skiplagged`) | `sk_hotels_search`, `sk_hotel_details` | Second price source; room-level availability and amenities for shortlisted hotels |
| Airbnb via `web.scrape` | `scrape` with `engine_name="headless"`, `wait_ms=5000` on `https://www.airbnb.com/s/<City>/homes?checkin=<YYYY-MM-DD>&checkout=<YYYY-MM-DD>&adults=<N>` | Rentals; worth it for 4+ nights, groups, or when a kitchen or washer matters |

Pass the trip's currency and the guest count (`adults`, `children`,
`children_ages`, `rooms`) on every call so prices are comparable.

For each shortlisted property keep: name, area, rating and review count,
nightly and total price with taxes when shown, cancellation terms when
shown, source, and link. Note when the cheapest listing is far from where
the user will spend their days; give the transit time if it is material.

Present 3 to 5 options across price tiers, sorted by total for the stay,
with one pick and the reason.

## Ground transport

| Need | Tools |
|---|---|
| Car rental | `skiplagged.sk_cars_search` (pickup/dropoff place, dates, times) |
| Ferries | `ferryhopper.search_ferry_trips` (1 to 5 legs by place name), `get_direct_connections_for_ports`, `trip_details`, and `get_disruptions` for the travel date |
| Rail, intercity bus, airport transfers | `web.search_web`, then `web.scrape` the operator's own timetable or fare page; cite it |

Between two stops, compare the realistic door-to-door options (for
example a train versus a short flight including airport time) and say
which wins on time and on cost.

## Rules

- Ground prices from operator pages are quotes only for the stated date;
  otherwise they are estimates.
- Never fail silently: list each source's status.

Adapted from the `compare-hotels` skill of borski/travel-hacking-toolkit
(MIT).
