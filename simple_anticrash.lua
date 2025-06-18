-- garrysmod/lua/autorun/simple_anticrash.lua

--[[ [shared] simple anticrash

thanks Iced Coffee for inspiration from
https://github.com/propkilldb/propkill/blob/master/gamemode/server/antilag.lua

description:
    simple anti crash logic that works by accumulating the stress of physical objects

features:
    prop freezes,
    prop emits a sound
    settings available in Context Menu -> Utilities -> Admin -> Anti-Crash settings

TODO:
- sv_anticrash_action nocollide/sleep/pull apart
]]

if SERVER then
    -- settings:
    local enabled_convar = CreateConVar("sv_anticrash_enabled", "1", FCVAR_ARCHIVE, "bool")
    local max_collision_score_convar = CreateConVar("sv_anticrash_max_collision_score", "10000", FCVAR_ARCHIVE, "float")
    local max_penetration_score_convar = CreateConVar("sv_anticrash_max_penetration_score", "5000", FCVAR_ARCHIVE,
        "float")
    local max_collisions_convar = CreateConVar("sv_anticrash_max_collisions_count", "5", FCVAR_ARCHIVE, "int")
    local collision_factor_convar = CreateConVar("sv_anticrash_collision_factor", "1.0", FCVAR_ARCHIVE, "float")
    local penetration_factor_convar = CreateConVar("sv_anticrash_penetration_factor", "1.0", FCVAR_ARCHIVE, "float")

    local enabled = enabled_convar:GetBool()
    local max_collision_score = max_collision_score_convar:GetFloat()
    local max_penetration_score = max_penetration_score_convar:GetFloat()
    local max_collisions_count = max_collisions_convar:GetInt()
    local collision_factor = collision_factor_convar:GetFloat()
    local penetration_factor = penetration_factor_convar:GetFloat()

    local vertex_cache = {}

    local function GetVertexCount(ent)
        if not IsValid(ent) then return 0 end

        if ent.anticrash_vertexcount then
            return ent.anticrash_vertexcount
        end

        local model = ent:GetModel()
        if model == nil then return 0 end

        if vertex_cache[model] then
            ent.anticrash_vertexcount = vertex_cache[model]
            return ent.anticrash_vertexcount
        end

        --if ent:GetPhysicsObjectCount() == 0 and ent.CreationTick == engine.TickCount() then
        --    return 1
        --end

        local vertex_count = 0
        local phys

        for i = 0, ent:GetPhysicsObjectCount() - 1 do
            phys = ent:GetPhysicsObjectNum(i)
            vertex_count = vertex_count + #(phys:GetMeshConvexes() or {})
        end

        vertex_cache[model] = vertex_count
        ent.anticrash_vertexcount = vertex_count

        return vertex_count
    end

    local function defuse_entity(ent)
        ent.anticrash_phys_obj:EnableMotion(false)
        ent.anticrash_collision_score = 0
        ent.anticrash_penetration_score = 0
        ent.anticrash_collisions_count = 0
        ent:EmitSound("ambient/levels/canals/windchime" .. math.random(4, 5) .. ".wav")
    end

    local function ent_anticrash(ent, data)
        if not enabled then return end
        local hit = data.HitEntity
        if hit == Entity(0) then return end
        if not IsValid(ent) then return end
        if hit:IsPlayer() then return end
        if ent:IsPlayer() then return end
        if not ent.anticrash_phys_obj:IsMotionEnabled() then return end
        local time = RealTime()
        if ent.anticrash_last_collision_time ~= time then
            ent.anticrash_collisions_count = 0
            ent.anticrash_collision_score = 0
            ent.anticrash_penetration_score = 0
        end
        ent.anticrash_last_collision_time = time
        ent.anticrash_collisions_count = ent.anticrash_collisions_count + 1
        ent.anticrash_collision_score = ent.anticrash_collision_score +
            (1 + ent.anticrash_vertexcount * collision_factor)
        if ent.anticrash_phys_obj:IsPenetrating() then
            ent.anticrash_penetration_score = ent.anticrash_penetration_score +
                (1 + ent.anticrash_vertexcount * penetration_factor)
        end
        if (max_collisions_count > 0 and ent.anticrash_collisions_count >= max_collisions_count) or
            max_collision_score < ent.anticrash_collision_score or
            max_penetration_score < ent.anticrash_penetration_score then
            defuse_entity(ent)
        end
    end
    hook.Add("Tick", "anticrash_get_cvars", function()
        enabled = enabled_convar:GetBool()
        if not enabled then return end
        max_collision_score = max_collision_score_convar:GetFloat()
        max_penetration_score = max_penetration_score_convar:GetFloat()
        max_collisions_count = max_collisions_convar:GetInt()
        collision_factor = collision_factor_convar:GetFloat()
        penetration_factor = penetration_factor_convar:GetFloat()
    end)

    hook.Add("OnEntityCreated", "anticrash_entity_created", function(ent)
        timer.Simple(0, function()
            if IsValid(ent) then
                local phys_obj = ent:GetPhysicsObject()
                if IsValid(phys_obj) then
                    ent.anticrash_collisions_count = 0
                    ent.anticrash_collision_score = 0
                    ent.anticrash_penetration_score = 0
                    ent.anticrash_last_collision_time = RealTime()
                    ent.anticrash_phys_obj = phys_obj
                    ent.anticrash_vertexcount = GetVertexCount(ent)
                    ent:AddCallback("PhysicsCollide", ent_anticrash)
                end
            end
        end)
    end)
elseif CLIENT then
    hook.Add("PopulateToolMenu", "simple_anticrash", function()
        spawnmenu.AddToolMenuOption("Utilities", "Admin", "admin_anticrash", "#Anti-Crash settings", "", "",
            function(panel)
                syncCheckbox(panel, "Enabled", "sv_anticrash_enabled")
                panel:Help("Maximum collisions per tick (0 = disabled)")
                syncIntSlider(panel, "sv_anticrash_max_collisions_count", 0, 20)
                panel:Help("Mesh complexity factor on collision score")
                syncSlider(panel, "sv_anticrash_collision_factor", 0, 1)
                panel:Help("Mesh complexity factor on penetration score")
                syncSlider(panel, "sv_anticrash_penetration_factor", 0, 1)
                panel:Help("Maximum collision score")
                syncSlider(panel, "sv_anticrash_max_collision_score", 1, 100000)
                panel:Help("Maximum penetration score")
                syncSlider(panel, "sv_anticrash_max_penetration_score", 1, 50000)
            end)
    end)
end
