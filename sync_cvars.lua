if SERVER then
    util.AddNetworkString("sv_cvar_change")
    util.AddNetworkString("cl_cvar_update")
    util.AddNetworkString("sv_request_cvar_value")

    local function on_sv_cvar_change(len, ply)
        local cvar_name = net.ReadString()
        local cvar_value = net.ReadString()
    
        local cvar = GetConVar(cvar_name)
        if cvar and ply:GetUserGroup() == "superadmin" then
            local type = cvar:GetHelpText()
            if type == "bool" then
                cvar:SetBool(tobool(cvar_value))
            elseif type == "float" then
                cvar:SetFloat(tonumber(cvar_value))
            elseif type == "int" then
                cvar:SetInt(tonumber(cvar_value))
            end
            net.Start("cl_cvar_update")
                net.WriteString(cvar_name)
                net.WriteString(cvar_value)
            net.Broadcast()
        end
    end
    net.Receive("sv_cvar_change", on_sv_cvar_change)

    local function on_sv_request_cvar_value(len, ply)
        local cvar_name = net.ReadString()
        local cvar = GetConVar(cvar_name)
        if cvar then
            local value = ""
            local type = cvar:GetHelpText()
            if type == "bool" then
                value = tostring(cvar:GetBool())
            elseif type == "float" then
                value = tostring(cvar:GetFloat())
            elseif type == "int" then
                value = tostring(cvar:GetInt())
            end
            net.Start("cl_cvar_update")
                net.WriteString(cvar_name)
                net.WriteString(value)
            net.Send(ply)
        end
    end
    net.Receive("sv_request_cvar_value", on_sv_request_cvar_value)

elseif CLIENT then
    sync_elems = sync_elems or {}

    net.Receive("cl_cvar_update", function ()
        local cmd = net.ReadString()
        local val = net.ReadString()
        for _, v in pairs(sync_elems[cmd] or {}) do
            if v:GetName() == "checkbox" then
                v:SetChecked(tobool(val))
            elseif v:GetName() == "slider" then
                if v:IsEditing() then return end
                v:SetValue(tonumber(val))
            end
        end
    end)

    function syncCheckbox(panel, label, cmd)
        if sync_elems[cmd] == nil then
            sync_elems[cmd] = {}
        end
        local elem = panel:CheckBox(label, cmd)
        elem.OnChange = function(self, value)
            net.Start("sv_cvar_change")
            net.WriteString(cmd)
            net.WriteString(tostring(value))
            net.SendToServer()
        end
        elem:SetName("checkbox")
        sync_elems[cmd][#sync_elems[cmd] + 1] = elem

        net.Start("sv_request_cvar_value")
        net.WriteString(cmd)
        net.SendToServer()
    end

    function syncSlider(panel, cmd, min, max)
        if sync_elems[cmd] == nil then
            sync_elems[cmd] = {}
        end
        local elem = panel:NumSlider("", cmd, min, max)
        elem.OnValueChanged = function(self, value)
            if elem:IsEditing() ~= true then return end
            net.Start("sv_cvar_change")
            net.WriteString(cmd)
            net.WriteString(tostring(value)) 
            net.SendToServer()
        end
        elem:SetName("slider")
        sync_elems[cmd][#sync_elems[cmd] + 1] = elem

        net.Start("sv_request_cvar_value")
        net.WriteString(cmd)
        net.SendToServer()
    end

    function syncIntSlider(panel, cmd, min, max)
        if sync_elems[cmd] == nil then
            sync_elems[cmd] = {}
        end
        local elem = panel:NumSlider("", cmd, min, max, 0)
        elem.OnValueChanged = function(self, value)
            if elem:IsEditing() ~= true then return end
            net.Start("sv_cvar_change")
            net.WriteString(cmd)
            net.WriteString(tostring(math.floor(value))) 
            net.SendToServer()
        end
        elem:SetName("slider")
        sync_elems[cmd][#sync_elems[cmd] + 1] = elem

        net.Start("sv_request_cvar_value")
        net.WriteString(cmd)
        net.SendToServer()
    end
end
