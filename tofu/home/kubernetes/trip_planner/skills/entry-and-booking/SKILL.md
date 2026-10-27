---
name: entry-and-booking
description: Visa, transit, and entry requirements for every border and connection, plus booking order, fare rules, and risk checks before the user pays. Use whenever a trip crosses a border or the user is ready to book.
---

# Entry requirements and booking

## Entry, visa, and transit

For each country entered **and each connection airport** (transit rules
differ from entry rules), using the traveler's passport nationality:

1. `web.search_web` for the official source: the destination government's
   immigration or foreign-affairs site, or the embassy page for the
   traveler's nationality. Use IATA Timatic-style summaries only to find
   the official page.
2. `web.scrape` (or `parse_document` for PDFs) the official page and
   record: visa required or not, visa-free or transit-without-visa limits
   (hours or days, eligible airports, onward-ticket rules), passport
   validity, electronic authorization (eTA, ESTA, ETIAS, K-ETA and the
   like), and processing time.
3. Cite the official URL and its last-updated date when the page shows
   one. If only secondary sources were reachable, say so; entry rules are
   never estimates the user should rely on.

Flag itineraries that only work with a transit privilege (for example a
visa-free transit window) or that change airports within a city.

## Booking order

Recommend an order, and say what can wait:

1. Anything with scarce supply or the largest price risk first, usually
   long-haul flights and peak-date lodging.
2. Visas or electronic authorizations with long processing times, before
   or right after the flights, as their rules require.
3. Refundable lodging next; it can be held and rebooked if prices drop.
4. Ground transport and day-level items last, unless they sell out
   (peak-season ferries, popular trains).

## Before paying: checks to state

- Fare type: what the fare includes (checked bag, seat selection,
  changes, refunds). Basic or light fares often exclude bags.
- Separate tickets and self-transfers: a missed connection on a
  separate ticket is the traveler's loss; recommend at least 3 hours, or
  one protected ticket.
- Hidden-city fares: carry-on only, the traveler must not check bags,
  must leave at the layover, and airlines may penalize the practice.
- Free cancellation windows: many carriers allow a short free
  cancellation after booking (for example 24 hours on US-touching
  bookings made 7+ days out). Check the carrier's own policy.
- Price changes: quotes are snapshots; re-check right before paying.

Adapted from the `booking-guidance` skill of borski/travel-hacking-toolkit
(MIT).
