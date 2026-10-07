--!strict
-- Deadlines in simulation time. No tasks or live server dependencies.
export type Job = { at: number, run: () -> (), valid: () -> boolean, failed: (any) -> () }
export type Queue = { push: (Job) -> (), popDue: (number) -> Job?, nextAt: () -> number?, clear: () -> () }
local ConstructionQueue = {}

function ConstructionQueue.new(): Queue
	local heap: { Job } = {}
	local function push(job: Job)
		local i = #heap + 1
		while i > 1 do
			local parent = math.floor(i / 2)
			if heap[parent].at <= job.at then break end
			heap[i] = heap[parent]
			i = parent
		end
		heap[i] = job
	end
	local function popDue(now: number): Job?
		local first = heap[1]
		if not first or first.at > now then return nil end
		local last = table.remove(heap)
		if #heap > 0 then
			local i = 1
			while i * 2 <= #heap do
				local child = i * 2
				if child < #heap and heap[child + 1].at < heap[child].at then child += 1 end
				if (last :: Job).at <= heap[child].at then break end
				heap[i] = heap[child]
				i = child
			end
			heap[i] = last :: Job
		end
		return first
	end
	return {
		push = push,
		popDue = popDue,
		nextAt = function(): number? return if heap[1] then heap[1].at else nil end,
		clear = function() table.clear(heap) end,
	}
end

return table.freeze(ConstructionQueue)
