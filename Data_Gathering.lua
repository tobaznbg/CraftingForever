-- Gathering data: what each gathering source yields and what it takes to get it.
-- Requirements are the classic game rules:
--   skinning  a mob of level L needs skill L*5 (L >= 20), (L-10)*10 below; the
--             level range is where the item mostly comes from (classic loot tables)
--   mining / herbalism  skill needed to gather the node or herb
--   cloth     humanoids in the given level range, no profession needed
local ADDON, ns = ...

ns.Gathering = {
  -- source = German profession name as shown in the game ("" = no profession)
  { source = "Kürschnerei", label = "Kürschnerei", kind = "mob", items = {
    { 2318, 5, 20 }, { 783, 5, 20 },        -- light leather / hide
    { 2319, 15, 30 }, { 4232, 15, 30 },     -- medium
    { 4234, 25, 40 }, { 4235, 25, 40 },     -- heavy
    { 4304, 35, 50 }, { 8169, 35, 50 },     -- thick
    { 8170, 45, 60 }, { 8171, 45, 60 },     -- rugged
    { 4461, 30, 40 },                       -- raptor hide (raptors)
    { 7392, 30, 40 },                       -- green whelp scale (whelps)
    { 8167, 35, 45 },                       -- turtle scale (turtles)
    { 8154, 40, 50 },                       -- scorpid scale
    { 8165, 40, 50 },                       -- worn dragonscale (dragonkin)
    { 15408, 50, 60 },                      -- heavy scorpid scale
    { 15417, 50, 60 },                      -- devilsaur leather
    { 15419, 50, 60 },                      -- warbear leather
    { 15422, 55, 60 },                      -- frostsaber leather
    { 15423, 50, 60 },                      -- chimera leather
  } },
  { source = "Bergbau", label = "Bergbau", kind = "skill", items = {
    { 2770, 1 }, { 2835, 1 }, { 774, 1 }, { 818, 1 },              -- copper, rough stone, gems
    { 2771, 65 }, { 2836, 65 }, { 1210, 65 }, { 1705, 65 },        -- tin
    { 2775, 75 },                                                  -- silver
    { 2772, 125 }, { 2838, 125 }, { 1529, 125 }, { 3864, 125 },    -- iron
    { 2776, 155 }, { 7909, 155 },                                  -- gold
    { 3858, 175 }, { 7912, 175 }, { 7910, 175 },                   -- mithril
    { 7911, 230 }, { 11370, 230 },                                 -- truesilver, dark iron
    { 10620, 245 }, { 12365, 245 }, { 12361, 245 }, { 12364, 245 },
    { 12799, 245 }, { 12800, 245 }, { 12363, 245 },                -- thorium and its gems
  } },
  { source = "Kräuterkunde", label = "Kräuterkunde", kind = "skill", items = {
    { 2447, 1 }, { 765, 1 }, { 2449, 15 }, { 785, 50 }, { 2450, 70 }, { 3820, 85 },
    { 2453, 100 }, { 3355, 115 }, { 3369, 120 }, { 3356, 125 }, { 3357, 150 },
    { 3818, 160 }, { 3821, 170 }, { 3358, 185 }, { 3819, 195 }, { 4625, 205 },
    { 8831, 210 }, { 8836, 220 }, { 8838, 230 }, { 8839, 235 }, { 8845, 245 },
    { 8846, 250 }, { 13464, 260 }, { 13463, 270 }, { 13465, 280 }, { 13466, 285 },
    { 13467, 290 }, { 13468, 300 },
  } },
  -- fishing: what the line brings (skill per fishing water, not per fish: no requirement here);
  -- the second value groups them (1 fish, 2 schools / other)
  { source = "Angeln", label = "Angeln", kind = "fish", items = {
    { 6291, 1 }, { 6303, 1 }, { 6289, 1 }, { 6317, 1 }, { 6361, 1 }, { 6308, 1 }, { 21071, 1 },
    { 6362, 1 }, { 8365, 1 }, { 4603, 1 }, { 13754, 1 }, { 13755, 1 }, { 13756, 1 }, { 13757, 1 },
    { 13758, 1 }, { 13759, 1 }, { 13760, 1 }, { 13888, 1 }, { 13889, 1 }, { 13893, 1 }, { 21153, 1 },
    { 6358, 2 }, { 6359, 2 }, { 6522, 2 }, { 13422, 2 }, { 7070, 2 },
  } },
  { source = "", label = "Stoff (Humanoide)", kind = "mob", items = {
    { 2589, 5, 20 }, { 2592, 15, 30 }, { 4306, 25, 40 }, { 4338, 35, 50 },
    { 14047, 45, 60 }, { 14256, 50, 60 },   -- felcloth: demons
  } },
}
