if SERVER then
    util.AddNetworkString("EntityInfoRequest")
    util.AddNetworkString("EntityInfoResponse")

    net.Receive("EntityInfoRequest", function(len, ply)
        local ent_index = net.ReadUInt(16)
        local ent = Entity(ent_index)
        
        if not IsValid(ent) then return end
        
        local data = {}
        data.valid = true
        data.class = ent:GetClass()
        data.model = ent:GetModel() or "No Model"
        data.pos = ent:GetPos()
        data.ang = ent:GetAngles()
        data.index = ent:EntIndex()
        
        -- Get owner info
        if ent.CPPIGetOwner and ent:CPPIGetOwner() then
            local owner = ent:CPPIGetOwner()
            data.owner = IsValid(owner) and owner:Nick() or "Unknown"
            data.owner_steamid = IsValid(owner) and owner:SteamID() or "Unknown"
        else
            data.owner = "World"
            data.owner_steamid = "N/A"
        end
        
        -- Additional properties - only include health if > 0
        local health = ent:Health()
        if ent:GetMaxHealth() > 0 and health > 0 then
            data.health = health
        end
        data.material = ent:GetMaterial() ~= "" and ent:GetMaterial() or nil
        
        net.Start("EntityInfoResponse")
        net.WriteTable(data)
        net.Send(ply)
    end)
elseif CLIENT then
    local font_scale_convar = CreateClientConVar("cl_buildhud_scale", "14", true, false)
    local alpha_convar = CreateClientConVar("cl_buildhud_alpha", "200", true, false)
    local show_entity_info = CreateClientConVar("cl_buildhud_entityinfo", "1", true, false)
    local current_scale = font_scale_convar:GetInt()
    
    local entity_info_visible = false
    local entity_info_data = nil
    local last_entity = nil
    local info_update_time = 0

    -- Helper function to count visual width of text (accounting for Cyrillic characters)
    local function get_visual_width(text)
        local visual_width = 0
        local i = 1
        while i <= #text do
            local byte = string.byte(text, i)
            if byte > 127 then
                -- Multi-byte UTF-8 character (like Cyrillic)
                if byte >= 194 and byte <= 223 then
                    i = i + 2 -- 2-byte character
                elseif byte >= 224 and byte <= 239 then
                    i = i + 3 -- 3-byte character
                elseif byte >= 240 and byte <= 244 then
                    i = i + 4 -- 4-byte character
                else
                    i = i + 1 -- Invalid UTF-8, treat as single byte
                end
                visual_width = visual_width + 1 -- Cyrillic displays as 1 character width
            else
                visual_width = visual_width + 1 -- ASCII character
                i = i + 1
            end
        end
        return visual_width
    end

    local function gen_font()
        surface.CreateFont("buildhud_monospace", {
            font = "Courier New",
            size = current_scale,
            weight = 500,
            antialias = false
        })
    end

    local function format_vector(vec)
        return string.format("%.1f, %.1f, %.1f", vec.x, vec.y, vec.z)
    end

    local function format_angle(ang)
        return string.format("%.1f, %.1f, %.1f", ang.p, ang.y, ang.r)
    end

    net.Receive("EntityInfoResponse", function()
        entity_info_data = net.ReadTable()
    end)

    local function update_entity_info()
        if not show_entity_info:GetBool() then 
            entity_info_visible = false
            return 
        end
        
        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        
        local trace = ply:GetEyeTrace()
        local ent = trace.Entity
        
        if IsValid(ent) and ent ~= game.GetWorld() then
            entity_info_visible = true
            
            -- Only request update if entity changed or enough time has passed
            if ent ~= last_entity or CurTime() - info_update_time > 0.5 then
                last_entity = ent
                info_update_time = CurTime()
                
                net.Start("EntityInfoRequest")
                net.WriteUInt(ent:EntIndex(), 16)
                net.SendToServer()
            end
        else
            entity_info_visible = false
            entity_info_data = nil
            last_entity = nil
        end
    end

    local function draw_entity_info()
        if not entity_info_visible or not entity_info_data or not entity_info_data.valid then return end
        
        -- Update font if scale changed
        if current_scale ~= font_scale_convar:GetInt() then
            current_scale = font_scale_convar:GetInt()
            gen_font()
        end
        
        surface.SetFont("buildhud_monospace")
        
        -- Prepare info lines with better precision for numbers
        local info_lines = {}
        local max_label_width = 0
        local max_value_width = 0
        
        -- Class and Index
        local class_text = entity_info_data.class .. "[" .. entity_info_data.index .. "]"
        info_lines[#info_lines + 1] = {"CLASS", class_text}
        max_label_width = math.max(max_label_width, get_visual_width("CLASS"))
        max_value_width = math.max(max_value_width, get_visual_width(class_text))
        
        -- Owner
        if entity_info_data.owner then
            info_lines[#info_lines + 1] = {"OWNER", entity_info_data.owner}
            max_label_width = math.max(max_label_width, get_visual_width("OWNER"))
            max_value_width = math.max(max_value_width, get_visual_width(entity_info_data.owner))
        end
        
        -- Position (preserve decimal precision)
        local pos_text = string.format("%.2f, %.2f, %.2f", entity_info_data.pos.x, entity_info_data.pos.y, entity_info_data.pos.z)
        info_lines[#info_lines + 1] = {"POSITION", pos_text}
        max_label_width = math.max(max_label_width, get_visual_width("POSITION"))
        max_value_width = math.max(max_value_width, get_visual_width(pos_text))
        
        -- Angles (preserve decimal precision)
        local ang_text = string.format("%.2f, %.2f, %.2f", entity_info_data.ang.p, entity_info_data.ang.y, entity_info_data.ang.r)
        info_lines[#info_lines + 1] = {"ANGLES", ang_text}
        max_label_width = math.max(max_label_width, get_visual_width("ANGLES"))
        max_value_width = math.max(max_value_width, get_visual_width(ang_text))
        
        -- Model (no shortening)
        if entity_info_data.model and entity_info_data.model ~= "No Model" then
            info_lines[#info_lines + 1] = {"MODEL", entity_info_data.model}
            max_label_width = math.max(max_label_width, get_visual_width("MODEL"))
            max_value_width = math.max(max_value_width, get_visual_width(entity_info_data.model))
        end
        
        -- Health (only if > 0)
        if entity_info_data.health then
            local health_text = tostring(entity_info_data.health)
            info_lines[#info_lines + 1] = {"HEALTH", health_text}
            max_label_width = math.max(max_label_width, get_visual_width("HEALTH"))
            max_value_width = math.max(max_value_width, get_visual_width(health_text))
        end
        
        -- Material (no shortening)
        if entity_info_data.material then
            info_lines[#info_lines + 1] = {"MATERIAL", entity_info_data.material}
            max_label_width = math.max(max_label_width, get_visual_width("MATERIAL"))
            max_value_width = math.max(max_value_width, get_visual_width(entity_info_data.material))
        end
        
        -- Calculate compact panel dimensions based on actual content
        local line_height = current_scale + 1 -- Reduced line spacing
        local padding = 8 -- Reduced padding
        local separator_width = 2 -- Space for ": " between label and value
        local char_width = current_scale * 0.6 -- Approximate character width for monospace font
        
        -- Calculate total width based on longest label + separator + longest value
        local content_width = (max_label_width + separator_width + max_value_width) * char_width
        local panel_width = content_width + padding * 2
        local panel_height = (#info_lines * line_height) + padding * 2
        
        -- Position on right side of screen
        local panel_x = ScrW() - panel_width - 20
        local panel_y = ScrH() / 2 - panel_height / 2
        
        -- Background
        local alpha = alpha_convar:GetInt()
        draw.RoundedBox(0, panel_x, panel_y, panel_width, panel_height, Color(0, 0, 0, alpha))
        
        -- Outline
        draw.RoundedBox(0, panel_x, panel_y, panel_width, 2, Color(100, 100, 100, 255)) -- Top
        draw.RoundedBox(0, panel_x, panel_y + panel_height - 2, panel_width, 2, Color(100, 100, 100, 255)) -- Bottom
        draw.RoundedBox(0, panel_x, panel_y, 2, panel_height, Color(100, 100, 100, 255)) -- Left
        draw.RoundedBox(0, panel_x + panel_width - 2, panel_y, 2, panel_height, Color(100, 100, 100, 255)) -- Right
        
        surface.SetTextColor(255, 255, 255, 255)
        
        -- Info lines with compact layout
        for i, line in ipairs(info_lines) do
            local label = line[1] .. ": "
            local value = line[2]
            
            -- Draw label
            surface.SetTextPos(panel_x + padding, panel_y + padding + (i-1) * line_height)
            surface.DrawText(label)
            
            -- Draw value immediately after label (more compact)
            local label_width = surface.GetTextSize(label)
            surface.SetTextPos(panel_x + padding + label_width, panel_y + padding + (i-1) * line_height)
            surface.DrawText(value)
        end
    end

    -- Initialize
    hook.Add("OnGamemodeLoaded", "entity_info_init", function()
        gen_font()
    end)

    -- Update entity info every frame
    hook.Add("Think", "entity_info_update", update_entity_info)

    -- Draw entity info
    hook.Add("HUDPaint", "draw_entity_info", draw_entity_info)
end 