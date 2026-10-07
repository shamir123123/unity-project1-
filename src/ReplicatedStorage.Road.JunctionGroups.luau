--!strict
-- JunctionGroups -- super nodes (user, 2026-10-07, after the Cities: Skylines "super node").
-- Junctions too close together for their own stop lines, crosswalks and arrows act as ONE
-- junction: no markings on the short links between them, one control decision, and one signal
-- controller for the roads ENTERING the group (cars on the links inside keep going). They stay
-- separate nodes, so a road is always built exactly where its preview showed it.
-- Pure library: the road mesh (client) and the signals (server) both ask it.

local RoadConstants = require(script.Parent.RoadConstants)

local JunctionGroups = {}

-- The least road left between two approaches before they count as one junction: a link that
-- still holds both stop lines and crossings keeps them (user, 2026-10-07: an avenue grid on 45 m
-- blocks and a triangle junction read better with their own markings).
local LINK_GAP = RoadConstants.ARROW_GAP

export type Groups = {
	groupOf: { [number]: number }, -- node id -> its group's id (the smallest member node id)
	internal: { [number]: boolean }, -- segment ids of the short links inside a group
}

-- How far from its node a junction's markings reach along arm k: its stop line, else its crossing.
local function marked(p: any, k: number): number
	if p.stopAt[k] > 0 then return p.stopAt[k] end
	return p.trims[k] + (if p.crosswalk[k] then RoadConstants.CROSSWALK_DEPTH else 0)
end

-- Is the road `arm` i of junction plan `a` a link inside a group: does it run to junction `b`
-- (its arm `j` is the same road) too short to hold both their stop lines and crossings?
function JunctionGroups.isLink(a: any, i: number, b: any, j: number): boolean
	if a.kind ~= "junction" or b.kind ~= "junction" then return false end
	return a.arms[i].len < marked(a, i) + marked(b, j) + LINK_GAP
end

-- `plans`: node id -> RoadJunctionSolver plan (arms carry segId and len). `farNode(node, seg)`:
-- the node at that road's other end.
function JunctionGroups.find(plans: { [number]: any }, farNode: (number, number) -> number?): Groups
	local parent: { [number]: number } = {}
	local function root(x: number): number
		while parent[x] ~= x do x = parent[x] end
		return x
	end
	local internal: { [number]: boolean } = {}
	for a, pa in plans do
		for i, arm in pa.arms do
			local b = farNode(a, arm.segId)
			local pb = if b and b ~= a then plans[b] else nil
			if not b or not pb then continue end
			for j, other in pb.arms do
				if other.segId ~= arm.segId then continue end
				if JunctionGroups.isLink(pa, i, pb, j) then
					internal[arm.segId] = true
					parent[a], parent[b] = parent[a] or a, parent[b] or b
					local ra, rb = root(a), root(b)
					if ra ~= rb then parent[math.max(ra, rb)] = math.min(ra, rb) end
				end
				break
			end
		end
	end
	local groupOf: { [number]: number } = {}
	for x in parent do
		groupOf[x] = root(x)
	end
	return { groupOf = groupOf, internal = internal }
end

return table.freeze(JunctionGroups)
