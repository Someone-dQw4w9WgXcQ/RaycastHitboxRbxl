--!strict

--- RaycastModuleV4 2021
-- @author Swordphin123

-- Debug / Test ray visual options
local SHOW_DEBUG_RAY_LINES: boolean = true
local DEFAULT_DEBUGGER_RAY_COLOUR: Color3 = Color3.fromRGB(255, 0, 0)
local DEFAULT_DEBUGGER_RAY_WIDTH: number = 4
local DEFAULT_DEBUGGER_RAY_NAME: string = "_RaycastHitboxDebugLine"
local DEFAULT_DEBUGGER_RAY_DURATION: number = 0.25

local DEFAULT_FAR_AWAY_CFRAME: CFrame = CFrame.new(0, math.huge, 0)

-- Allow RaycastModule to write to the output
local SHOW_OUTPUT_MESSAGES: boolean = false

-- Instance options
local DEFAULT_ATTACHMENT_INSTANCE: string = "DamagePoint"
local DEFAULT_GROUP_NAME_INSTANCE: string = "Group"

-- Debug Message options
local DEFAULT_DEBUG_LOGGER_PREFIX: string = "[ Raycast Hitbox V4 ]\n"
local DEFAULT_MISSING_ATTACHMENTS: string = "No attachments found in object: %s. Can be safely ignored if using SetPoints."
local DEFAULT_ATTACH_COUNT_NOTICE: string = "%s attachments found in object: %s."

local adornmentsLastUse = {}
local adornmentsInReserve = {}

local Hitbox = {}
Hitbox.__index = Hitbox
Hitbox.__type = "RaycastHitbox"

-- The tag name. Used for cleanup.
local DEFAULT_COLLECTION_TAG_NAME: string = "_RaycastHitboxV4Managed"

local CollectionService = game:GetService("CollectionService")

--- Initialize required modules
local Signal = require(game:GetService("ReplicatedStorage"):WaitForChild("Modules"):WaitForChild("Signal"))

-- Detection mode enums
Hitbox.DetectionMode = {
	Humanoid = 1,
	PartMode = 2,
	Bypass = 3,
}

-- Hitbox values
local MINIMUM_SECONDS_SCHEDULER: number = 1 / 60
local DEFAULT_SIMULATION_TYPE: RBXScriptSignal = game:GetService("RunService").Heartbeat

type Point = {
	Group: string?,
	CastMode: Solver,
	LastPosition: Vector3?,
	WorldSpace: Vector3?,
	Instances: {[number]: (Instance | Vector3)}
}

type Solver = {
	Solve: ({[string]: any}) -> (Vector3, Vector3),
	UpdateToNextPosition: ({[string]: any}) -> (Vector3),
	Visualize: ({[string]: any}) -> (CFrame)
}

local Vector3Solver: Solver = {
	--- Solve direction and length of the ray by comparing current and last frame's positions
	-- @param point type
	Solve = function(point)
		--- Translate localized Vector3 positions to world space values
		local originPart: BasePart = point.Instances[1]
		local vector = point.Instances[2]:: any
		local pointToWorldSpace = originPart.Position + originPart.CFrame:VectorToWorldSpace(vector)

		--- If LastPosition is nil (caused by if the hitbox was stopped previously), rewrite its value to the current point position
		if not point.LastPosition then
			point.LastPosition = pointToWorldSpace
		end

		local origin = point.LastPosition
		local direction = pointToWorldSpace - (point.LastPosition or Vector3.zero)

		point.WorldSpace = pointToWorldSpace

		return origin, direction
	end,

	UpdateToNextPosition = function(point)
		return point.WorldSpace
	end,

	Visualize = function(point)
		return CFrame.lookAt(point.WorldSpace, point.LastPosition)
	end
}
local AttachmentSolver: Solver = {
	--- Solve direction and length of the ray by comparing current and last frame's positions
	Solve = function(point)
		--- If LastPosition is nil (caused by if the hitbox was stopped previously), rewrite its value to the current point position
		if not point.LastPosition then
			point.LastPosition = point.Instances[1].WorldPosition
		end

		local origin: Vector3 = point.Instances[1].WorldPosition
		local direction: Vector3 = point.Instances[1].WorldPosition - point.LastPosition

		return origin, direction
	end,

	UpdateToNextPosition = function(point)
		return point.Instances[1].WorldPosition
	end,

	Visualize = function(point)
		return CFrame.lookAt(point.Instances[1].WorldPosition, point.LastPosition)
	end
}
local BoneSolver: Solver = {
	--- Solve direction and length of the ray by comparing current and last frame's positions
	-- @param point type
	Solve = function(point)
		--- Translate localized bone positions to world space values
		local originBone: Bone = point.Instances[1]
		local vector: Vector3 = point.Instances[2]
		local worldCFrame: CFrame = originBone.TransformedWorldCFrame
		local pointToWorldSpace: Vector3 = worldCFrame.Position + worldCFrame:VectorToWorldSpace(vector)

		--- If LastPosition is nil (caused by if the hitbox was stopped previously), rewrite its value to the current point position
		if not point.LastPosition then
			point.LastPosition = pointToWorldSpace
		end

		local origin: Vector3 = point.LastPosition
		local direction: Vector3 = pointToWorldSpace - (point.LastPosition or Vector3.zero)

		point.WorldSpace = pointToWorldSpace

		return origin, direction
	end,

	UpdateToNextPosition = function(point)
		return point.WorldSpace
	end,

	Visualize = function(point)
		return CFrame.lookAt(point.WorldSpace, point.LastPosition)
	end
}
local LinkAttachmentsSolver: Solver = {
	--- Solve direction and length of the ray by comparing both attachment1 and attachment2's positions
	-- @param point type
	Solve = function(point)
		local origin: Vector3 = point.Instances[1].WorldPosition
		local direction: Vector3 = point.Instances[2].WorldPosition - point.Instances[1].WorldPosition

		return origin, direction
	end,

	UpdateToNextPosition = function(point)
		return point.Instances[1].WorldPosition
	end,

	Visualize = function(point)
		return CFrame.lookAt(point.Instances[1].WorldPosition, point.Instances[2].WorldPosition)
	end
}

export type Hitbox = typeof(setmetatable({}:: {
	RaycastParams: RaycastParams?,
	DetectionMode: number,
	HitboxRaycastPoints: {[Point]: true},
	HitboxPendingRemoval: boolean,
	HitboxStopTime: number,
	HitboxObject: Instance,
	HitboxActive: boolean,
	Visualizer: boolean,
	DebugLog: boolean,
	OnUpdate: Signal.Signal,
	OnHit: Signal.Signal,
}, Hitbox))

local ActiveHitboxes: {[any]: true} = {}

--- Internal function that returns a point type
-- @param group string name
-- @param castMode numeric enum value
-- @param lastPosition Vector3 value
local function _CreatePoint(group: string?, castMode: Solver, lastPosition: Vector3?): Point
	return {
		Group = group,
		CastMode = castMode,
		LastPosition = lastPosition,
		WorldSpace = nil,
		Instances = {}
	}
end

--- Activates the raycasts for the hitbox object.
--- The hitbox will automatically stop and restart if the hitbox was already casting.
-- @param optional number parameter to automatically turn off the hitbox after 'n' seconds
function Hitbox:HitStart(seconds: number?)
	if self.HitboxActive then
		self:HitStop()
	end

	if seconds then
		self.HitboxStopTime = time() + math.max(MINIMUM_SECONDS_SCHEDULER, seconds)
	end

	self.HitboxActive = true
end

--- Disables the raycasts for the hitbox object.
--- Also automatically cancels any current time scheduling for the current hitbox.
function Hitbox:HitStop()
	self.HitboxActive = false
	self.HitboxStopTime = 0
end

--- Queues the hitbox to be destroyed in the next frame
function Hitbox:Destroy()
	self.HitboxPendingRemoval = true

	if self.HitboxObject then
		CollectionService:RemoveTag(self.HitboxObject, self.Tag)
	end

	self:HitStop()
	self.OnHit:Destroy()
	self.OnUpdate:Destroy()
end

--- Searches for attachments for the given instance (if applicable)
function Hitbox:Recalibrate()
	local descendants: {[number]: Instance} = self.HitboxObject:GetDescendants()
	local attachmentCount: number = 0

	--- Remove all previous attachments
	for point in self.HitboxRaycastPoints do
		if point.CastMode == AttachmentSolver then
			self.HitboxRaycastPoints[point] = nil
		end
	end

	for _, attachment in descendants do
		if not attachment:IsA("Attachment") or attachment.Name ~= DEFAULT_ATTACHMENT_INSTANCE then
			continue
		end

		local group: string? = attachment:GetAttribute(DEFAULT_GROUP_NAME_INSTANCE)
		local point: Point = _CreatePoint(group, AttachmentSolver, attachment.WorldPosition)

		table.insert(point.Instances, attachment)
		self.HitboxRaycastPoints[point] = true

		attachmentCount += 1
	end

	if self.DebugLog then
		print(DEFAULT_DEBUG_LOGGER_PREFIX..
			if attachmentCount ~= 0 then string.format(DEFAULT_ATTACH_COUNT_NOTICE, attachmentCount, self.HitboxObject.Name)
			else
			string.format(DEFAULT_MISSING_ATTACHMENTS, self.HitboxObject.Name))
	end
end

--- Creates a link between two attachments. The module will constantly raycast between these two attachments.
-- @param attachment1 Attachment object (can have a group attribute)
-- @param attachment2 Attachment object
function Hitbox:LinkAttachments(attachment1: Attachment, attachment2: Attachment)
	local group: string? = attachment1:GetAttribute(DEFAULT_GROUP_NAME_INSTANCE)
	local point: Point = _CreatePoint(group, LinkAttachmentsSolver)

	point.Instances[1] = attachment1
	point.Instances[2] = attachment2
	self.HitboxRaycastPoints[point] = true
end

--- Removes the link of an attachment. Putting one of any of the two original attachments you used in LinkAttachment will automatically sever the other
-- @param attachment
function Hitbox:UnlinkAttachments(attachment: Attachment)
	for point in self.HitboxRaycastPoints do
		if #point.Instances >= 2 then
			if point.Instances[1] == attachment or point.Instances[2] == attachment then
				self.HitboxRaycastPoints[point] = nil
			end
		end
	end
end

--- Creates raycast points using only vector3 values.
-- @param object BasePart or Bone, the part you want the points to be locally offset from
-- @param table of vector3 values that are in local space relative to the basePart or bone
-- @param optional group string parameter that names the group these points belong to
function Hitbox:SetPoints(object: BasePart | Bone, vectorPoints: {Vector3}, group: string?)
	for _, vector: Vector3 in vectorPoints do
		local point: Point = _CreatePoint(group, if object:IsA("Bone") then BoneSolver else Vector3Solver)

		point.Instances[1] = object
		point.Instances[2] = vector
		self.HitboxRaycastPoints[point] = true
	end
end

--- Removes raycast points using only vector3 values. Use the same vector3 table from SetPoints
-- @param object BasePart or Bone, the original instance you used for SetPoints
-- @param table of vector values that are in local space relative to the basePart
function Hitbox:RemovePoints(object: BasePart | Bone, vectorPoints: {Vector3})
	for point in self.HitboxRaycastPoints do
		local part = point.Instances[1]

		if part == object then
			local originalVector = point.Instances[2] :: Vector3

			if table.find(vectorPoints, originalVector) then
				self.HitboxRaycastPoints[point] = nil
			end
		end
	end
end

--- Finds a hitbox object if valid, else return nil
-- @param Object instance
function Hitbox.FindHitbox(object: Instance): Hitbox?
	for hitbox in ActiveHitboxes do
		if not hitbox.HitboxPendingRemoval and hitbox.HitboxObject == object then
			return hitbox
		end
	end
	return
end

DEFAULT_SIMULATION_TYPE:Connect(function()
	--- Iterate through all the hitboxes
	for hitbox in ActiveHitboxes do
		--- Skip this hitbox if the hitbox will be garbage collected this frame
		if hitbox.HitboxPendingRemoval then
			ActiveHitboxes[hitbox] = nil
			table.clear(hitbox)
			setmetatable(hitbox, nil)
			continue
		end

		for point in hitbox.HitboxRaycastPoints do
			--- Reset this point if the hitbox is inactive
			if not hitbox.HitboxActive then
				point.LastPosition = nil
				continue
			end

			--- Calculate rays
			local castMode = point.CastMode
			local origin: Vector3, direction: Vector3 = castMode.Solve(point)
			local raycastResult: RaycastResult = workspace:Raycast(origin, direction, hitbox.RaycastParams)

			--- Draw debug rays
			if hitbox.Visualizer then
				--- Create a new LineAdornmentHandle if none are in reserve
				local adornment: LineHandleAdornment? = table.remove(adornmentsInReserve)
				if not adornment then
					local line = Instance.new("LineHandleAdornment")
					line.Name = DEFAULT_DEBUGGER_RAY_NAME
					line.Color3 = DEFAULT_DEBUGGER_RAY_COLOUR
					line.Thickness = DEFAULT_DEBUGGER_RAY_WIDTH

					line.Length = 0
					line.CFrame = DEFAULT_FAR_AWAY_CFRAME

					line.Adornee = workspace.Terrain
					line.Parent = workspace.Terrain

					adornmentsLastUse[line] = 0

					adornment = line
				end
				assert(adornment) --- FOR TYPE CHECKING

				adornment.Visible = true
				adornmentsLastUse[adornment] = time()

				local debugStartPosition: CFrame = castMode.Visualize(point)
				adornment.Length = direction.Magnitude
				adornment.CFrame = debugStartPosition
			end

			--- Update the current point's position
			point.LastPosition = castMode.UpdateToNextPosition(point)

			--- If a ray detected a hit
			if raycastResult then
				local part: BasePart = raycastResult.Instance
				local model: Instance?
				local humanoid: Instance?
				local target: Instance?

				if hitbox.DetectionMode == 1 then
					model = part:FindFirstAncestorOfClass("Model")
					if model then
						humanoid = model:FindFirstChildOfClass("Humanoid")
					end
					target = humanoid
				else
					target = part
				end

				--- Found a target. Fire the OnHit event
				if target then
					hitbox.OnHit:Fire(part, humanoid, raycastResult, point.Group)
				end
			end

			--- Hitbox Time scheduler
			if hitbox.HitboxStopTime > 0 then
				if hitbox.HitboxStopTime <= time() then
					hitbox:HitStop()
				end
			end

			--- OnUpdate event that fires every frame for every point
			hitbox.OnUpdate:Fire(point.LastPosition)
		end
	end

	--- Iterates through all the debug rays to see if they need to be cached or cleaned up
	for adornment, lastUse in adornmentsLastUse do
		if (time() - lastUse) >= DEFAULT_DEBUGGER_RAY_DURATION then
			adornmentsLastUse[adornment] = nil
			adornment.Length = 0
			adornment.Visible = false
			adornment.CFrame = DEFAULT_FAR_AWAY_CFRAME
			table.insert(adornmentsInReserve, adornment)
		end
	end
end)

--- Creates or finds a hitbox object. Returns an hitbox object
-- @param required object parameter that takes in either a part or a model
function Hitbox.new(object: Instance): Hitbox
	if CollectionService:HasTag(object, DEFAULT_COLLECTION_TAG_NAME) then
		return Hitbox.FindHitbox(object)
	else
		local hitbox = setmetatable({
			RaycastParams = nil,
			DetectionMode = Hitbox.DetectionMode.PartMode,
			HitboxRaycastPoints = {},
			HitboxPendingRemoval = false,
			HitboxStopTime = 0,
			HitboxObject = object,
			HitboxActive = false,
			Visualizer = SHOW_DEBUG_RAY_LINES,
			DebugLog = SHOW_OUTPUT_MESSAGES,
			OnUpdate = Signal.new(),
			OnHit = Signal.new(),
		}, Hitbox)

		local tagConnection: RBXScriptConnection

		local function onTagRemoved(instance: Instance)
			if instance == object then
				tagConnection:Disconnect()
				hitbox:Destroy()
			end
		end

		hitbox:Recalibrate()
		ActiveHitboxes[hitbox] = true
		CollectionService:AddTag(hitbox.HitboxObject, DEFAULT_COLLECTION_TAG_NAME)

		tagConnection = CollectionService:GetInstanceRemovedSignal(DEFAULT_COLLECTION_TAG_NAME):Connect(onTagRemoved)

		return hitbox
	end
end

return Hitbox
