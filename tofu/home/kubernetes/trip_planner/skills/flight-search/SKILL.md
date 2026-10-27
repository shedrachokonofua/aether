---
name: flight-search
description: Cash flight search across Google Flights (fli), Kiwi.com, and Skiplagged, with round-trip versus one-way comparison, flexible dates, and market checks. Use for every flight leg of a trip or any fare question.
---

# Flight search

Search every source for every leg. Sources disagree on price and coverage;
the order below decides which price to trust, not which sources to skip.

## Sources

| Source | Tools | Strengths | Watch for |
|---|---|---|---|
| Google Flights (`flights`) | `search_flights`, `search_dates`, `get_booking_options`, `find_airports` | Widest airline coverage, date-specific fares, filters (stops, airlines, alliances, layovers, departure window), `currency`/`country`/`language` for market checks; `get_booking_options` returns airline-direct and agency prices with booking URLs for a chosen flight | Unofficial access to Google; if it errors, say so and lean on the others. On `retryable: true`, retry at most twice with backoff |
| Kiwi.com (`kiwi`) | `search-flight` | Virtual interlining (mixed-airline itineraries), +/- flex days, booking links | Self-transfer itineraries: separate tickets, no protection if a leg slips. Weak on small domestic markets |
| Skiplagged (`skiplagged`) | `sk_flights_search`, `sk_flex_departure_calendar`, `sk_flex_return_calendar`, `sk_resolve_iata`, `sk_destinations_anywhere` | Cheapest-day calendars, hidden-city fares, IATA lookup | Hidden-city fares: carry-on only, one-way only, and airlines penalize the practice. Never recommend one without saying so |
| Web fallback (`web`) | `scrape` | Last resort when a structured source fails | See "Web fallback" |

Trust order when quotes disagree for the same flight: airline site >
Google Flights > Kiwi/Skiplagged. A price you can tie to a booking link
beats one you cannot.

## Workflow per leg

1. Resolve airports: use every airport that serves the city (for example
   Beijing PEK and PKX, Tokyo NRT and HND, London LHR/LGW/STN/LCY).
   `flights.find_airports` or `skiplagged.sk_resolve_iata` for unfamiliar
   cities; pass several codes comma-separated to `search_flights`.
2. In one parallel batch:
   - `flights.search_flights` for the exact date (sort CHEAPEST, then
     again with `max_stops=NON_STOP` when nonstops may exist).
   - `kiwi.search-flight` with `departureDateFlexDays` of 1 to 3 when the
     user has any flexibility.
   - `skiplagged.sk_flights_search` (standard fares; include hidden-city
     only to report it, labelled).
3. If dates are flexible: `flights.search_dates` over the window, or
   `skiplagged.sk_flex_departure_calendar` / `sk_flex_return_calendar`,
   then re-quote the cheapest days with `search_flights`.
4. International: re-run `search_flights` with `country` set to the
   destination's market (and `currency` unchanged) and report any gap
   over about 5 percent.
5. For each flight you recommend, call `flights.get_booking_options` with
   its `flight_numbers` and the same filters you searched with. Its
   airline-direct price and URL make the fare **quoted**; list agency
   options only when cheaper, with their name.

## Round trip versus one-way pairs

With a return date, always price both, in the same batch:

- the round-trip fare (`return_date` on `search_flights`, `returnDate`
  on Kiwi/Skiplagged), and
- two independent one-ways, which also surfaces mixed carriers.

State the verdict with the delta ("round trip CA$1,842 vs one-way pair
CA$1,918: round trip saves CA$76"). Under about CA$50 apart, mention the
flexibility of separate tickets.

## Reading results

For each candidate keep: carrier(s) and flight numbers, local departure
and arrival with dates, total duration, stops with layover airport and
length, fare, currency, source, and booking link when given.
Flag: overnight or under-90-minute international connections, airport
changes within a connection, self-transfers, and basic-economy fares that
exclude bags or seat selection when that is visible.

## Web fallback (`web.scrape`)

Use only when the structured sources fail or for a sanity check:

- Google Flights search page, fetched directly, returns date-specific
  fares under "Top flights":
  `https://www.google.com/travel/flights?q=Flights%20to%20<DEST>%20from%20<ORIGIN>%20on%20<YYYY-MM-DD>%20one%20way&hl=en&gl=<country>&curr=<CUR>`
- Kayak results need a browser: `scrape` with `engine_name="headless"`
  and `wait_ms=6000`.
- Skyscanner blocks automated access (PerimeterX); skip it. Expedia
  rate-limits (HTTP 429).

Label any price from this path as low-confidence unless it matches a
structured source.

Adapted from the `flight-search-strategy`, `compare-flights`, and
`google-flights` skills of borski/travel-hacking-toolkit (MIT).
