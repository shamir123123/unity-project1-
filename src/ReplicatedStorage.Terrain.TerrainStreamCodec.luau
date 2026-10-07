--!strict
--!native
-- TerrainStreamCodec: the edited terrain chunks the server streams to a loading client, packed.
-- Pure library: no state, no side effects on require.
--
-- WHY. A raw chunk is 16.9 KB (heights 8,450 + materials 4,225 + flags 4,225). A big city has
-- hundreds of edited chunks, so the stream was megabytes of RemoteEvent traffic while the
-- client sat on the loading screen waiting for it -- with a 30 s timeout behind it. Heights are
-- smooth (a road grade is a constant step) and materials/flags are mostly zero, so a delta
-- code plus Zstd takes it to a small fraction of that.
--
-- LAYOUT before compression, planar so like bytes sit together (what Zstd feeds on):
--   u8 VERSION, u16 count, count x u16 key,
--   count x 4,225 low bytes, count x 4,225 high bytes  -- each height as the zigzagged
--       difference from the corner to its left (row start: from 0), so a smooth row is ~0s
--   count x 4,225 material bytes, count x 4,225 flag bytes
-- Lossless for any u16 heights: the difference wraps mod 65,536 both ways.

local EncodingService = game:GetService("EncodingService")

local TerrainStreamCodec = {}

local VERSION = 1
local SIDE = 65 -- Constants.CHUNK_CORNERS
local CELLS = SIDE * SIDE -- Constants.CHUNK_CORNER_COUNT
local ZSTD = Enum.CompressionAlgorithm.Zstd
local LEVEL = 6

export type Item = { key: number, h: buffer, m: buffer, f: buffer? }

-- Can this machine unpack a packed stream? Asked by the client, which tells the server, so a
-- client that cannot decompress is simply sent the raw chunks it always got.
function TerrainStreamCodec.supported(): boolean
	local ok, back = pcall(function(): buffer
		local probe = buffer.create(8)
		buffer.writeu32(probe, 0, 0xC0DE)
		return EncodingService:DecompressBuffer(EncodingService:CompressBuffer(probe, ZSTD, 1), ZSTD)
	end)
	return ok and typeof(back) == "buffer" and buffer.len(back) == 8 and buffer.readu32(back, 0) == 0xC0DE
end

function TerrainStreamCodec.pack(items: { Item }): buffer
	local n = #items
	local raw = buffer.create(3 + n * 2 + n * CELLS * 4)
	buffer.writeu8(raw, 0, VERSION)
	buffer.writeu16(raw, 1, n)
	local keys = 3
	local lo = keys + n * 2
	local hi = lo + n * CELLS
	local mat = hi + n * CELLS
	local flg = mat + n * CELLS
	for c, item in items do
		buffer.writeu16(raw, keys + (c - 1) * 2, item.key)
		local h = item.h
		local o = (c - 1) * CELLS
		for z = 0, SIDE - 1 do
			local prev = 0
			local row = z * SIDE
			for x = 0, SIDE - 1 do
				local i = row + x
				local v = buffer.readu16(h, i * 2)
				local d = (v - prev + 32768) % 65536 - 32768
				local zz = if d >= 0 then d * 2 else -d * 2 - 1
				buffer.writeu8(raw, lo + o + i, zz % 256)
				buffer.writeu8(raw, hi + o + i, zz // 256)
				prev = v
			end
		end
		buffer.copy(raw, mat + o, item.m, 0, CELLS)
		local f = item.f
		if f then buffer.copy(raw, flg + o, f, 0, CELLS) end
	end
	return EncodingService:CompressBuffer(raw, ZSTD, LEVEL)
end

-- nil for anything that does not decode to a whole, well-formed stream.
function TerrainStreamCodec.unpack(packed: any): { Item }?
	if typeof(packed) ~= "buffer" then return nil end
	local ok, items = pcall(function(): { Item }?
		local raw = EncodingService:DecompressBuffer(packed, ZSTD)
		if buffer.len(raw) < 3 or buffer.readu8(raw, 0) ~= VERSION then return nil end
		local n = buffer.readu16(raw, 1)
		if buffer.len(raw) ~= 3 + n * 2 + n * CELLS * 4 then return nil end
		local keys = 3
		local lo = keys + n * 2
		local hi = lo + n * CELLS
		local mat = hi + n * CELLS
		local flg = mat + n * CELLS
		local out: { Item } = table.create(n)
		for c = 1, n do
			local o = (c - 1) * CELLS
			local h = buffer.create(CELLS * 2)
			for z = 0, SIDE - 1 do
				local prev = 0
				local row = z * SIDE
				for x = 0, SIDE - 1 do
					local i = row + x
					local zz = buffer.readu8(raw, lo + o + i) + buffer.readu8(raw, hi + o + i) * 256
					local d = if zz % 2 == 0 then zz // 2 else -(zz + 1) // 2
					prev = (prev + d) % 65536
					buffer.writeu16(h, i * 2, prev)
				end
			end
			local m = buffer.create(CELLS)
			buffer.copy(m, 0, raw, mat + o, CELLS)
			local f = buffer.create(CELLS)
			buffer.copy(f, 0, raw, flg + o, CELLS)
			out[c] = { key = buffer.readu16(raw, keys + (c - 1) * 2), h = h, m = m, f = f }
		end
		return out
	end)
	return if ok then items else nil
end

return TerrainStreamCodec
