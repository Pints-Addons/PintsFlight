-- Pint's Flight: while you're on a flight path, a small bar shows where you're going, how many stops are left and a
-- countdown to landing. The first time you fly a route the time is an estimate (marked ~); after landing the real time
-- is remembered, so the next flight on that route counts down exactly. Hovering a flight master's map shows stops and time.
--   /pflight            unlock / lock the bar (drag it while unlocked; middle-drag moves it any time)
--   /pflight disembark  show or hide the Disembark button
--   /pflight reset      put the bar back in its default spot
local ADDON = ...
local PF = {}
_G.PintsFlight = PF
local DEFAULTS = { times = {}, speed = nil, pos = nil, locked = true }
local db
local function Print(m) print("|cffd4a017Pint's Flight:|r " .. m) end
local SECRET = type(issecretvalue) == "function"
local function Known(v) if SECRET and issecretvalue(v) then return nil end return v end

---------------------------------------------------------------- the route from the flight master's map
local function MapID() return GetTaxiMapID and Known(GetTaxiMapID()) end
-- yards per map unit across and down, when the game says how big the map is
local function MapYards(mapID)
	if mapID and C_Map and C_Map.GetMapWorldSize then
		local w, h = C_Map.GetMapWorldSize(mapID)
		w, h = Known(w), Known(h)
		if w and w > 0 then return w, h end
	end
	return 12000, 12000      -- about a continent
end
local function NodeAt(x, y)
	local best, bd
	for i = 1, (NumTaxiNodes() or 0) do
		local nx, ny = TaxiNodePosition(i)
		if nx then
			local d = (nx - x) ^ 2 + (ny - y) ^ 2
			if not bd or d < bd then best, bd = i, d end
		end
	end
	return best
end
local function CurrentNode()
	for i = 1, (NumTaxiNodes() or 0) do if TaxiNodeGetType(i) == "CURRENT" then return i end end
end
local function Short(name) return name and (name:gsub(",.*$", "")) or "?" end
-- { from, to, hops = { {x, y, name}, ... }, yards = { per hop }, total yards, mapID }
function PF.Route(slot)
	local n = GetNumRoutes and GetNumRoutes(slot) or 0
	if not n or n < 1 then return end
	local mapID = MapID()
	local W, H = MapYards(mapID)
	local cur = CurrentNode()
	local r = { from = cur and TaxiNodeName(cur), to = TaxiNodeName(slot), hops = {}, yards = {}, total = 0, mapID = mapID }
	local sx, sy
	if cur then sx, sy = TaxiNodePosition(cur) end
	for h = 1, n do
		local x, y = TaxiGetDestX(slot, h), TaxiGetDestY(slot, h)
		if not (sx and x) then break end
		local node = NodeAt(x, y)
		local yd = math.sqrt(((x - sx) * W) ^ 2 + ((y - sy) * H) ^ 2)
		r.hops[h] = { x, y, node and TaxiNodeName(node) or "?" }
		r.yards[h] = yd
		r.total = r.total + yd
		sx, sy = x, y
	end
	return r
end
local function Key(r) return (r.from or "?") .. " > " .. (r.to or "?") end
-- seconds for a route: the time you flew it before, or an estimate from its length
function PF.Time(r)
	local t = db.times[Key(r)]
	if t then return t, false end
	return r.total / (db.speed or 30) + 3 * #r.hops, true
end
local function Clock(s)
	s = math.max(0, math.floor(s + 0.5))
	return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

---------------------------------------------------------------- the bar
local bar
local function Build()
	bar = CreateFrame("Frame", "PintsFlightBar", UIParent, "BackdropTemplate")
	bar:SetSize(300, 40)
	bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	bar:SetBackdropColor(0, 0, 0, 0.6); bar:SetBackdropBorderColor(0, 0, 0, 1)
	bar:SetMovable(true); bar:SetClampedToScreen(true); bar:EnableMouse(true); bar:RegisterForDrag("LeftButton", "MiddleButton")
	-- drag with the middle mouse button any time (locked or not); with the left button while unlocked (/pflight)
	bar:SetScript("OnDragStart", function(self, button) if button == "MiddleButton" or not db.locked then self:StartMoving() end end)
	bar:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint(); db.pos = { p, rp, x, y }
	end)
	bar.icon = bar:CreateTexture(nil, "ARTWORK"); bar.icon:SetSize(30, 30); bar.icon:SetPoint("LEFT", 5, 0)
	bar.icon:SetTexture("Interface\\Icons\\Ability_Mount_Wyvern_01"); bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	bar.to = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal"); bar.to:SetPoint("TOPLEFT", bar.icon, "TOPRIGHT", 6, -1)
	bar.to:SetPoint("RIGHT", -60, 0); bar.to:SetJustifyH("LEFT"); bar.to:SetWordWrap(false)
	bar.time = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge"); bar.time:SetPoint("TOPRIGHT", -6, -3)
	bar.stops = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); bar.stops:SetPoint("BOTTOMLEFT", bar.icon, "BOTTOMRIGHT", 6, 4)
	bar.prog = CreateFrame("StatusBar", nil, bar); bar.prog:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar.prog:SetStatusBarColor(0.83, 0.63, 0.09); bar.prog:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 40, 3); bar.prog:SetPoint("BOTTOMRIGHT", -4, 3)
	bar.prog:SetHeight(3); bar.prog:SetMinMaxValues(0, 1)
	-- Disembark: land at the next flight point instead of flying on (when the game offers it)
	bar.land = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
	bar.land:SetSize(84, 22); bar.land:SetPoint("LEFT", bar, "RIGHT", 4, 0); bar.land:SetText("Disembark")
	bar.land:SetScript("OnClick", function(self)
		if not (TaxiRequestEarlyLanding and flight and UnitOnTaxi("player")) then return end
		TaxiRequestEarlyLanding()
		flight.early = true
		self:Disable(); self:SetText("Landing...")
		local h = flight.route.hops[flight.stop]
		Print("landing at the next stop" .. (h and h[3] ~= "?" and (": " .. Short(h[3])) or "") .. ".")
	end)
	bar.land:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Disembark")
		local h = flight and flight.route.hops[flight.stop]
		GameTooltip:AddLine("End the flight at the next stop" .. (h and h[3] ~= "?" and (": " .. Short(h[3])) or "") .. ".", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	bar.land:SetScript("OnLeave", function() GameTooltip:Hide() end)
	bar.land:Hide()
	PF.Place()
	bar:Hide()
end
function PF.Place()
	if not bar then return end
	bar:ClearAllPoints()
	local p = db.pos
	if p then bar:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else bar:SetPoint("TOP", UIParent, "TOP", 0, -140) end
end

---------------------------------------------------------------- the flight
local flight      -- { route, start, total, estimate, stop }
local function PlayerXY(mapID)
	if not (mapID and C_Map and C_Map.GetPlayerMapPosition) then return end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not ok or not pos then return end
	local x, y = pos:GetXY()
	return Known(x), Known(y)
end
local function StopsLeft(f, elapsed)
	local r = f.route
	local n = #r.hops
	-- by where you are, when the game says (each stop passed within ~150 yards)
	local x, y = PlayerXY(r.mapID)
	if x and y and x > 0 then
		local W, H = MapYards(r.mapID)
		local h = r.hops[f.stop]
		while h and f.stop < n and math.sqrt(((x - h[1]) * W) ^ 2 + ((y - h[2]) * H) ^ 2) < 150 do
			f.stop = f.stop + 1; h = r.hops[f.stop]
		end
	else
		-- otherwise by how far along the trip you are
		local done, at = (elapsed / math.max(1, f.total)) * r.total, 0
		for i = 1, n do at = at + r.yards[i]; if at > done then f.stop = math.max(f.stop, i); break end end
	end
	return n - f.stop        -- stops before your destination
end
local tick = 0
local function OnUpdate(_, el)
	tick = tick + el
	if tick < 0.1 or not flight or flight.waiting then return end
	tick = 0
	if not UnitOnTaxi("player") then
		if GetTime() - flight.start > 5 then PF.Landed() end
		return
	end
	local elapsed = GetTime() - flight.start
	local left = flight.total - elapsed
	local stops = StopsLeft(flight, elapsed)
	bar.to:SetText("To " .. Short(flight.route.to))
	bar.stops:SetText(stops == 0 and "|cff40ff40Last leg|r" or (stops == 1 and "1 stop left" or (stops .. " stops left")))
	if left > 0 then bar.time:SetText((flight.estimate and "~" or "") .. Clock(left))
	else bar.time:SetText("|cffaaaaaa" .. (flight.estimate and "soon" or "0:00") .. "|r") end
	bar.prog:SetValue(math.min(1, elapsed / math.max(1, flight.total)))
	-- Disembark: only while there's a stop before your destination to land at (the game can end a flight early only
	-- on clients that have it - WoW Forever)
	bar.land:SetShown(TaxiRequestEarlyLanding ~= nil and db.disembark ~= false and (stops > 0 or flight.early) and true or false)
end
function PF.Start(slot)
	local r = PF.Route(slot)
	if not r then return end
	local t, est = PF.Time(r)
	flight = { route = r, start = GetTime(), total = t, estimate = est, stop = 1, waiting = true }
	if not bar then Build() end
	bar.to:SetText("To " .. Short(r.to)); bar.time:SetText((est and "~" or "") .. Clock(t)); bar.prog:SetValue(0)
	local stops = #r.hops - 1
	bar.stops:SetText(stops == 0 and "Direct flight" or (stops == 1 and "1 stop left" or (stops .. " stops left")))
	bar.land:Enable(); bar.land:SetText("Disembark"); bar.land:Hide()
	bar:SetScript("OnUpdate", OnUpdate)
	bar:Show()
end
function PF.Landed()
	local f = flight
	flight = nil
	if bar then bar:Hide(); bar:SetScript("OnUpdate", nil) end
	if not f or not f.flying then return end
	if f.early then return end            -- (cut short: not the route's real time)
	local took = GetTime() - f.flying
	if took < 10 then return end
	db.times[Key(f.route)] = math.floor(took + 0.5)
	-- learn how fast flights go, for routes you haven't flown yet
	if f.route.total > 0 then
		local sp = f.route.total / math.max(1, took - 3 * #f.route.hops)
		db.speed = db.speed and (db.speed * 0.7 + sp * 0.3) or sp
	end
	if f.estimate then Print(("%s to %s took %s - remembered for next time."):format(Short(f.route.from), Short(f.route.to), Clock(took))) end
end
-- the clock starts when you're actually in the air (the take-off can lag the click)
local watch = CreateFrame("Frame")
watch:SetScript("OnUpdate", function()
	if flight and flight.waiting and UnitOnTaxi("player") then
		flight.waiting = nil; flight.flying = GetTime(); flight.start = GetTime()
	elseif flight and flight.waiting and GetTime() - flight.start > 10 then
		flight = nil; if bar then bar:Hide() end          -- didn't take off
	end
end)

---------------------------------------------------------------- flight master's map: stops and time on hover
local function TipFor(slot)
	local r = PF.Route(slot)
	if not r or #r.hops == 0 then return end
	local t, est = PF.Time(r)
	local stops = #r.hops - 1
	GameTooltip:AddLine((stops == 0 and "Direct" or (stops == 1 and "1 stop" or (stops .. " stops"))) .. " - " .. (est and "about " or "") .. Clock(t), 0.83, 0.63, 0.09)
	GameTooltip:Show()
end
local function HookMap()
	if PF.hooked then return end
	if TaxiNodeOnButtonEnter then
		PF.hooked = true
		hooksecurefunc("TaxiNodeOnButtonEnter", function(button) if button and button.GetID then pcall(TipFor, button:GetID()) end end)
	end
end

---------------------------------------------------------------- events
hooksecurefunc("TakeTaxiNode", function(slot) pcall(PF.Start, slot) end)
local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "TAXIMAP_OPENED", "PLAYER_CONTROL_GAINED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, e, a1)
	if e == "ADDON_LOADED" and a1 == ADDON then
		PintsFlightDB = PintsFlightDB or {}
		db = PintsFlightDB
		for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = (type(v) == "table") and {} or v end end
		PF.db = db
	elseif e == "TAXIMAP_OPENED" or e == "PLAYER_LOGIN" then HookMap()
	elseif e == "PLAYER_CONTROL_GAINED" then
		if flight and flight.flying and not UnitOnTaxi("player") then PF.Landed() end
	end
end)

SLASH_PINTSFLIGHT1 = "/pflight"
SlashCmdList.PINTSFLIGHT = function(msg)
	msg = (msg or ""):lower()
	if not bar then Build() end
	if msg == "reset" then db.pos = nil; PF.Place(); Print("bar back in its spot."); return end
	if msg == "disembark" then
		db.disembark = (db.disembark == false) and true or false
		Print("Disembark button " .. (db.disembark and "on." or "off.")); return
	end
	db.locked = not db.locked
	if db.locked then
		if not flight then bar:Hide() end
		Print("bar locked.")
	else
		bar.to:SetText("Pint's Flight - drag me"); bar.stops:SetText("2 stops left"); bar.time:SetText("1:23"); bar.prog:SetValue(0.4)
		bar:Show(); Print("bar unlocked - drag it where you like, then /pflight again to lock it.")
	end
end
