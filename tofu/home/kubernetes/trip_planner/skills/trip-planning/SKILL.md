---
name: trip-planning
description: End-to-end cash trip planning. Use for any request to plan, price, or compare a trip (flights plus lodging, ground transport, entry rules, itinerary, budget). Orchestrates flight-search, lodging-and-ground, and entry-and-booking.
---

# Trip planning

Turn "plan a trip to X" into one priced, sourced, bookable plan. Cash only:
no points, miles, or card portals.

## 1. Pin down the request

Extract, and ask only for what changes the search:

| Input | Default if unstated |
|---|---|
| Origin (city/airport) | Ask |
| Destination(s), order of stops | Ask |
| Dates or window, and how flexible | Ask |
| Travelers (adults, children with ages, infants) | 1 adult |
| Cabin | Economy |
| Budget ceiling, currency | No ceiling; currency of the origin country |
| Constraints: nonstop only, max layover, airlines to avoid, bags, accessibility | None |
| Passport nationality (for visas and transit) | Ask if any border is crossed |

Never guess dates, traveler count, or nationality. One short question
batch, then work.

## 2. Search in parallel

Launch every independent search at once; do not wait on one to start another.

- Flights for every leg, both constructions (round trip and one-way pairs),
  per `flight-search`.
- Lodging for every stay, per `lodging-and-ground`.
- Ground links between stops (rail, ferry, car), per `lodging-and-ground`.
- Entry, visa, and transit rules for every border crossed and every
  connection airport, per `entry-and-booking`.

Track each source's status as you go: `ok (N results)`, `error: <message>`,
or `skipped: <reason>`.

## 3. Verify, do not assume

Every price is one of:

- **Quoted**: a date-specific fare or rate a tool returned for these exact
  dates and travelers, with its source and booking link.
- **Estimate**: anything else (route averages, price trends, "from" prices,
  a single scraped page). Label it, and say what would make it quoted.

Never present an estimate as a quote. If every source for a component
failed, say so and price that component as an estimate with the reason.

## 4. Build the plan

1. **Itinerary**: day by day, with travel legs, check-ins, and connections.
   Flag tight connections (under 90 min international, or a self-transfer
   between separate tickets) and overnight layovers.
2. **Options**: 3 to 5 ranked combinations, not every result. Typical axes:
   cheapest, best value (price versus time and stops), most comfortable
   (nonstop, better hotel).
3. **Cost matrix**: one row per option, columns for each leg, lodging,
   ground, and total, in one currency. State the exchange rate and date
   when converting.
4. **Recommendation**: the winner in one or two sentences, and why.
5. **Book first**: what to book in which order, and what can wait
   (see `entry-and-booking`).
6. **Sources**: the status list from step 2, and every URL used.

## Output

- Markdown tables for options and the cost matrix; bold the winner.
- Times in local time with the date; mark next-day arrivals (`+1`).
- Name the source of every price ("via flights/search_flights",
  "via kiwi", "via trivago").
- End with concrete next steps you can take in this session (other dates,
  nearby airports, a different hotel area), stated, not asked.

## Failure rules

- Never fail silently. A failed source is listed with its error and the
  plan continues with what remains.
- Call a tool before concluding it is unavailable.
- Never replace the structured sources with improvised page scraping and
  call the result a market price; scraped prices are low-confidence and
  labelled as such.

Adapted from the `trip-planner`, `plan-trip`, and `fallback-and-resilience`
skills of borski/travel-hacking-toolkit (MIT, see NOTICE).
