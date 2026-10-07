--!strict
-- generationId: 3803558c-2cf8-4d1b-9b14-69b361e1abac
local CSG = require(script.Dependencies.ConstructiveSolidGeometry)
local GP = require(script.Dependencies.GeometryPrimitives)
local SO = require(script.Dependencies.SmartObject)
local MU = require(script.Dependencies.MathUtils)


local RetractableAwning = {}

type Parameters = {
	Size: Vector3,
	Attributes: {
		ColorStripe1: Color3?,
		ColorStripe2: Color3?,
		ColorHousing: Color3?,
		ColorFrame: Color3?,
		StripeWidth: number?,
		ValanceDrop: number?,
	},
}
local startTime = 0
local timerThread : thread = task.spawn(function()
while true do
	if not script:IsDescendantOf(game) then
		startTime = 0
		return
	end
	if startTime > 0 then
		local elapsed = tick() - startTime
		print("[ProceduralModel] " .. script:GetFullName() .. " rendering... " .. string.format("%.0f", elapsed) .. " seconds")
	end
	task.wait(3)
end
end)
script.Destroying:Connect(function()
	task.cancel(timerThread)
end)

RetractableAwning.OnGenerate = function(parameters: Parameters, targetContainer: Instance)
	-- Timer setup
	startTime = tick()

	local awningModel = GP.model("RetractableAwning", nil)-- Fix orientation of the model
	awningModel.WorldPivot = CFrame.identity
	
	
	-- ==========================================
	-- SEMANTIC PARAMETERS (Attributes)
	-- ==========================================
	local smartWidth = parameters.Size.X
	local smartHeight = parameters.Size.Y
	local smartDepth = parameters.Size.Z
	
	local cStripe1 = parameters.Attributes.ColorStripe1 or Color3.fromRGB(245, 205, 50) -- Warm Yellow
	local cStripe2 = parameters.Attributes.ColorStripe2 or Color3.fromRGB(250, 250, 250) -- White
	local cHousing = parameters.Attributes.ColorHousing or Color3.fromRGB(220, 220, 225) -- Light Grey/White
	local cFrame = parameters.Attributes.ColorFrame or Color3.fromRGB(200, 200, 205) -- Metal Grey
	
	local targetStripeWidth = parameters.Attributes.StripeWidth or 1.0
	local valanceDrop = parameters.Attributes.ValanceDrop or 0.8
	
	-- Scaling factors for Y and Z (since default is 10)
	local scaleY = smartHeight / 10
	local scaleZ = smartDepth / 10
	
	-- Derived dimensions
	local extensionZ = smartDepth -- Extends in -Z
	local dropY = 3.0 * scaleY    -- How far down the front bar sits compared to the housing
	local housingH = 1.5 * scaleY
	local housingD = 1.5 * scaleZ
	local bracketDropY = 4.0 * scaleY -- Where the arms mount on the wall
	
	local fabricThickness = 0.05
	local barRadius = 0.3 * scaleY
	local armThickness = 0.2 * scaleY
	
	local matMetal = "SmoothPlastic"
	local matFabric = "Fabric"
	
	-- Base positions
	local origin = Vector3.new(0, 0, 0)
	local wallZ = 0
	local frontZ = -extensionZ
	local topY = 0
	local frontY = topY - dropY
	
	-- Stripe calculations
	local stripeCount = math.max(1, math.floor(smartWidth / targetStripeWidth))
	local actualStripeW = smartWidth / stripeCount
	
	-- ==========================================
	-- 1. HOUSING / CASSETTE
	-- ==========================================
	local housingGroup = GP.model("Housing", awningModel)
	
	-- Back mounting block (against the wall)
	GP.axisAlignedBlockFromCorners("HousingBack",
	    Vector3.new(smartWidth/2, topY - housingH, wallZ),
	    Vector3.new(-smartWidth/2, topY, wallZ - housingD * 0.7),
	    cHousing, matMetal, housingGroup
	)
	
	-- Rounded top/front edge
	GP.cylinder("HousingCurve",
	    Vector3.new(smartWidth/2, topY - housingH/2, wallZ - housingD * 0.7),
	    Vector3.new(-smartWidth/2, topY - housingH/2, wallZ - housingD * 0.7),
	    housingH/2, cHousing, matMetal, housingGroup
	)
	
	-- End Caps
	GP.cylinder("EndCapLeft",
	    Vector3.new(smartWidth/2 + 0.1, topY - housingH/2, wallZ - housingD * 0.7),
	    Vector3.new(smartWidth/2, topY - housingH/2, wallZ - housingD * 0.7),
	    housingH/2 * 1.05, cHousing, matMetal, housingGroup
	)
	GP.cylinder("EndCapRight",
	    Vector3.new(-smartWidth/2 - 0.1, topY - housingH/2, wallZ - housingD * 0.7),
	    Vector3.new(-smartWidth/2, topY - housingH/2, wallZ - housingD * 0.7),
	    housingH/2 * 1.05, cHousing, matMetal, housingGroup
	)
	GP.axisAlignedBlockFromCorners("EndCapLeftBox",
	    Vector3.new(smartWidth/2 + 0.1, topY - housingH, wallZ),
	    Vector3.new(smartWidth/2, topY, wallZ - housingD * 0.7),
	    cHousing, matMetal, housingGroup
	)
	GP.axisAlignedBlockFromCorners("EndCapRightBox",
	    Vector3.new(-smartWidth/2 - 0.1, topY - housingH, wallZ),
	    Vector3.new(-smartWidth/2, topY, wallZ - housingD * 0.7),
	    cHousing, matMetal, housingGroup
	)
	
	-- ==========================================
	-- 2. CANOPY & VALANCE
	-- ==========================================
	local canopyGroup = GP.model("Canopy", awningModel)
	
	local fabricStartX = smartWidth/2
	local fabricZStart = wallZ - housingD * 0.5
	local fabricYStart = topY - housingH * 0.2
	
	for i = 1, stripeCount do
	    local isColor1 = (i % 2 == 1)
	    local col = isColor1 and cStripe1 or cStripe2
	    
	    local startX = fabricStartX - (i - 1) * actualStripeW
	    local endX = fabricStartX - i * actualStripeW
	    
	    -- Sloped Canopy Segment
	    GP.quadFromFourPoints("Stripe_" .. i,
	        Vector3.new(startX, fabricYStart, fabricZStart),
	        Vector3.new(endX, fabricYStart, fabricZStart),
	        Vector3.new(endX, frontY, frontZ),
	        Vector3.new(startX, frontY, frontZ),
	        fabricThickness, nil, col, matFabric, canopyGroup
	    )
	    
	    -- Valance Segment (Points down at the front)
	    -- V-shaped point for the scallop
	    local valanceMidX = (startX + endX) / 2
	    local valanceBottomY = frontY - (valanceDrop * scaleY)
	    
	    -- Offset slightly in Z to hang from the front bar
	    local valFrontZ = frontZ - barRadius - 0.05
	    
	    -- Create the pointed flap using a triangle
	    -- Use a prism with thickness
	    GP.triangularPrismFromThreePoints("Valance_" .. i,
	        Vector3.new(startX, frontY, valFrontZ),
	        Vector3.new(endX, frontY, valFrontZ),
	        Vector3.new(valanceMidX, valanceBottomY, valFrontZ),
	        fabricThickness, Vector3.new(0,0,1), col, matFabric, canopyGroup
	    )
	end
	
	-- ==========================================
	-- 3. FRONT BAR
	-- ==========================================
	local frameGroup = GP.model("Frame", awningModel)
	
	GP.cylinder("FrontBar",
	    Vector3.new(smartWidth/2 + 0.2, frontY, frontZ),
	    Vector3.new(-smartWidth/2 - 0.2, frontY, frontZ),
	    barRadius, cFrame, matMetal, frameGroup
	)
	
	-- ==========================================
	-- 4. SUPPORT ARMS
	-- ==========================================
	-- We will place two support arms near the edges
	local armInset = actualStripeW * 1.5
	if armInset > smartWidth/3 then armInset = smartWidth/4 end
	
	local leftArmX = smartWidth/2 - armInset
	local rightArmX = -smartWidth/2 + armInset
	
	local bracketY = topY - bracketDropY
	local bracketZ = wallZ
	
	local function buildArm(name, xPos)
	    local armMod = GP.model(name, frameGroup)
	    
	    -- Wall Bracket
	    local bracketH = 1.0 * scaleY
	    local bracketW = 0.4 * scaleY
	    local bracketD = 0.1 * scaleZ
	    GP.axisAlignedBlockFromCorners("BracketPlate",
	        Vector3.new(xPos + bracketW/2, bracketY + bracketH/2, bracketZ),
	        Vector3.new(xPos - bracketW/2, bracketY - bracketH/2, bracketZ - bracketD),
	        cFrame, matMetal, armMod
	    )
	    
	    -- Pivot mount
	    GP.cylinder("BracketPivot",
	        Vector3.new(xPos + bracketW/2, bracketY, bracketZ - bracketD - 0.1),
	        Vector3.new(xPos - bracketW/2, bracketY, bracketZ - bracketD - 0.1),
	        0.15 * scaleY, cFrame, matMetal, armMod
	    )
	    
	    -- The Arm (from pivot to front bar)
	    -- We split the arm into two segments, angled up to meet the bar, like a classic elbow arm
	    -- For simplicity and robustness, a single straight strut from bracket to front bar works, 
	    -- but a hinged elbow looks better. Let's make an elbow that points slightly downward.
	    
	    local startP = Vector3.new(xPos, bracketY, bracketZ - bracketD - 0.1)
	    local endP = Vector3.new(xPos, frontY, frontZ + barRadius)
	    
	    -- Midpoint pushed down to create an elbow
	    local midP = startP:Lerp(endP, 0.5) + Vector3.new(0, -0.5 * scaleY, 0)
	    
	    -- Arm segment 1
	    GP.strutFromTwoPoints("Arm1", startP, midP, armThickness, armThickness * 1.5, cFrame, matMetal, armMod)
	    -- Arm segment 2
	    GP.strutFromTwoPoints("Arm2", midP, endP, armThickness, armThickness * 1.5, cFrame, matMetal, armMod)
	    
	    -- Elbow joint
	    GP.cylinder("Elbow",
	        midP + Vector3.new(armThickness, 0, 0),
	        midP - Vector3.new(armThickness, 0, 0),
	        armThickness * 1.1, cHousing, matMetal, armMod
	    )
	end
	
	buildArm("LeftArm", leftArmX)
	buildArm("RightArm", rightArmX)
	
	awningModel.Parent = targetContainer
	-- reposition
	for _, part in targetContainer:GetDescendants() do
		if part:IsA("BasePart") then
			part.CFrame -= Vector3.yAxis * parameters.Size.Y / 2
		end
	end
	for _, model in targetContainer:GetDescendants() do
		if model:IsA("Model") then
			model.WorldPivot -= Vector3.yAxis * parameters.Size.Y / 2
		end
	end

	-- Stop timer when generation completes
	local timeElapsed = tick() - startTime
	startTime = 0
	if timeElapsed > 3 and script:IsDescendantOf(game) then
		print("[ProceduralModel] " .. script:GetFullName() .. " rendering completed")
	end

end

return RetractableAwning
