-- Market analysis from the collector (ahmarket.py). Generated, do not edit.
-- days (oldest first, UTC, copper): turnover = ESTIMATED gold turnover (own sales estimate
--   divided by the calibration factor, see ahmarket.py), turnoverCertain = LOWER BOUND (partial
--   commodity purchases only), offers/items = average per snapshot, listedValue = average
--   sum(quantity * cheapest offer), newOffers = auctions that appeared, priceIndex = fixed-basket
--   Laspeyres index (100 liquid items, first day = 100), hours = snapshots (partial days < 24)
-- summary: changes in percent over changeDays days (fewer than 7 while history is short)
local ADDON, ns = ...
ns.MarketAnalysis = {
  updated = "2026-11-17T13:19:01Z",
  days = {
    { day = "2026-11-16", hours = 15, turnover = 565921137, turnoverCertain = 95637427, offers = 289707, items = 6574, listedValue = 3711834634, newOffers = 939185, priceIndex = 100 },
    { day = "2026-11-17", hours = 14, turnover = 405734239, turnoverCertain = 99241216, offers = 245983, items = 6583, listedValue = 3367459517, newOffers = 546369, priceIndex = 103.02 },
  },
  summary = {
    days = 2, changeDays = 1, calFactor = 9.18,
    turnover7d = 971655376, turnoverCertain7d = 194878643,
    turnoverChangePct = -23.2, offersChangePct = -15.1, inflationPct = 3.02,
    topProfession = { id = 202, name = "Ingenieurskunst", score = 3428008 },
    topRecipes = {
      { id = 12617, name = "Extrem sicherer Transporter nach Gadgetzan", professionId = 202, itemId = 18986, profit = 710477, demand = 3.4 },
      { id = 55074, name = "Kriegsbärenhelm", professionId = 165, itemId = 252485, profit = 305931, demand = 3.08 },
      { id = 10796, name = "Sturmschleierschultern", professionId = 165, itemId = 15058, profit = 476766, demand = 1.62 },
      { id = 55030, name = "Blauer Drachenschuppenhelm", professionId = 165, itemId = 252604, profit = 260754, demand = 2.34 },
      { id = 10768, name = "Lebendige Schultern", professionId = 165, itemId = 15061, profit = 300554, demand = 1.49 },
    },
    movers = { up = { { itemId = 279537, change = 2.049 }, { itemId = 260793, change = 1.935 }, { itemId = 21177, change = 1.797 }, { itemId = 264107, change = 1.76 }, { itemId = 4865, change = 1.754 } }, down = { { itemId = 10601, change = -0.346 }, { itemId = 12697, change = -0.345 }, { itemId = 6299, change = -0.325 }, { itemId = 253976, change = -0.318 }, { itemId = 2679, change = -0.312 } } },
  },
}
