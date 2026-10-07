--!strict
return function()
 local function merger(source: string): any
  local first = assert(string.find(source, "function TerrainMesh.mergeGeo", 1, true))
  local last = assert(string.find(source, "\nreturn TerrainMesh", first, true))
  local env = setmetatable({ TerrainMesh = {} }, { __index = getfenv() })
  local chunk = assert(loadstring(string.sub(source, first, last - 1) .. "\nreturn TerrainMesh.mergeGeo"))
  setfenv(chunk, env)
  return chunk()
 end
 local function part(x: number, z: number): any
  return {
   origin = Vector3.new(x, 10+x, z),
   pos = { Vector3.new(-128,-2,-128), Vector3.new(128,3,-128), Vector3.new(128,2,128), Vector3.new(-128,-3,128) },
   nrm = { Vector3.yAxis, Vector3.xAxis, Vector3.zAxis, -Vector3.yAxis },
   col = { Color3.new(1,0,0), Color3.new(0,1,0), Color3.new(0,0,1), Color3.new(1,1,1) },
   uv = { Vector2.zero, Vector2.xAxis, Vector2.one, Vector2.yAxis },
   tri = { 1,3,2,1,4,3 },
  }
 end
 describe("TerrainMesh irregular merge", function()
  it("centres irregular chunk groups on their baked bounding box", function()
   local merge = merger(script.Parent.Parent.Source)
   for _, parts in {
    { part(0,0), part(256,0), part(0,256) },
    { part(0,0), part(768,0), part(0,256), part(256,256) },
   } do
    local g = merge(parts)
    local lo, hi = Vector3.new(math.huge,math.huge,math.huge), Vector3.new(-math.huge,-math.huge,-math.huge)
    for _, p in g.pos do lo = lo:Min(p); hi = hi:Max(p) end
    assert(math.abs(lo.X+hi.X)<0.001 and math.abs(lo.Y+hi.Y)<0.001 and math.abs(lo.Z+hi.Z)<0.001, "baked mesh would shift irregular terrain away from its heightmap")
    local reverse = {}
    for i=#parts,1,-1 do table.insert(reverse,parts[i]) end
    assert((merge(reverse).origin-g.origin).Magnitude<0.001, "member order changed the merged ground's origin")
   end
  end)
  it("preserves every world vertex, attribute, and triangle through the rebase", function()
   local parts = {part(0,0),part(768,0),part(0,256)}
   local merged = merger(script.Parent.Parent.Source)(parts)
   local count, triangles = 0, 0
   for _, g in parts do
    for i,p in g.pos do
     local j = count+i
     assert(((merged.origin+merged.pos[j])-(g.origin+p)).Magnitude<0.001, "merge moved a world vertex")
     assert(merged.nrm[j]==g.nrm[i] and merged.col[j]==g.col[i] and merged.uv[j]==g.uv[i], "merge changed a terrain attribute")
    end
    for i,v in g.tri do assert(merged.tri[triangles+i]==v+count, "merge changed triangle membership or winding") end
    count += #g.pos
    triangles += #g.tri
   end
   assert(#merged.pos==count and #merged.tri==triangles, "merge lost or added geometry")
  end)
 end)
end