--!strict
-- CityTeleport
-- Sends a player from the LOBBY into a city: a reserved server of the CITY place, one
-- per owner. Nobody is routed on join any more -- the lobby is a destination, not a
-- transit lounge, and players sit there until they actually pick a city. The hop is
-- triggered by the slot pick (CitySlotService.onRequestLoadSlot).
--
-- Friends reach you two ways: from the lobby, by entering YOUR ownerId here, or from
-- Roblox's join-friend, which drops them straight into your reserved server. Either
-- way PlaceAccessService decides on arrival whether they may stay.
--
-- Studio has no reserved servers and cannot teleport, so it never calls this: it loads
-- the city in place and F5 runs the whole menu -> city -> menu loop locally.

local DataStoreService = game:GetService("DataStoreService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlacesConfig = require(ReplicatedStorage.Access.PlacesConfig)

local CityTeleport = {}

local _bound = false

local function accessStore(): DataStore
	return DataStoreService:GetDataStore(PlacesConfig.AccessStore)
end

-- An access code is only valid for the place it was reserved against; reusing one
-- across places fails the teleport with a bare "unexpected error", and since the cache
-- keeps serving it, that lockout is permanent. So the placeId is stored alongside and
-- checked here. A legacy bare-string entry predates the pairing and cannot be verified,
-- so it is discarded and re-reserved -- which is also how this migrates itself.
--
-- That check is what carries the two-place split across for free: every code cached
-- against the OLD single place fails the match and is re-reserved against the city
-- place on first use. Nothing to migrate by hand.
-- Pure so the spec can cover every shape the store might hand back.
function CityTeleport._cachedCode(cached: any, placeId: number): string?
	if typeof(cached) ~= "table" then return nil end
	if cached.placeId ~= placeId then return nil end
	if typeof(cached.code) ~= "string" or cached.code == "" then return nil end
	return cached.code
end

-- Drop this owner's cached city server so the next attempt reserves a fresh one.
-- A reserved server can die in ways the cache cannot see -- shut down, expired, or
-- minted against a place we no longer teleport to -- and every one of them is
-- permanent without this: the cache keeps handing back the same dead code forever.
local function forgetReserved(ownerId: number)
	pcall(function() accessStore():RemoveAsync(PlacesConfig.serverKey(ownerId)) end)
end

-- Reserve (or reuse) this owner's city server. Returns the access code, or nil.
-- ponytail: no cross-server lock, so two lobby servers reserving the same owner at the
-- exact same moment can create two instances (last write wins the cache). Rare and
-- self-healing on the next join; add a MemoryStore lock if it ever matters.
local function ensureReserved(ownerId: number): string?
	local cityPlaceId = PlacesConfig.CITY_PLACE_ID
	if cityPlaceId == 0 then
		warn("[CityTeleport] CITY_PLACE_ID is unset -- the two-place split is not wired yet")
		return nil
	end

	local key = PlacesConfig.serverKey(ownerId)
	local ok, cached = pcall(function()
		return accessStore():GetAsync(key)
	end)
	if ok then
		-- Re-assert the owner record on every reuse: an earlier owner write may have failed,
		-- leaving a cached server that refuses its own owner. No psid = pre-fix entry; re-reserve.
		local code = CityTeleport._cachedCode(cached, cityPlaceId)
		if code and typeof(cached.psid) == "string" then
			local wok = pcall(function() accessStore():SetAsync(PlacesConfig.ownerKey(cached.psid), ownerId) end)
			if wok then return code end
		end
	end

	local rok, accessCode, privateServerId = pcall(function()
		return TeleportService:ReserveServer(cityPlaceId)
	end)
	if not rok or typeof(accessCode) ~= "string" then
		warn("[CityTeleport] ReserveServer failed for owner", ownerId, accessCode)
		return nil
	end

	-- Record the owner BEFORE anyone teleports in -- the city gate reads this.
	-- Must land, or the server is cached with no owner and the owner is refused from it forever.
	local written = false
	for attempt = 1, 4 do
		local wok, err = pcall(function() accessStore():SetAsync(PlacesConfig.ownerKey(privateServerId), ownerId) end)
		if wok then written = true break end
		warn("[CityTeleport] owner write attempt", attempt, "failed for owner", ownerId, err)
		if attempt < 4 then task.wait(attempt) end
	end
	if not written then return nil end
	pcall(function() accessStore():SetAsync(key, { code = accessCode, placeId = cityPlaceId, psid = privateServerId }) end)
	return accessCode
end

local function teleportReserved(player: Player, code: string, data: { [string]: any }): boolean
	local opts = Instance.new("TeleportOptions")
	opts.ReservedServerAccessCode = code
	opts:SetTeleportData(data)

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(PlacesConfig.CITY_PLACE_ID, { player }, opts)
	end)
	if not ok then
		warn("[CityTeleport] TeleportAsync failed for", player.Name, err)
	end
	return ok
end

-- slotId rides along as teleport data so the arriving client can ask for that city
-- straight away. It is CLIENT-READABLE and client-spoofable on the far side, which is
-- fine: the load handler validates the slot against that player's own session index,
-- so the worst a forged value opens is one of their own cities. Ownership is never
-- read from here -- the gate resolves it from the access store by PrivateServerId.
-- `staffMode` is "visitor" when a staff member chose to arrive able to look but not build.
-- It rides the same client-readable teleport data, which is safe for the same reason the
-- slot id is: the city server confirms staff against the ROSTER, and this value can only
-- ever take rights away from someone already confirmed. It grants nothing to anyone.
function CityTeleport.enterCity(player: Player, ownerId: number, slotId: number?, staffMode: string?): boolean
	if typeof(ownerId) ~= "number" or ownerId <= 0 then return false end

	local code = ensureReserved(ownerId)
	if not code then return false end
	return teleportReserved(player, code, { ownerId = ownerId, slotId = slotId, staffMode = staffMode })
end

-- An admin save copy needs a server with no city in it. A fresh reservation with NO owner
-- record is exactly that: the access gate fails closed to staff only, and a copy never
-- saves (CitySlotService), so nobody's city can be written from it. The arriving client
-- asks for the copy itself -- see the adminCopy boot in MainMenuController.
function CityTeleport.enterAdminCopy(player: Player, sourceUserId: number, slotId: number): boolean
	if PlacesConfig.CITY_PLACE_ID == 0 then return false end
	local ok, code = pcall(function()
		return TeleportService:ReserveServer(PlacesConfig.CITY_PLACE_ID)
	end)
	if not ok or typeof(code) ~= "string" then
		warn("[CityTeleport] ReserveServer failed for admin copy,", player.Name, code)
		return false
	end
	return teleportReserved(player, code, { adminCopy = { userId = sourceUserId, slotId = slotId } })
end

-- Send a player back to the menu. The lobby is an ordinary public place, so this is a
-- plain teleport with no reservation -- matchmaking picks whichever lobby has room.
function CityTeleport.returnToLobby(player: Player): boolean
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(PlacesConfig.LOBBY_PLACE_ID, { player })
	end)
	if not ok then
		warn("[CityTeleport] return to lobby failed for", player.Name, err)
	end
	return ok
end

function CityTeleport.Bind()
	if _bound then return end
	_bound = true

	-- A dead reserved server is invisible to the cache, so the retry has to clear it or
	-- the player is locked out for good. One extra ReserveServer is the worst case.
	TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		warn("[CityTeleport] teleport failed for", player.Name, result, message)
		forgetReserved(player.UserId)
	end)
end

return CityTeleport
