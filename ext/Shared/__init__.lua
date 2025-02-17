GameObjectOriginType = {
	Vanilla = 1,
	Custom = 2,
	CustomChild = 3
}

-- This is a global table that stores the save file data as a Lua table. Will be populated on-demand by
-- the server via NetEvents on the client-side
g_CustomLevelData = nil

-- Stores LevelData DataContainer guids.
local m_CustomLevelData = nil

local m_IndexCount = 0
local m_OriginalLevelIndeces = {}
local m_LastLoadedMap = nil
local m_ObjectVariations = {}
local m_PendingVariations = {}

local function PatchOriginalObject(p_Object, p_World)
	if p_Object.originalRef == nil then
		print("Object without original reference found, dynamic object?")
		return
	end
	local s_Reference = nil
	if p_Object.originalRef.partitionGuid == nil or p_Object.originalRef.partitionGuid == "nil" then -- perform a search without partitionguid
		 s_Reference = ResourceManager:SearchForInstanceByGuid(Guid(p_Object.originalRef.instanceGuid))
		 if s_Reference == nil then
		 	print("Unable to find original reference: " .. p_Object.originalRef.instanceGuid)
		 	return
		 end
	else
		 s_Reference = ResourceManager:FindInstanceByGuid(Guid(p_Object.originalRef.partitionGuid), Guid(p_Object.originalRef.instanceGuid))
		 if s_Reference == nil then
		 	print("Unable to find original reference: " .. p_Object.originalRef.instanceGuid .. " in partition " .. p_Object.originalRef.partitionGuid)
		 	return
		 end
	end
	s_Reference = _G[s_Reference.typeInfo.name](s_Reference)
	s_Reference:MakeWritable()
	if p_Object.isDeleted then
		s_Reference.excluded = true
	end
	if p_Object.localTransform then
		s_Reference.blueprintTransform = LinearTransform(p_Object.localTransform) -- LinearTransform(p_Object.localTransform)
	else
		s_Reference.blueprintTransform = LinearTransform(p_Object.transform) -- LinearTransform(p_Object.transform)
	end
end

local function AddCustomObject(p_Object, p_World, p_RegistryContainer)
	local s_Blueprint = ResourceManager:FindInstanceByGuid(Guid(p_Object.blueprintCtrRef.partitionGuid), Guid(p_Object.blueprintCtrRef.instanceGuid))
	if s_Blueprint == nil then
		print('Cannot find blueprint with guid ' .. tostring(p_Object.blueprintCtrRef.instanceGuid))
	end

	-- Filter BangerEntityData.
	if s_Blueprint:Is('ObjectBlueprint') then
		local s_ObjectBlueprint = ObjectBlueprint(s_Blueprint)
		if s_ObjectBlueprint.object and s_ObjectBlueprint.object:Is('BangerEntityData') then
			return
		end
	end


	local s_Reference
	if s_Blueprint:Is('EffectBlueprint') then
		s_Reference = EffectReferenceObjectData()
		s_Reference.autoStart = true
	else
		s_Reference = ReferenceObjectData()
	end

	p_RegistryContainer.referenceObjectRegistry:add(s_Reference)
	if p_Object.localTransform then
		s_Reference.blueprintTransform = LinearTransform(p_Object.localTransform)
	else
		s_Reference.blueprintTransform = LinearTransform(p_Object.transform)
	end
	--print("AddCustomObject: " .. p_Object.transform)
	s_Reference.blueprint = Blueprint(s_Blueprint)
	-- s_Reference.blueprint:MakeWritable()

	if m_ObjectVariations[p_Object.variation] == nil then
		m_PendingVariations[p_Object.variation] = s_Reference
	else
		s_Reference.objectVariation = m_ObjectVariations[p_Object.variation]
	end
	s_Reference.indexInBlueprint = #p_World.objects + m_IndexCount + 1
	s_Reference.isEventConnectionTarget = Realm.Realm_None
	s_Reference.isPropertyConnectionTarget = Realm.Realm_None
	s_Reference.excluded = false

	p_World.objects:add(s_Reference)
end

local function CreateWorldPart(p_PrimaryLevel, p_RegistryContainer)
	local s_World = WorldPartData()
	p_RegistryContainer.blueprintRegistry:add(s_World)

	--find index
	for _, l_Object in pairs(p_PrimaryLevel.objects) do
		if l_Object:Is('WorldPartReferenceObjectData') then
			local l_RefObjectData = WorldPartReferenceObjectData(l_Object)
			if l_RefObjectData.blueprint:Is('WorldPartData') then
				local s_WorldPart = WorldPartData(l_RefObjectData.blueprint)
				if #s_WorldPart.objects ~= 0 then
					local s_ROD = s_WorldPart.objects[#s_WorldPart.objects] -- last one in array
					if s_ROD and s_ROD:Is('ReferenceObjectData') then
						s_ROD = ReferenceObjectData(s_ROD)
						if s_ROD.indexInBlueprint > m_IndexCount then
							m_IndexCount = s_ROD.indexInBlueprint
						end
					end
				end
			end
		end
	end
	-- m_IndexCount = 30000
	print('Index count is: '..tostring(m_IndexCount))

	for _, l_Object in pairs(g_CustomLevelData.data) do
		if l_Object.origin == GameObjectOriginType.Custom then
			if not g_CustomLevelData.vanillaOnly then
				AddCustomObject(l_Object, s_World, p_RegistryContainer)
			end
		elseif l_Object.origin == GameObjectOriginType.Vanilla then
			PatchOriginalObject(l_Object, s_World)
		end
		-- TODO handle CustomChild
	end
	m_LastLoadedMap = SharedUtils:GetLevelName()

	local s_WorldPartReference = WorldPartReferenceObjectData()
	s_WorldPartReference.blueprint = s_World

	s_WorldPartReference.isEventConnectionTarget = Realm.Realm_None
	s_WorldPartReference.isPropertyConnectionTarget = Realm.Realm_None
	s_WorldPartReference.excluded = false

	return s_WorldPartReference
end

-- nº 1 in calling order
Events:Subscribe('Level:LoadResources', function()
	print("-----Loading resources")
	m_ObjectVariations = {}
	m_PendingVariations = {}
end)

-- nº 2 in calling order
Events:Subscribe('Partition:Loaded', function(p_Partition)
	if p_Partition == nil then
		return
	end

	local s_PrimaryInstance = p_Partition.primaryInstance

	if s_PrimaryInstance == nil then
		print('Instance is null?')
		return
	end
	-- if l_Instance:Is("Blueprint") then
		--print("-------"..Blueprint(l_Instance).name)
	-- end
	if s_PrimaryInstance.typeInfo.name == "LevelData" then
		local s_Instance = LevelData(s_PrimaryInstance)
		if (s_Instance.name == SharedUtils:GetLevelName()) then
			print("----Registering PrimaryLevel guids")
			s_Instance:MakeWritable()

			m_CustomLevelData = {
				instanceGuid = s_Instance.instanceGuid,
				partitionGuid = s_Instance.partitionGuid
			}
			if (SharedUtils:IsClientModule()) then
				NetEvents:Send('MapLoader:GetLevel')
			end
		end
	elseif s_PrimaryInstance:Is('ObjectVariation') then
		-- Store all variations in a map.
		local s_Variation = ObjectVariation(s_PrimaryInstance)
		m_ObjectVariations[s_Variation.nameHash] = s_Variation
		if m_PendingVariations[s_Variation.nameHash] ~= nil then
			for _, l_Object in pairs(m_PendingVariations[s_Variation.nameHash]) do
				l_Object.objectVariation = s_Variation
			end

			m_PendingVariations[s_Variation.nameHash] = nil
		end
	end
end)

-- nº 3 in calling order
Events:Subscribe('Level:LoadingInfo', function(p_Info)
	if p_Info == "Registering entity resources" then
		print("-----Loading Info - Registering entity resources")

		if not g_CustomLevelData then
			print("No custom level specified.")
			return
		end

		if m_CustomLevelData == nil then
			print("m_CustomLevelData is nil, something went wrong")
			return
		end

		local s_PrimaryLevel = ResourceManager:FindInstanceByGuid(m_CustomLevelData.partitionGuid, m_CustomLevelData.instanceGuid)

		if s_PrimaryLevel == nil then
			print("Couldn\'t find PrimaryLevel DataContainer, aborting")
			return
		end

		s_PrimaryLevel = LevelData(s_PrimaryLevel)

		if m_LastLoadedMap == SharedUtils:GetLevelName() then
			print('Same map loading, skipping')
			return
		end

		print("Patching level")
		local s_RegistryContainer = s_PrimaryLevel.registryContainer
		if s_RegistryContainer == nil then
			print('No registryContainer found, this shouldn\'t happen')
		end
		s_RegistryContainer = RegistryContainer(s_RegistryContainer)
		s_RegistryContainer:MakeWritable()

		local s_WorldPartReference = CreateWorldPart(s_PrimaryLevel, s_RegistryContainer)

		s_WorldPartReference.indexInBlueprint = #s_PrimaryLevel.objects

		s_PrimaryLevel.objects:add(s_WorldPartReference)

		-- Save original indeces in case LevelData has to be reset to default state later.
		m_OriginalLevelIndeces = {
			objects = #s_PrimaryLevel.objects,
			ROFs = #s_RegistryContainer.referenceObjectRegistry,
			blueprints = #s_RegistryContainer.blueprintRegistry,
			entity = #s_RegistryContainer.entityRegistry
		}
		s_RegistryContainer.referenceObjectRegistry:add(s_WorldPartReference)
		print('Level patched')
	end
end)

-- Remove all DataContainer references and reset vars
Events:Subscribe('Level:Destroy', function()
	m_ObjectVariations = {}
	m_PendingVariations = {}
	m_IndexCount = 0

	-- TODO: remove all custom objects from level registry and leveldata if next round is
	-- the same map but a different save, once that is implemented. If it's a different map
	-- there is no need to clear anything, as the leveldata will be unloaded and a new one loaded
end)