--!nonstrict
-- ACUnitCatalog.spec -- every exterior AC prop, checked against the LOD ladder it will
-- actually ride rather than against how it looks in the viewport.
--
-- The assertions worth having are the ones that are easy to get wrong and impossible to see:
--   * meshBacked must be FALSE. ModelBaker.bakeMesh refuses mesh-backed non-foliage models,
--     so a unit that drifts over half its volume into MeshParts silently loses BOTH mesh
--     rungs and becomes a flat quad at 1000 studs. Nothing looks wrong up close when that
--     happens -- which is the entire reason this file exists.
--   * coarsen must at least halve keptParts, because that halving is exactly the test
--     LODProxyCache.bakeFor applies before it will spend a bake on the DISTANT rung.
--   * the volume above the 300 mm bake gate, because on kit this small almost every fitting
--     is under it and a unit can quietly reduce to nothing at proxy range.
--
-- Runs in Edit mode: the whole bake path (CreateEditableMesh / collect / bakeMesh) works from
-- the command bar, so this needs no play session. bakeMesh slices across frames, so give the
-- runner room:
--   print(require(game.ServerScriptService.Tests.SpecRunner)(30))

return function()
	local RS = game:GetService("ReplicatedStorage")
	local ModelBaker = require(RS.Shared.ModelBaker)
	local ACUnitCatalog = require(script.Parent)
	local units = script.Parent.Parent

	-- ModelBaker.MIN_FEATURE_STUDS and AssetLODView.DETAIL_STUDS, mirrored. Both are private
	-- to their modules; if either moves, this spec is where the mismatch should surface.
	local MIN_FEATURE = 0.6
	local STUD_MM = 500 -- WORLD_SCALE 0.5 => 1 m = 2 studs

	local function template(key)
		local m = units:FindFirstChild(key)
		if not (m and m:IsA("Model")) then
			error(("no template Model named %q in the ACUnits folder"):format(key))
		end
		return m
	end

	describe("catalog data", function()
		it("every ordered key resolves to an entry that agrees with its own key", function()
			for _, key in ACUnitCatalog.order do
				local e = ACUnitCatalog.get(key)
				if not e then error(("order lists %q but byKey has no entry"):format(key)) end
				expect(e.key).to.equal(key)
				expect(e.name).to.be.a("string")
				if e.mount ~= "wall" and e.mount ~= "ground" then
					error(("%s: mount is %q, expected wall or ground"):format(key, tostring(e.mount)))
				end
				if e.mount == "ground" and (e.mountMm ~= 0 or e.standoffMm ~= 0) then
					error(("%s stands on the ground but declares mountMm/standoffMm"):format(key))
				end
				if e.mount == "wall" and e.mountMm <= 0 then
					error(("%s hangs on a wall but declares no mounting height"):format(key))
				end
			end
		end)

		it("byKey holds nothing that order forgot to list", function()
			local listed = {}
			for _, key in ACUnitCatalog.order do listed[key] = true end
			for key in ACUnitCatalog.byKey do
				if not listed[key] then error(("byKey has %q but order does not list it"):format(key)) end
			end
		end)

		it("covers all four building classes", function()
			for _, class in { "Residential", "Commercial", "Industrial", "Office" } do
				local keys = ACUnitCatalog.forClass(class)
				if #keys < 3 then
					error(("%s has only %d unit(s); a class needs at least 3 to dress a street")
						:format(class, #keys))
				end
			end
		end)

		it("tables are frozen per project rule 12", function()
			expect(table.isfrozen(ACUnitCatalog.byKey)).to.equal(true)
			expect(table.isfrozen(ACUnitCatalog.finish)).to.equal(true)
		end)
	end)

	describe("templates", function()
		it("every catalog key has a Model beside the catalog", function()
			for _, key in ACUnitCatalog.order do template(key) end
		end)

		it("every part is anchored, non-query and non-touch", function()
			for _, key in ACUnitCatalog.order do
				for _, d in template(key):GetDescendants() do
					if d:IsA("BasePart") then
						if not d.Anchored then error(("%s.%s is not anchored"):format(key, d.Name)) end
						if d.CanQuery then error(("%s.%s has CanQuery on"):format(key, d.Name)) end
						if d.CanTouch then error(("%s.%s has CanTouch on"):format(key, d.Name)) end
					end
				end
			end
		end)

		it("nothing is a MeshPart or a Union", function()
			-- The guard one rung earlier than meshBacked: a single imported mesh can tip a small
			-- unit over the half-volume line on its own, and this says which part did it.
			for _, key in ACUnitCatalog.order do
				for _, d in template(key):GetDescendants() do
					if d:IsA("MeshPart") or d:IsA("UnionOperation") then
						error(("%s.%s is a %s -- part-built is what earns the mesh rungs")
							:format(key, d.Name, d.ClassName))
					end
				end
			end
		end)

		it("pivots sit on the local origin so PivotTo lands them with no fudge", function()
			-- Both mounting conventions put their reference point at the origin: the ground plane
			-- centred on the footprint for a ground unit, the point where the wall plane meets the
			-- ground for a wall unit. One assertion covers both.
			for _, key in ACUnitCatalog.order do
				local m = template(key)
				if not m.PrimaryPart then error(("%s has no PrimaryPart"):format(key)) end
				local p = m:GetPivot().Position
				if p.Magnitude > 1e-3 then
					error(("%s pivot is %.3f studs off the local origin (%.3f, %.3f, %.3f)")
						:format(key, p.Magnitude, p.X, p.Y, p.Z))
				end
			end
		end)

		it("wall units keep every part on the outboard side of the wall plane", function()
			-- A wall template is authored with the wall at z = 0 and the unit hanging out toward
			-- -Z. A part that strays to +Z would be buried inside the building the moment a placer
			-- seats it against a facade, and nothing about the template would look wrong.
			for _, key in ACUnitCatalog.order do
				local e = ACUnitCatalog.get(key)
				if e.mount ~= "wall" then continue end
				for _, d in template(key):GetDescendants() do
					if d:IsA("BasePart") then
						local back = d.Position.Z + d.Size.Z / 2
						if back > 1e-3 then
							error(("%s.%s reaches %.0f mm INTO the wall"):format(key, d.Name, back * STUD_MM))
						end
					end
				end
			end
		end)

		it("wall units start at the mounting height the catalog declares", function()
			-- The template owns its own height above ground; a placer only supplies the wall. If
			-- the two disagree, every mini-split in the city sits at the wrong storey.
			for _, key in ACUnitCatalog.order do
				local e = ACUnitCatalog.get(key)
				if e.mount ~= "wall" then continue end
				local m = template(key)
				local casing = m:FindFirstChild("Casing")
				if not (casing and casing:IsA("BasePart")) then continue end
				local bottom = (casing.Position.Y - casing.Size.Y / 2) * STUD_MM
				if math.abs(bottom - e.mountMm) > 25 then
					error(("%s casing sits at %.0f mm, catalog declares mountMm %.0f")
						:format(key, bottom, e.mountMm))
				end
			end
		end)

		it("matches the real-world envelope the entry was measured from", function()
			-- Cabinet units carry a part literally named Casing that IS the product envelope, so
			-- they are held to 2%. Frame-built units (chiller, fluid cooler, VRF bank, louvre
			-- bank) have no single cabinet -- their published size is the overall machine, cowl
			-- included -- so those are measured on model extents at 10%, which still catches a
			-- unit drifting a whole size class away from what the catalog claims.
			for _, key in ACUnitCatalog.order do
				local e = ACUnitCatalog.get(key)
				local m = template(key)
				local casing = m:FindFirstChild("Casing")
				local size, tol, source
				if casing and casing:IsA("BasePart") then
					size, tol, source = casing.Size, 0.02, "casing"
				else
					size, tol, source = m:GetExtentsSize(), 0.10, "extents"
				end
				local got = { size.Y * STUD_MM, size.X * STUD_MM, size.Z * STUD_MM }
				local axis = { "height", "width", "depth" }
				for i = 1, 3 do
					local want = e.mm[i]
					if math.abs(got[i] - want) > want * tol then
						error(("%s %s (%s) is %.0f mm, catalog says %.0f mm")
							:format(key, axis[i], source, got[i], want))
					end
				end
			end
		end)

		it("declares as many fan grilles as it actually models", function()
			for _, key in ACUnitCatalog.order do
				local e = ACUnitCatalog.get(key)
				local guards = 0
				for _, d in template(key):GetDescendants() do
					if d:IsA("BasePart") and d.Name:match("Guard") then guards += 1 end
				end
				if guards ~= e.fans then
					error(("%s models %d fan guard(s) but the catalog declares fans = %d")
						:format(key, guards, e.fans))
				end
			end
		end)
	end)

	describe("LOD ladder", function()
		it("no unit is mesh-backed, so bakeMesh will not refuse it", function()
			for _, key in ACUnitCatalog.order do
				local bake = ModelBaker.collect(template(key), {})
				expect(bake).to.be.ok()
				if bake.meshBacked then
					error(("%s is mesh-backed: it would get NO mesh rungs, only an impostor"):format(key))
				end
			end
		end)

		it("every unit bakes a FAR mesh", function()
			for _, key in ACUnitCatalog.order do
				local bake = ModelBaker.collect(template(key), {})
				local mesh = ModelBaker.bakeMesh(bake, "spec_ac_" .. key)
				if not mesh then error(("%s baked no FAR mesh"):format(key)) end
				mesh:Destroy()
			end
		end)

		it("box-built units earn the DISTANT rung by at least halving keptParts", function()
			-- Only box-built units are held to this. ModelBaker.coarsen merges BOXES and keeps
			-- every non-box spec exactly as it is, on purpose -- a fan cowl or a drum is most of
			-- what makes an outline recognisable, and flattening it to an AABB is the one
			-- simplification that reads as the shape changing. A unit dominated by cylindrical
			-- guards therefore cannot halve however it is authored, and correctly falls back to
			-- its FAR mesh at DISTANT -- LODProxyCache.meshFor returns `coarse or mesh`.
			for _, key in ACUnitCatalog.order do
				local m = template(key)
				local boxes, total = 0, 0
				for _, d in m:GetDescendants() do
					if d:IsA("BasePart") then
						total += 1
						if d:IsA("Part") and d.Shape == Enum.PartType.Block then boxes += 1 end
					end
				end
				if total == 0 or boxes / total < 0.7 then continue end
				local bake = ModelBaker.collect(m, {})
				-- Too simple to coarsen: halving 6 parts means getting to 3, and there is no
				-- version of a panel cooler that is three boxes and still a panel cooler.
				-- LODProxyCache declines to spend a bake here for the same reason.
				if bake.keptParts < 8 then continue end
				local coarse = ModelBaker.coarsen(bake)
				-- The exact test LODProxyCache.bakeFor applies before spending a coarse bake.
				if coarse.keptParts * 2 > bake.keptParts then
					error(("%s is %.0f%% boxes and coarsens only %d -> %d, so LODProxyCache will not bake it a coarse rung")
						:format(key, boxes / total * 100, bake.keptParts, coarse.keptParts))
				end
			end
		end)

		it("the parts that carry the silhouette survive MIN_FEATURE_STUDS", function()
			-- Small fittings are SUPPOSED to fall through the gate -- valve covers, service
			-- hatches, badges. What must not is the mass: require most of each unit's volume to
			-- sit in parts the bake will actually keep, or the proxy comes out hollow.
			for _, key in ACUnitCatalog.order do
				local kept, dropped = 0, 0
				for _, d in template(key):GetDescendants() do
					if d:IsA("BasePart") then
						local v = d.Size.X * d.Size.Y * d.Size.Z
						if math.max(d.Size.X, d.Size.Y, d.Size.Z) < MIN_FEATURE then
							dropped += v
						else
							kept += v
						end
					end
				end
				local share = kept / math.max(kept + dropped, 1e-6)
				if share < 0.9 then
					error(("%s keeps only %.0f%% of its volume above the 300 mm bake gate")
						:format(key, share * 100))
				end
			end
		end)

		it("every fan guard clears the bake gate on its diameter", function()
			-- The one detail that must never be dropped: a condenser with no visible fan reads as
			-- a plain crate. Guards are sized by diameter precisely so this holds.
			for _, key in ACUnitCatalog.order do
				for _, d in template(key):GetDescendants() do
					if d:IsA("BasePart") and d.Name:match("Guard") then
						local longest = math.max(d.Size.X, d.Size.Y, d.Size.Z)
						if longest < MIN_FEATURE then
							error(("%s.%s is %.0f mm across and would be dropped from the bake")
								:format(key, d.Name, longest * STUD_MM))
						end
					end
				end
			end
		end)
	end)
end
