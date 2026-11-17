-- Market analysis from the collector (ahmarket.py). Generated, do not edit.
-- days (oldest first, UTC, copper): turnover = ESTIMATED gold turnover (own sales estimate
--   divided by the calibration factor, see ahmarket.py), turnoverCertain = LOWER BOUND (partial
--   commodity purchases only), offers/items = average per snapshot, listedValue = average
--   sum(quantity * cheapest offer), newOffers = auctions that appeared, priceIndex = fixed-basket
--   Laspeyres index (100 liquid items, first day = 100), hours = snapshots (partial days < 24)
-- summary: changes in percent over changeDays days (fewer than 7 while history is short)
local ADDON, ns = ...
ns.MarketAnalysis = {
  updated = "2026-11-17T12:19:00Z",
  days = {
    { day = "2026-11-16", hours = 15, turnover = 564065457, turnoverCertain = 95637427, offers = 289707, items = 6574, listedValue = 3711834634, newOffers = 939185, priceIndex = 100 },
    { day = "2026-11-17", hours = 13, turnover = 369518635, turnoverCertain = 91773284, offers = 245662, items = 6579, listedValue = 3351116613, newOffers = 488351, priceIndex = 103.1 },
  },
  summary = {
    days = 2, changeDays = 1, calFactor = 9.21,
    turnover7d = 933584092, turnoverCertain7d = 187410711,
    turnoverChangePct = -24.4, offersChangePct = -15.2, inflationPct = 3.1,
    topProfession = { id = 165, name = "Lederverarbeitung", score = 4408904 },
    topRecipes = {
      { id = 12617, name = "Extrem sicherer Transporter nach Gadgetzan", professionId = 202, itemId = 18986, profit = 709836, demand = 3.41 },
      { id = 55030, name = "Blauer Drachenschuppenhelm", professionId = 165, itemId = 252604, profit = 498190, demand = 2.32 },
      { id = 55074, name = "Kriegsbärenhelm", professionId = 165, itemId = 252485, profit = 386419, demand = 2.89 },
      { id = 57042, name = "Webstuhl", professionId = 197, itemId = 279959, profit = 179962, demand = 4.73 },
      { id = 10796, name = "Sturmschleierschultern", professionId = 165, itemId = 15058, profit = 465896, demand = 1.62 },
    },
    movers = { up = { { itemId = 6299, change = 2.46 }, { itemId = 2569, change = 2.003 }, { itemId = 260793, change = 1.923 }, { itemId = 4604, change = 1.818 }, { itemId = 250375, change = 1.814 } }, down = { { itemId = 18781, change = -0.941 }, { itemId = 13890, change = -0.928 }, { itemId = 7079, change = -0.875 }, { itemId = 251291, change = -0.874 }, { itemId = 264152, change = -0.865 } } },
  },
}
