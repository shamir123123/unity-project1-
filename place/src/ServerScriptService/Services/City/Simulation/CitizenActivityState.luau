--!strict
-- Compact resident activity records; only source facts, no saved routes or Instances.
local CitizenActivityState = {}
local STAGES = table.freeze({atHome=true,atWork=true,atStudy=true,atSchool=true,transit=true})
local function finite(n: any): boolean
 return typeof(n)=="number" and n==n and math.abs(n)<math.huge
end
local function position(p: any): {number}
 if typeof(p)~="Vector3" then return {} end
 return {math.round(p.X*10)/10,math.round(p.Y*10)/10,math.round(p.Z*10)/10}
end
function CitizenActivityState.pack(person: any, job: number?, destination: number?, pos: Vector3?): {any}
 return {person.pid,person.age,person.name,person.gender,person.eduLevel or person.bestTier or 0,
 job or 0,person.stage,person.commutedWorkDay or -1,person.outKind or "",destination or 0,
 person.tripTargetHome==true,position(pos),person.usingCar==true,person.studyId or 0,
 person.schoolId or 0,position(person.studyPos or person.schoolPos),person.commutedHomeDay or -1,
 person.commutedSchoolDay or -1,person.ownsCar==true}
end
function CitizenActivityState.position(data: any): Vector3?
 if typeof(data)~="table" or not finite(data[1]) or not finite(data[2]) or not finite(data[3]) then return nil end
 if math.max(math.abs(data[1]),math.abs(data[2]),math.abs(data[3]))>100000 then return nil end
 return Vector3.new(data[1],data[2],data[3])
end
function CitizenActivityState.apply(person: any, data: any): boolean
 if typeof(data)~="table" or not finite(data[1]) or data[1]<1 or data[1]%1~=0 then return false end
 if not finite(data[2]) or not STAGES[data[7]] then return false end
 person.pid=data[1];person.age=math.clamp(data[2],0,120)
 if finite(data[5]) then
  if person.eduLevel~=nil then person.eduLevel=math.clamp(math.floor(data[5]),0,3)
  else person.bestTier=math.clamp(math.floor(data[5]),0,3) end
 end
 if typeof(data[3])=="string" then person.name=data[3]:sub(1,80) end
 if data[4]=="M" or data[4]=="F" then person.gender=data[4] end
 person.stage=data[7]
 person.commutedWorkDay=if finite(data[8]) and data[8]>=0 then data[8] else nil
 person.commutedHomeDay=if finite(data[17]) and data[17]>=0 then data[17] else nil
 person.commutedSchoolDay=if finite(data[18]) and data[18]>=0 then data[18] else nil
 person.outKind=if typeof(data[9])=="string" and data[9]~="" then data[9] else nil
 person.tripTargetHome=data[11]==true
 person.usingCar=data[13]==true
 if typeof(data[19])=="boolean" then person.ownsCar=data[19] end
 return true
end
return table.freeze(CitizenActivityState)
