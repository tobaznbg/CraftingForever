-- Style: flat, dark look for all CraftingForever windows (no Blizzard templates).
-- Solid panels with a one-pixel border, flat buttons and tabs, a thin scrollbar
-- and a single font family.
local ADDON, ns = ...

local Style = {}
ns.Style = Style

-- Colors as { r, g, b, a } in 0..1.
Style.C = {
  bg       = { 0.07, 0.07, 0.08, 0.96 },
  header   = { 0.11, 0.11, 0.12, 1 },
  border   = { 0.20, 0.20, 0.22, 1 },
  row      = { 1, 1, 1, 0.025 },  -- every second row
  hover    = { 0.31, 0.76, 0.63, 0.12 },
  accent   = { 0.31, 0.76, 0.63, 1 },  -- teal
  button   = { 0.16, 0.16, 0.18, 1 },
  buttonHi = { 0.22, 0.22, 0.25, 1 },
  text     = { 0.92, 0.92, 0.92, 1 },
  muted    = { 0.60, 0.60, 0.62, 1 },
}
-- Same colors as chat escape codes for text.
Style.ACCENT = "|cff4fc2a1"
Style.MUTED = "|cff99999e"
Style.HEAD = "|cffd8c9a3"

local FONT = "Fonts\\ARIALN.TTF"
local fonts = {}

-- Font object of the given size (cached).
function Style.Font(size, flags)
  local key = size .. (flags or "")
  if not fonts[key] then
    local font = CreateFont("CraftingForeverFont" .. key:gsub("%W", ""))
    font:SetFont(FONT, size, flags or "")
    font:SetTextColor(unpack(Style.C.text))
    fonts[key] = font
  end
  return fonts[key]
end

function Style.Text(parent, size, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  fs:SetFontObject(Style.Font(size or 12))
  fs:SetWordWrap(false)
  return fs
end

local function solid(parent, color, layer, sublevel)
  local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel or 0)
  t:SetColorTexture(unpack(color))
  return t
end
Style.Solid = solid

-- One-pixel border around a frame.
function Style.Border(frame, color)
  color = color or Style.C.border
  local edges = {
    { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
    { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
  }
  for _, e in ipairs(edges) do
    local t = solid(frame, color, "BORDER")
    t:SetPoint(e[1])
    t:SetPoint(e[2])
    if e[3] then t:SetWidth(e[3]) else t:SetHeight(e[4]) end
  end
end

-- Dark panel with border; optional header strip of the given height.
function Style.Panel(frame, headerHeight)
  local bg = solid(frame, Style.C.bg)
  bg:SetAllPoints()
  Style.Border(frame)
  if headerHeight then
    local head = solid(frame, Style.C.header, "BACKGROUND", 1)
    head:SetPoint("TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", -1, -1)
    head:SetHeight(headerHeight)
    local line = solid(frame, Style.C.border, "BORDER")
    line:SetPoint("TOPLEFT", head, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT")
    line:SetHeight(1)
  end
end

-- Flat button. color: optional { r, g, b } for the text (e.g. accent).
function Style.Button(parent, label, width, height, onClick, textColor)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, height or 22)
  b.bg = solid(b, Style.C.button)
  b.bg:SetAllPoints()
  Style.Border(b)
  b.label = Style.Text(b, 12)
  b.label:SetPoint("CENTER")
  b.label:SetText(label)
  if textColor then b.label:SetTextColor(unpack(textColor)) end
  b:SetScript("OnEnter", function(self) self.bg:SetColorTexture(unpack(Style.C.buttonHi)) end)
  b:SetScript("OnLeave", function(self)
    self.bg:SetColorTexture(unpack(self.active and Style.C.buttonHi or Style.C.button))
  end)
  b:SetScript("OnMouseDown", function(self) self.label:SetPoint("CENTER", 0, -1) end)
  b:SetScript("OnMouseUp", function(self) self.label:SetPoint("CENTER", 0, 0) end)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

-- Tab: flat text with an accent line under the active one.
function Style.Tab(parent, label, width, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 26)
  b.label = Style.Text(b, 13)
  b.label:SetPoint("CENTER", 0, 1)
  b.label:SetText(label)
  b.line = solid(b, Style.C.accent, "ARTWORK")
  b.line:SetPoint("BOTTOMLEFT", 6, 0)
  b.line:SetPoint("BOTTOMRIGHT", -6, 0)
  b.line:SetHeight(2)
  function b:SetActive(active)
    self.active = active
    self.line:SetShown(active)
    self.label:SetTextColor(unpack(active and Style.C.text or Style.C.muted))
  end
  b:SetScript("OnEnter", function(self) if not self.active then self.label:SetTextColor(unpack(Style.C.text)) end end)
  b:SetScript("OnLeave", function(self) if not self.active then self.label:SetTextColor(unpack(Style.C.muted)) end end)
  b:SetScript("OnClick", onClick)
  b:SetActive(false)
  return b
end

-- Close button: a plain "×".
function Style.Close(parent, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(24, 24)
  b.label = Style.Text(b, 18)
  b.label:SetPoint("CENTER")
  b.label:SetText("×")
  b.label:SetTextColor(unpack(Style.C.muted))
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(Style.C.text)) end)
  b:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(Style.C.muted)) end)
  b:SetScript("OnClick", onClick or function() parent:Hide() end)
  return b
end

-- Scroll area with mouse wheel and a thin scrollbar. Returns scrollFrame, content.
function Style.Scroll(parent)
  local scroll = CreateFrame("ScrollFrame", nil, parent)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  local track = solid(parent, { 1, 1, 1, 0.04 }, "ARTWORK")
  track:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 3, 0)
  track:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 3, 0)
  track:SetWidth(4)
  local thumb = solid(parent, Style.C.accent, "OVERLAY")
  thumb:SetWidth(4)
  local function update()
    local range = scroll:GetVerticalScrollRange() or 0
    local height = scroll:GetHeight() or 0
    if range <= 0 or height <= 0 then thumb:Hide() return end
    thumb:Show()
    local size = math.max(20, height * height / (height + range))
    local offset = (height - size) * scroll:GetVerticalScroll() / range
    thumb:SetHeight(size)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", track, "TOP", 0, -offset)
  end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local value = self:GetVerticalScroll() - delta * 45
    value = math.max(0, math.min(value, self:GetVerticalScrollRange()))
    self:SetVerticalScroll(value)
    update()
  end)
  scroll:SetScript("OnScrollRangeChanged", update)
  scroll:SetScript("OnSizeChanged", update)
  scroll.UpdateBar = update
  return scroll, content
end
