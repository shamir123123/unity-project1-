--!strict
-- ACUnitCatalog -- the exterior HVAC kit that hangs on the side of a city building:
-- condensers, wall packs, chillers, louvre banks. Pure data. One Model per key lives beside
-- this module, authored by ServerStorage.Authoring.ACUnitBuilder.
--
-- WHERE THE NUMBERS COME FROM -- READ THIS BEFORE TRUSTING ONE
-- Unlike ReplicatedStorage.Props.PropCatalog's first five entries, NONE of the envelopes
-- below are transcribed from a manufacturer datasheet. They are modelled from general
-- knowledge of each product class and are good to roughly the nearest 50-100 mm -- enough to
-- read correctly in a city and to keep the classes in proportion to each other, not enough to
-- cite. Re-measure against a real spec sheet before treating any figure here as authoritative.
--
-- WHY THESE ARE PART-BUILT AND NOT IMPORTED MESHES
-- Same reason the street props are (see ReplicatedStorage.Props.PropCatalog): ModelBaker
-- .bakeMesh opens with `if bake.meshBacked and not bake.foliage then return nil end`, and
-- collect() calls a model mesh-backed once MeshParts hold over half its volume. An AC unit
-- imported as a mesh would get NO FAR mesh and NO DISTANT coarse mesh -- LODProxyCache would
-- fall through to bakeImpostor and AssetLODView would flip it to a flat camera-facing quad at
-- 1000 studs. Built from Parts, ModelBaker bakes the mesh itself and every instance of one
-- kind collapses to ONE draw call. Part-built IS how these become meshes.
--
-- That matters more here than it does for bins. AC kit is the most repeated prop class in the
-- city -- one mini-split per apartment window, one VRF bank per office setback -- so the rung
-- that collapses them all to a single draw call is the one carrying the frame budget.
--
-- MOUNTING -- the pivot rule differs by `mount`, and placement depends on it
--   "wall"   the pivot sits where the wall plane meets the GROUND: local x = 0, y = 0, z = 0,
--            with every part at z <= 0 so the unit hangs out of the wall toward -Z. The
--            template already knows its own correct height above ground (`mountMm`), so a
--            placer does PivotTo(CFrame.lookAlong(wallBasePoint, outwardNormal)) and nothing
--            else -- the same "template knows its own offset" contract PropCatalog has with
--            the ground plane.
--   "ground" the pivot sits on the ground plane, centred on X/Z, exactly like PropCatalog --
--            PivotTo(groundY) lands it flush.
--
-- AUTHORING RULES THESE TEMPLATES FOLLOW -- keep them if you add a unit
--   * 1 m = 2 studs (RoadConstants.WORLD_SCALE 0.5 => STUD_TO_METER 0.5). Geometry is
--     authored in MILLIMETRES and converted once, so it can be checked against a datasheet.
--   * A part whose LONGEST side is under 0.6 studs (300 mm) is dropped from the bake by
--     ModelBaker.MIN_FEATURE_STUDS. Fine for valve covers and badges; fatal for anything
--     carrying the silhouette. Run a grille guard's DIAMETER past the gate, not its rim.
--   * Do NOT parent a placed unit under a folder named Yard, Lot or ParkMarkers --
--     ModelBaker.SKIP_GROUPS treats those as per-instance lot dressing and excludes them from
--     the bake entirely, which silently costs the unit every mesh rung.
--   * Keep the part count lean. The ladder does not collapse a model to one draw call until
--     FAR (500 studs), and a city camera commonly sits at 100-300.

export type Entry = {
	key: string,
	name: string,
	class: "Residential" | "Commercial" | "Industrial" | "Office",
	kind: "Condenser" | "Window" | "ThroughWall" | "WallPack" | "Chiller" | "Fan" | "Louvre" | "Tower",
	mount: "wall" | "ground",
	-- Height of the BOTTOM of the casing above ground, mm. Zero for ground-standing units.
	mountMm: number,
	-- How far the casing projects from the wall face, mm. Zero for ground-standing units.
	standoffMm: number,
	radius: number, -- placement footprint, studs
	tint: Color3,   -- swatch shown in a picker
	-- Real-world envelope of the CASING in mm (H, W, D) -- the product a datasheet describes,
	-- NOT the whole assembly. Brackets, line trunking and pipe stubs deliberately push the
	-- model's extents past this, so the spec measures the named casing part instead.
	mm: { number },
	fans: number, -- fan grilles on the casing; 0 for louvres and sleeves
	-- "face" discharges out the front, "top" discharges upward. Drives which way the grille
	-- faces and therefore what the silhouette reads as at proxy range.
	discharge: "face" | "top" | "none",
}

local ACUnitCatalog = {}

ACUnitCatalog.order = {
	-- residential
	"MiniSplitCondenser",
	"WindowRoomAC",
	"PTACSleeve",
	"PadCondenser",
	-- commercial
	"WallPackAC",
	"MultiSplitCondenser",
	"CommercialCondenser",
	"KitchenCondensingUnit",
	-- industrial
	"AirCooledChiller",
	"PanelCooler",
	"WallExhaustFan",
	"FluidCooler",
	-- office
	"VRFModule",
	"VRFBank",
	"FacadeLouvreBank",
} :: { string }

ACUnitCatalog.byKey = table.freeze({
	-- ---------------------------------------------------------------------------------
	-- RESIDENTIAL -- small, ivory, and hung high on the wall or sat on a pad by the fence.
	-- ---------------------------------------------------------------------------------
	MiniSplitCondenser = table.freeze({
		key = "MiniSplitCondenser", name = "Mini-Split Condenser",
		class = "Residential", kind = "Condenser", mount = "wall",
		mountMm = 2200, standoffMm = 330, radius = 1,
		tint = Color3.fromRGB(232, 228, 216), fans = 1, discharge = "face",
		mm = table.freeze({ 550, 800, 285 }),
	}),
	WindowRoomAC = table.freeze({
		key = "WindowRoomAC", name = "Window Unit",
		class = "Residential", kind = "Window", mount = "wall",
		mountMm = 1400, standoffMm = 400, radius = 1,
		tint = Color3.fromRGB(238, 236, 230), fans = 0, discharge = "face",
		-- Depth is the EXTERIOR PROJECTION, not the 560 mm product: a window unit lives half
		-- inside the opening and only the outboard box is ever drawn. Same for PTACSleeve.
		mm = table.freeze({ 430, 660, 400 }),
	}),
	PTACSleeve = table.freeze({
		key = "PTACSleeve", name = "PTAC Sleeve",
		class = "Residential", kind = "ThroughWall", mount = "wall",
		mountMm = 600, standoffMm = 120, radius = 1,
		tint = Color3.fromRGB(198, 196, 190), fans = 0, discharge = "face",
		mm = table.freeze({ 410, 1067, 120 }),
	}),
	PadCondenser = table.freeze({
		key = "PadCondenser", name = "Pad Condenser",
		class = "Residential", kind = "Condenser", mount = "ground",
		mountMm = 0, standoffMm = 0, radius = 2,
		tint = Color3.fromRGB(206, 204, 198), fans = 1, discharge = "top",
		mm = table.freeze({ 900, 800, 800 }),
	}),

	-- ---------------------------------------------------------------------------------
	-- COMMERCIAL -- bigger cabinets, beige powder coat, and the first units big enough that
	-- their fan grille is a silhouette feature rather than a detail.
	-- ---------------------------------------------------------------------------------
	WallPackAC = table.freeze({
		key = "WallPackAC", name = "Wall-Mount Package Unit",
		class = "Commercial", kind = "WallPack", mount = "wall",
		mountMm = 150, standoffMm = 610, radius = 2,
		tint = Color3.fromRGB(214, 208, 192), fans = 1, discharge = "face",
		mm = table.freeze({ 2210, 1220, 610 }),
	}),
	MultiSplitCondenser = table.freeze({
		key = "MultiSplitCondenser", name = "Multi-Split Condenser",
		class = "Commercial", kind = "Condenser", mount = "ground",
		mountMm = 0, standoffMm = 0, radius = 2,
		tint = Color3.fromRGB(222, 220, 212), fans = 2, discharge = "face",
		mm = table.freeze({ 1650, 950, 340 }),
	}),
	CommercialCondenser = table.freeze({
		key = "CommercialCondenser", name = "Commercial Condenser",
		class = "Commercial", kind = "Condenser", mount = "ground",
		mountMm = 0, standoffMm = 0, radius = 3,
		tint = Color3.fromRGB(190, 190, 186), fans = 1, discharge = "top",
		mm = table.freeze({ 1200, 1220, 1220 }),
	}),
	KitchenCondensingUnit = table.freeze({
		key = "KitchenCondensingUnit", name = "Kitchen Condensing Unit",
		class = "Commercial", kind = "Condenser", mount = "wall",
		mountMm = 450, standoffMm = 780, radius = 2,
		tint = Color3.fromRGB(178, 180, 182), fans = 1, discharge = "face",
		mm = table.freeze({ 760, 900, 700 }),
	}),

	-- ---------------------------------------------------------------------------------
	-- INDUSTRIAL -- deliberately the largest kit in the set, so an industrial wall reads as
	-- industrial from the skyline rather than from a label. The chiller is 4.2 m long: it is
	-- the one unit here that is bigger than the building prop it sits against.
	-- ---------------------------------------------------------------------------------
	AirCooledChiller = table.freeze({
		key = "AirCooledChiller", name = "Air-Cooled Chiller",
		class = "Industrial", kind = "Chiller", mount = "ground",
		mountMm = 0, standoffMm = 0, radius = 6,
		tint = Color3.fromRGB(168, 172, 176), fans = 4, discharge = "top",
		mm = table.freeze({ 2300, 4200, 2200 }),
	}),
	PanelCooler = table.freeze({
		key = "PanelCooler", name = "Panel Cooler",
		class = "Industrial", kind = "Condenser", mount = "wall",
		mountMm = 900, standoffMm = 250, radius = 1,
		tint = Color3.fromRGB(186, 190, 194), fans = 0, discharge = "face",
		mm = table.freeze({ 1200, 400, 250 }),
	}),
	WallExhaustFan = table.freeze({
		key = "WallExhaustFan", name = "Wall Exhaust Fan",
		class = "Industrial", kind = "Fan", mount = "wall",
		mountMm = 3000, standoffMm = 700, radius = 2,
		tint = Color3.fromRGB(158, 160, 164), fans = 1, discharge = "face",
		mm = table.freeze({ 1200, 1200, 700 }),
	}),
	FluidCooler = table.freeze({
		key = "FluidCooler", name = "Fluid Cooler",
		class = "Industrial", kind = "Tower", mount = "ground",
		mountMm = 0, standoffMm = 0, radius = 6,
		tint = Color3.fromRGB(176, 178, 174), fans = 1, discharge = "top",
		mm = table.freeze({ 3000, 2400, 1800 }),
	}),

	-- ---------------------------------------------------------------------------------
	-- OFFICE -- VRF modules, ganged. On a real tower this kit lives on a setback ledge or the
	-- podium roof edge, not scattered up the facade, and the louvre bank marks the plant floor.
	-- ---------------------------------------------------------------------------------
	VRFModule = table.freeze({
		key = "VRFModule", name = "VRF Module",
		class = "Office", kind = "Condenser", mount = "ground",
		mountMm = 0, standoffMm = 0, radius = 2,
		-- Two fans STACKED on the front face, not on the roof -- that vertical pair of circles
		-- on a slim tall cabinet is the whole reason a VRF module is recognisable at range.
		tint = Color3.fromRGB(226, 224, 218), fans = 2, discharge = "face",
		mm = table.freeze({ 1680, 930, 765 }),
	}),
	VRFBank = table.freeze({
		key = "VRFBank", name = "VRF Bank",
		class = "Office", kind = "Condenser", mount = "ground",
		mountMm = 0, standoffMm = 0, radius = 5,
		-- Four modules on one rail: 4 x 930 casing + 3 x 60 service gap = 3900.
		tint = Color3.fromRGB(226, 224, 218), fans = 8, discharge = "face",
		mm = table.freeze({ 1800, 3900, 765 }),
	}),
	FacadeLouvreBank = table.freeze({
		key = "FacadeLouvreBank", name = "Facade Louvre Bank",
		class = "Office", kind = "Louvre", mount = "wall",
		mountMm = 900, standoffMm = 300, radius = 3,
		tint = Color3.fromRGB(142, 146, 150), fans = 0, discharge = "none",
		mm = table.freeze({ 3000, 2400, 300 }),
	}),
}) :: { [string]: Entry }

-- Cabinet finishes. Exterior HVAC is a narrow palette in the real world -- nearly everything
-- is one of these four -- so keeping them here stops each new unit inventing its own grey and
-- lets a whole class be retinted at once. These are Part.Color values and they are the real
-- colour: unlike a building wall, none of this kit wears a texture, so nothing has to be
-- resolved through Shared.TextureAverages for the proxy to come out the right shade.
ACUnitCatalog.finish = table.freeze({
	Ivory      = Color3.fromRGB(232, 228, 216), -- residential split condensers
	LightGrey  = Color3.fromRGB(198, 200, 202), -- commercial cabinets
	Galvanised = Color3.fromRGB(168, 172, 176), -- industrial, mill finish
	Charcoal   = Color3.fromRGB(74, 78, 82),    -- grilles, guards, frames, bracket steel
})

function ACUnitCatalog.get(key: string): Entry?
	return ACUnitCatalog.byKey[key]
end

-- Every key of one building class, in catalog order.
function ACUnitCatalog.forClass(class: string): { string }
	local out = {}
	for _, key in ACUnitCatalog.order do
		local e = ACUnitCatalog.byKey[key]
		if e and e.class == class then table.insert(out, key) end
	end
	return out
end

return ACUnitCatalog
