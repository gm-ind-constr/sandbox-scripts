-- garrysmod/lua/autorun/smart_noclip.lua

--[[ [shared] smart noclip

description:
    script made to eliminate the need for !pvp or !build commands because they are UGLY,
    even though, my implementation might be more uglier, i think it's fair
    this script automates noclip availability, it's very suitable for servers
    with no rules where players don't have godmode at all.
    the best case scenario: players would start learning propsurfing and propkilling
    in attempts to be better at pvp

features (p is player):
    if p1 harms (weapon or with a prop) p2,
        p1's noclip is disabled on cooldown

    if during p1's cooldown, p2 (the victim) uses noclip,
        p1 gets compensation and their noclip would turn on faster than waiting for the whole cooldown

    if p throws a prop,
        p noclip is disabled on small cooldown

    if p dies their cooldown is removed

    cooldown types are not interfering with each other,
        for example:
        if p had previously harmed another player,
            if p throws an object with physgun,
                their cooldown would not override to a smaller cooldown

    chat print texts in chat dont repeat themselves often

    [X]
    everything is set with console variables

    physical objects chain reactions save the initiator of motion (see [1])

    ability to change settings:
    - the cooldown of PLAYER_HURT (see [2])
    - the cooldown of PLAYER_HURT_FROM_PROP (see [2])
    - the cooldown of PROP_THROW
    - how fast should prop be going to be considered as deadly?
    - compensation for other p fleeing COOLDOWN_COMPENSATION

    [1] - affected physical object on collision other regular objects will always transfer information to them and make them affected too. if player holds or throws object with a physgun that object becomes affected,
        these objects will store initiator of motion until:
        - timeout for it occurs,
        - object stops moving (goes to sleep),

    [2] - player hurt cooldown either works on weapons like crowbar or pistol, or on the props, with saved initiator of motion (see [1]),
        if p1 throws a prop directly at p2:
            if p2 dies from that:
                that would count as PLAYER_HURT_FROM_PROP
            else, p2 only got hurt, not died:
                that would count as PLAYER_HURT
        also, if instead p1 throws prop1 at prop2, while prop2 is not being held anyone after that point, it would count as PLAYER_HURT_FROM_PROP.

todo (will never do this probably):
- punish owner of the prop if nothing helped to track killer, also make it as a setting
- if object has constraints it probably is a vehicle, check for constraints if it has a seat and if they have drivers, punish every single one inside of the found seats.
- clientside prediction would be nice,
    possible events for clientside prediction:
    - prop throwing with physgun,
    - prop throwing with gravgun,
    - attacking a player
]]

local REASON = {
    PLAYER_HURT = 1,
    COOLDOWN_ENDED = 2,
    COOLDOWN_COMPENSATION = 3,
    DOOMED_SITUATION = 4,
    PROP_THROW = 5,
    PLAYER_HURT_FROM_PROP = 6
}
if SERVER then
    -- settings:
    local COOLDOWNS = {
        [REASON.PLAYER_HURT] = 8,
        [REASON.PLAYER_HURT_FROM_PROP] = 8,
        [REASON.PROP_THROW] = 3,
        [REASON.COOLDOWN_COMPENSATION] = 2
    }
    local deadly_prop_speed = 500

    util.AddNetworkString("smart_noclip_sync")
    util.AddNetworkString("smart_noclip_msg")
    local function let_client_know(ply)
        net.Start("smart_noclip_sync")
        net.WriteBool(ply.can_noclip)
        net.Send(ply)
    end
    local function send_message(ply, msg_index)
        net.Start("smart_noclip_msg")
        net.WriteInt(msg_index, 8)
        net.Send(ply)
    end
    local function is_player_unstuck(ply)
        if not IsValid(ply) then return false end
        if not ply:IsPlayer() then return false end
        if not ply:Alive() then return false end
        local pos = ply:GetPos()
        if not util.IsInWorld(pos) then return false end
        local mins, maxs = ply:GetHull()
        local trace = {
            start = pos,
            endpos = pos,
            mins = mins,
            maxs = maxs,
            filter = ply
        }
        local tr = util.TraceHull(trace)
        if tr.StartSolid then return false end
        return true
    end
    local function set_noclip_cooldown(ply, new_reason)
        local cooldown = COOLDOWNS[new_reason]
        if ply.can_noclip == nil then ply.can_noclip = false end
        if ply.can_noclip == true then
            ply.can_noclip = false
            let_client_know(ply)
        end
        local old_reason = ply.cooldown_reason
        local old_cooldown = ply.noclip_cooldown
        if old_reason == nil then
            old_reason = REASON.COOLDOWN_ENDED
        end
        if old_reason == new_reason and
            new_reason ~= REASON.COOLDOWN_COMPENSATION and
            new_reason ~= REASON.COOLDOWN_ENDED then
            ply.noclip_cooldown = cooldown
            return
        end
        if old_reason == REASON.COOLDOWN_ENDED and new_reason == REASON.PROP_THROW then
            ply.noclip_cooldown = cooldown
            ply.cooldown_reason = new_reason
            send_message(ply, new_reason)
            return
        end
        if new_reason == REASON.PLAYER_HURT or new_reason == REASON.PLAYER_HURT_FROM_PROP then
            ply.noclip_cooldown = cooldown
            ply.cooldown_reason = new_reason
            if old_reason ~= REASON.PLAYER_HURT and old_reason ~= REASON.PLAYER_HURT_FROM_PROP then
                if not is_player_unstuck(ply) then
                    send_message(ply, REASON.DOOMED_SITUATION)
                else
                    send_message(ply, new_reason)
                end
            end
            return
        end
        if old_reason == REASON.COOLDOWN_ENDED or old_reason == REASON.COOLDOWN_COMPENSATION then
            if not is_player_unstuck(ply) then
                send_message(ply, REASON.DOOMED_SITUATION)
            end
            ply.cooldown_reason = new_reason
            ply.noclip_cooldown = cooldown
            return
        end
        if old_cooldown <= cooldown then
            ply.cooldown_reason = new_reason
            ply.noclip_cooldown = cooldown
            send_message(ply, new_reason)
            return
        end
        if (old_reason == REASON.PLAYER_HURT or
                old_reason == REASON.PLAYER_HURT_FROM_PROP) and
            new_reason == REASON.COOLDOWN_COMPENSATION then
            if old_cooldown < cooldown then return end
            ply.cooldown_reason = new_reason
            ply.noclip_cooldown = cooldown
            send_message(ply, REASON.COOLDOWN_COMPENSATION)
            return
        end
    end
    local affected_ents = {}
    local function remove_physics_callback(ent)
        if not ent.phys_collide_callback then return end
        ent:RemoveCallback("PhysicsCollide", ent.phys_collide_callback)
        affected_ents[ent:EntIndex()] = nil
        ent.phys_collide_callback = nil
    end
    local function add_physics_callback(ent, initiator)
        if ent.phys_collide_callback == nil then
            ent.throw_initiator = initiator
            ent.phys_collide_callback = ent:AddCallback("PhysicsCollide", function(our_ent, data)
                if data.HitEntity:GetPhysicsObject():IsMotionEnabled() and not data.HitEntity:IsPlayer() then
                    add_physics_callback(data.HitEntity, our_ent.throw_initiator)
                end
            end)
            affected_ents[ent:EntIndex()] = ent
        end
    end
    hook.Add("Tick", "smart_noclip_tick", function()
        local players = player.GetAll()
        for _, ply in pairs(players) do
            if ply:GetMoveType() == MOVETYPE_NOCLIP then
                if ply.can_noclip == false then
                    ply:SetMoveType(MOVETYPE_WALK)
                end
            end
            if ply.noclip_cooldown == nil then continue end
            if ply.noclip_cooldown >= 0 then
                ply.noclip_cooldown = ply.noclip_cooldown - FrameTime()
            end
            if ply.noclip_cooldown < 0 then
                if ply.can_noclip == false then
                    ply.can_noclip = true
                    let_client_know(ply)
                    ply.cooldown_reason = REASON.COOLDOWN_ENDED
                    send_message(ply, REASON.COOLDOWN_ENDED)
                    if ply.murder_attempt_on ~= nil then
                        if ply.murder_attempt_on.was_attacked_by == ply then
                            ply.murder_attempt_on.was_attacked_by = nil
                        end
                    end
                    ply.murder_attempt_on = nil
                end
            end
        end
        for _, ent in pairs(affected_ents) do
            if not IsValid(ent) then continue end
            local phys_obj = ent:GetPhysicsObject()
            if IsValid(phys_obj) then
                if phys_obj:IsAsleep() or
                    --ent:GetVelocity():Length() < deadly_prop_speed or
                    (not ent:IsPlayerHolding() and not phys_obj:IsMotionEnabled()) then
                    remove_physics_callback(ent)
                end
            end
        end
    end)
    hook.Add("PhysgunPickup", "smart_noclip_prop_pickup", function(ply, ent)
        add_physics_callback(ent, ply)
    end)
    hook.Add("GravGunPunt", "smart_noclip_prop_punt", function(ply, ent)
        add_physics_callback(ent, ply)
        set_noclip_cooldown(ply, REASON.PROP_THROW)
    end)
    hook.Add("PhysgunDrop", "smart_noclip_prop_drop", function(ply, ent)
        timer.Simple(0, function()
            if IsValid(ent) then
                if ent:GetVelocity():Length() > deadly_prop_speed then
                    add_physics_callback(ent, ply)
                    set_noclip_cooldown(ply, REASON.PROP_THROW)
                end
            end
        end)
    end)
    local function player_death(victim, inflictor)
        if not IsValid(victim) then return end
        if not IsValid(inflictor) then return end
        if victim:IsPlayer() then
            if victim.was_attacked_by ~= nil then
                if victim.was_attacked_by.murder_attempt_on == victim then
                    victim.was_attacked_by.murder_attempt_on = nil
                end
            end
            victim.was_attacked_by = nil
            if victim.noclip_cooldown ~= nil then
                victim.noclip_cooldown = 0
            end
            if victim.cooldown_reason ~= nil then
                victim.cooldown_reason = REASON.COOLDOWN_ENDED
            end
            local phys_obj = inflictor:GetPhysicsObject()
            if not IsValid(phys_obj) then return end
            if phys_obj:IsMotionEnabled() then
                if inflictor.throw_initiator == nil then return end
                if inflictor.throw_initiator ~= victim then
                    set_noclip_cooldown(inflictor.throw_initiator, REASON.PLAYER_HURT_FROM_PROP)
                end
            end
        end
    end
    hook.Add("PlayerDeath", "smart_noclip_ply_death", player_death)
    hook.Add("PlayerHurt", "smart_noclip_ply_hurt", function(victim, attacker, health)
        --if health <= 0 then
        --    player_death(victim, attacker)
        --    return
        --end
        if not IsValid(victim) then return end
        if not IsValid(attacker) then return end
        if victim:IsPlayer() then
            if attacker:IsPlayer() then
                if victim ~= attacker then
                    victim.was_attacked_by = attacker
                    attacker.murder_attempt_on = victim
                    set_noclip_cooldown(attacker, REASON.PLAYER_HURT)
                end
            else
                local phys_obj = attacker:GetPhysicsObject()
                if not IsValid(phys_obj) then return end
                if phys_obj:IsMotionEnabled() then
                    if attacker.throw_initiator == nil then return end
                    if attacker.throw_initiator ~= victim then
                        if attacker.throw_initiator ~= nil then
                            victim.was_attacked_by = attacker.throw_initiator
                            attacker.throw_initiator.murder_attempt_on = victim
                            set_noclip_cooldown(attacker.throw_initiator, REASON.PLAYER_HURT_FROM_PROP)
                        end
                    end
                end
            end
        end
    end)
    hook.Add("EntityRemoved", "smart_noclip_ent_removed", function(ent)
        remove_physics_callback(ent)
    end)
    hook.Add("PlayerNoClip", "a", function(ply, desired)
        if ply.can_noclip == nil then
            return true
        end
        if desired then
            if ply.was_attacked_by ~= nil then
                local attacker = ply.was_attacked_by
                local reason = attacker.cooldown_reason
                ply.was_attacked_by = nil
                if reason ~= nil then
                    if reason == REASON.PLAYER_HURT or
                        reason == REASON.PLAYER_HURT_FROM_PROP then
                        set_noclip_cooldown(attacker, REASON.COOLDOWN_COMPENSATION)
                    end
                end
            end
        end
        return ply.can_noclip
    end)
elseif CLIENT then
    local silence_prints_convar = CreateClientConVar("cl_noclip_silence_prints", "0", true, false,
        "Silence Smart Noclip chat notifications")
    hook.Add("PopulateToolMenu", "smart_noclip", function()
        spawnmenu.AddToolMenuOption("Utilities", "User", "smart_noclip", "#Noclip preferences", "", "", function(panel)
            panel:CheckBox("Silence Noclip chat prints", "cl_noclip_silence_prints")
        end)
    end)
    local lang_convar = GetConVar("gmod_language")
    local prefix = "[NOCLIP]"
    local reason_to_msg = {
        ["ru"] = {
            [REASON.PLAYER_HURT] = "Вы навредили другому Игроку, Noclip был выключен",
            [REASON.COOLDOWN_ENDED] = "Noclip снова доступен",
            [REASON.COOLDOWN_COMPENSATION] = "Игрок которому вы навредили - улетел, Noclip скоро будет включен",
            [REASON.DOOMED_SITUATION] =
            "Вы навредили другому Игроку находясь за пределами карты, теперь довольствуйтесь этой проклятой ситуацией которую сами и создали",
            [REASON.PROP_THROW] = "Вы кинули предмет, Noclip был выключен",
            [REASON.PLAYER_HURT_FROM_PROP] = "Ваш предмет навредил другому игроку, Noclip был выключен"
        },
        ["en"] = {
            [REASON.PLAYER_HURT] = "You have hurt another Player, Noclip was disabled",
            [REASON.COOLDOWN_ENDED] = "Noclip is now available to use",
            [REASON.COOLDOWN_COMPENSATION] = "Player that You have hurt - fleed, Noclip soon will be enabled",
            [REASON.DOOMED_SITUATION] =
            "You have hurt another Player while being out of bounds, now, admire this doomed situation that you have created",
            [REASON.PROP_THROW] = "You have thrown an object, Noclip was disabled",
            [REASON.PLAYER_HURT_FROM_PROP] = "Your object hurt another Player, Noclip was disabled"
        }
    }
    -- will prevent clientside prediction errors only when synced
    -- which is not nice but i mean it's atleast something
    local can_noclip = true
    net.Receive("smart_noclip_sync", function()
        can_noclip = net.ReadBool()
    end)
    net.Receive("smart_noclip_msg", function()
        local reason = net.ReadInt(8)
        if silence_prints_convar:GetBool() then
            return
        end
        local lang = "en"
        local target = lang_convar:GetString()
        if table.HasValue(table.GetKeys(reason_to_msg), target) then lang = target end
        local to_print = prefix .. " " .. reason_to_msg[lang][reason]
        LocalPlayer():ChatPrint(to_print)
    end)
    hook.Add("PlayerNoClip", "a", function()
        return can_noclip
    end)
end
