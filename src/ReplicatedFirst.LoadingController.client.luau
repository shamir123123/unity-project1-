--!strict

local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local StarterGui        = game:GetService("StarterGui")

local LoadingView = require(script:WaitForChild("LoadingView"))

ReplicatedFirst:RemoveDefaultLoadingScreen()

local MAIN_MENU_NAME = "MainMenu"
local LOADING_SCREEN_NAME = "LoadingScreen"
local STAFF_PANEL_NAME = "StaffPanel" -- unified tester/admin/developer overlay
-- MainMenuController's city-load screen. In the city place it goes up while this one is still
-- running (the teleport data names the city), and hiding it left that load with no screen.
local CITY_LOADING_SCREEN_NAME = "GameLoadingScreen"
-- Above the main menu (Theme.Layer.Screen, 250), which is built and enabled underneath this
-- screen, and the city-load screen (Theme.Layer.Fade, 950). At the template's 100 the menu
-- drew OVER the join screen: it could be clicked mid-gate, and the handover below then switched off
-- whatever screen the player had opened (LOAD CITY), leaving them on the bare key art.
local JOIN_SCREEN_DISPLAY_ORDER = 960

-- Is the main menu this place's screen at all? In the CITY place it is not: the player was
-- sent there to be IN a city, and MainMenuController has already decided which one before
-- this screen comes down. Handing over by force-enabling the menu is what put a main menu
-- on top of a running city -- the fix at the other end could not hold, because this ran
-- after it. Waited for rather than required at the top: ReplicatedFirst runs before
-- ReplicatedStorage has finished replicating.
local function menuBelongsHere(): boolean
	local ok, elsewhere = pcall(function()
		local access = ReplicatedStorage:WaitForChild("Access", 10)
		return require(access:WaitForChild("PlacesConfig", 10)).menuIsElsewhere()
	end)
	if not ok then
		-- Unreadable: behave as the lobby, which is the only place that can recover.
		warn("[LoadingController] PlacesConfig unreadable, assuming the menu belongs here: " .. tostring(elsewhere))
		return true
	end
	return not elsewhere
end

-- THE JOIN GATE. The screen stays up until this player's data is actually here:
--   1. the place itself (game:IsLoaded)
--   2. the server side of their data -- profile record + city slot index -- reported by
--      PlayerLoadService through the DataLoad* attributes on the Player
--   3. the client side -- saved settings applied, first slot index fetched -- latched by
--      the steps in ReplicatedStorage.Shared.ClientBootGate
-- Before this, the menu opened on a timer: Continue could be empty for a player who has
-- three cities, and the language / UI scale snapped a second after it appeared.
--
-- The gate runs BEHIND LoadingView's loader, which fills its street grid from the gate's own
-- progress. The logo only builds once the gate is through, so the menu it hands over to is
-- complete.
--
-- DATA_TIMEOUT is the never-stuck backstop. Every wait below is bounded by it: a service
-- that fails to answer drops the player into the menu on defaults (which is what they got
-- before this gate existed), it never leaves them staring at a logo. GATE_BACKSTOP bounds
-- the loader hold on top of that, for the unbounded game.Loaded wait.
--
-- No SKIP here: skipping into a menu with half its data is worse than the wait. Only the
-- city load (MainMenuController) offers one.
local DATA_TIMEOUT     = 45
local GATE_BACKSTOP    = DATA_TIMEOUT + 15
local CLIENT_STEPS     = { "settings", "menu" }
local POLL_INTERVAL    = 0.1

local player    = Players.LocalPlayer :: Player
local playerGui = player:WaitForChild("PlayerGui")

-- The lobby's "JOINING CITY" screen rode the teleport (SetTeleportGui). Keep it up so there
-- is no gap between the teleport and the city-load screen, which replaces it BY NAME
-- (MainMenuController.createGameLoadingScreen destroys any existing GameLoadingScreen).
-- Backstop for an arrival that never starts a load: it must not cover the game forever.
local arrivingGui = game:GetService("TeleportService"):GetArrivingTeleportGui()
if arrivingGui then
    arrivingGui.Parent = playerGui
    task.delay(120, function()
        if arrivingGui.Parent then arrivingGui:Destroy() end
    end)
end

local menuIsOpen = true

local function setCoreGuiEnabled(enabled: boolean)
    for _ = 1, 5 do
        local ok = pcall(function()
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, enabled)
        end)
        if ok then
            return
        end
        task.wait()
    end
end

local function shouldKeepEnabled(guiName: string): boolean
    if guiName == LOADING_SCREEN_NAME or guiName == STAFF_PANEL_NAME or guiName == CITY_LOADING_SCREEN_NAME then
        return true
    end

    return menuIsOpen and guiName == MAIN_MENU_NAME
end

-- Tag every gui we switch off, so the menu can switch back on exactly the ones we took
-- and nothing else. The menu used to restore from a hardcoded name list that had drifted
-- out of sync with the guis the controllers actually create, which left tooltips, modals,
-- hover cards and the radio bar dark for the whole session on any client that happened to
-- build them while this screen was still up.
--
-- Panels that mean to start closed (SettingsUI, EditorUI, PlacementCostHud) set
-- Enabled = false BEFORE parenting, so they reach us already disabled and are never
-- tagged -- handing over must not force them open.
local HIDDEN_BY_LOADER_ATTR = "HiddenByLoadingScreen"

local function hideGui(child: ScreenGui)
    if child.Enabled then
        child:SetAttribute(HIDDEN_BY_LOADER_ATTR, true)
        child.Enabled = false
    end
end

local function hideOtherScreenGuis()
    for _, child in ipairs(playerGui:GetChildren()) do
        if child:IsA("ScreenGui") and not shouldKeepEnabled(child.Name) then
            hideGui(child)
        end
    end
end

local childAddedConnection = playerGui.ChildAdded:Connect(function(child)
    if child:IsA("ScreenGui") and not shouldKeepEnabled(child.Name) then
        hideGui(child)
    end
end)

setCoreGuiEnabled(false)
hideOtherScreenGuis()

-- The join screen belongs to the LOBBY. In the city place the player has already sat
-- through it once, and MainMenuController's city-load screen is the one that means
-- something here -- playing the cards and logo in front of it was a second, fake load.
-- Other guis stay tagged-hidden; the city load hands them back on entry.
if not menuBelongsHere() then
    childAddedConnection:Disconnect()
    return
end

-- Clone the template card and draw the join screen on its Background. The template itself
-- stays the plain logo card that MainMenuController clones for its city-load transition.
local template  = ReplicatedFirst:WaitForChild(LOADING_SCREEN_NAME)
local screenGui = template:Clone()
screenGui.Name = LOADING_SCREEN_NAME
screenGui.DisplayOrder = JOIN_SCREEN_DISPLAY_ORDER
screenGui.Enabled = true
screenGui.Parent  = playerGui

local bg   = screenGui:WaitForChild("Background") :: GuiObject
local view = LoadingView.new(bg)

local function runJoinGate()
    local deadline = os.clock() + DATA_TIMEOUT

    -- 1. The place itself: assets and the initial replication.
    view.setStatus("Loading game")
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    view.setProgress(0.25)

    -- 2. The player's data, server side. PlayerLoadService moves these attributes along as
    -- each DataStore read lands and flips DataLoaded once every one of them has.
    while player:GetAttribute("DataLoaded") ~= true do
        if os.clock() >= deadline then
            warn("[LoadingController] player data did not arrive in time -- entering on defaults")
            break
        end

        local step = player:GetAttribute("DataLoadStep")
        view.setStatus(if typeof(step) == "string" then string.upper(step) else "LOADING YOUR DATA")

        local serverAlpha = tonumber(player:GetAttribute("DataLoadProgress")) or 0
        view.setProgress(0.25 + 0.45 * math.clamp(serverAlpha, 0, 1))

        task.wait(POLL_INTERVAL)
    end
    view.setProgress(0.7)

    -- 3. The client half: the loaded profile APPLIED (settings) and the menu holding the
    -- player's real slot list. Waited on through a latched gate, not an event, because these
    -- steps can complete before this script ever gets to look at them.
    view.setStatus("APPLYING YOUR SETTINGS")
    local sharedFolder = ReplicatedStorage:WaitForChild("Shared", math.max(1, deadline - os.clock()))
    local gateModule = if sharedFolder then sharedFolder:WaitForChild("ClientBootGate", math.max(1, deadline - os.clock())) else nil

    if gateModule and gateModule:IsA("ModuleScript") then
        local BootGate = require(gateModule) :: any
        local missing = BootGate.await(CLIENT_STEPS, math.max(0, deadline - os.clock()))
        if missing then
            warn("[LoadingController] boot step '" .. missing .. "' never completed -- entering anyway")
        end
    else
        warn("[LoadingController] ClientBootGate is missing -- skipping the client-side wait")
    end

    view.setProgress(1)
    view.setStatus(if player:GetAttribute("DataLoadTimedOut") == true then "SOME DATA IS UNAVAILABLE" else "READY")
end

-- The gate runs alongside the loader; gateDone is the only thing the two threads share. The
-- logo plays the moment it is through -- no cards, no minimum: the screen is exactly as long
-- as the load.
local gateDone = false
task.spawn(function()
    local ok, err = pcall(runJoinGate)
    if not ok then
        warn("[LoadingController] join gate failed -- entering anyway: " .. tostring(err))
    end
    gateDone = true
end)

view.showProgress()
if not view.holdUntil(function() return gateDone end, GATE_BACKSTOP) then
    warn("[LoadingController] join gate never finished -- entering anyway")
end
view.playLogo()

-- Hand over UNDER the card, then fade it, so the menu is already there when the logo clears.
-- In the city place the menu is not what comes next: hand the screen over exactly as
-- MainMenuController left it and take nothing else down on the way out.
local mainMenu = playerGui:WaitForChild(MAIN_MENU_NAME, 10)
menuIsOpen = menuBelongsHere()
setCoreGuiEnabled(false)

if menuIsOpen then
    hideOtherScreenGuis()
    if mainMenu and mainMenu:IsA("ScreenGui") then
        mainMenu.Enabled = true
    else
        warn("MainMenu ScreenGui was not found after loading completed.")
    end
end

childAddedConnection:Disconnect()

view.fadeOut()
view.destroy()
screenGui:Destroy()
