if SERVER then
    util.AddNetworkString("ScoreUpdate")
    util.AddNetworkString("FreezeProps")
    util.AddNetworkString("DeleteProps")
    util.AddNetworkString("ServerInfoUpdate")

    -- Player statistics tracking
    local player_stats = {}

    -- Server info from external JSON file
    local external_server_info = {
        cpu_usage = 0,
        mem_used = 0
    }

    local function ReadExternalServerInfo()
        local file_path = "server_info.json"
        if file.Exists(file_path, "DATA") then
            local content = file.Read(file_path, "DATA")
            if content then
                local success, data = pcall(util.JSONToTable, content)
                if success and data then
                    external_server_info = {
                        cpu_usage = data.cpu_usage or external_server_info.cpu_usage,
                        mem_used = data.mem_used or external_server_info.mem_used
                    }
                    --PrintMessage(HUD_PRINTTALK, data.cpu_usage .. "  -  " .. data.mem_used)
                end
            end
        end
    end

    local function InitPlayerStats(ply)
        local steamid = ply:SteamID()
        if not player_stats[steamid] then
            player_stats[steamid] = {
                kills = 0,
                deaths = 0
            }
        end
    end
 
    local function CountPlayerProps(ply)
        local props_active = 0
        local props_frozen = 0
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and ent:GetClass() == "prop_physics" then
                if ent.CPPIGetOwner and ent:CPPIGetOwner() == ply then
                    local phys = ent:GetPhysicsObject()
                    if IsValid(phys) then
                        if phys:IsMotionEnabled() then
                            props_active = props_active + 1
                        else
                            props_frozen = props_frozen + 1
                        end
                    end
                end
            end
        end
        return props_active, props_frozen
    end

    local function CountPlayerConstraints(ply)
        local constraints_active = 0
        local constraints_frozen = 0
        do return constraints_active, constraints_frozen end
        local counted_constraints = {}
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and ent:GetClass() == "prop_physics" then
                if ent.CPPIGetOwner and ent:CPPIGetOwner() == ply then
                    local constraints = constraint.GetAllConstrainedEntities(ent)
                    for _, constrained_ent in pairs(constraints) do
                        if IsValid(constrained_ent) and constrained_ent ~= ent then
                            local constraint_list = constraint.FindConstraints(ent, "")
                            for _, constraint_data in pairs(constraint_list) do
                                local constraint_id = tostring(constraint_data.Constraint)
                                if not counted_constraints[constraint_id] then
                                    counted_constraints[constraint_id] = true

                                    -- Check if constraint involves frozen props
                                    local ent1_frozen = false
                                    local ent2_frozen = false

                                    if IsValid(constraint_data.Ent1) then
                                        local phys1 = constraint_data.Ent1:GetPhysicsObject()
                                        if IsValid(phys1) then
                                            ent1_frozen = not phys1:IsMotionEnabled()
                                        end
                                    end

                                    if IsValid(constraint_data.Ent2) then
                                        local phys2 = constraint_data.Ent2:GetPhysicsObject()
                                        if IsValid(phys2) then
                                            ent2_frozen = not phys2:IsMotionEnabled()
                                        end
                                    end

                                    if ent1_frozen or ent2_frozen then
                                        constraints_frozen = constraints_frozen + 1
                                    else
                                        constraints_active = constraints_active + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return constraints_active, constraints_frozen
    end

    local function SendRealData()
        local parts = {}
        for _, ply in ipairs(player.GetAll()) do
            local steamid = ply:SteamID()
            InitPlayerStats(ply)

            local nick = ply:Nick():gsub(";", "?")
            local kills = player_stats[steamid].kills
            local deaths = player_stats[steamid].deaths
            local props_active, props_frozen = CountPlayerProps(ply)
            local constraints_active, constraints_frozen = CountPlayerConstraints(ply)
            local ping = ply:Ping()
            local loss = ply:PacketLoss()

            -- Send server info along with first player (or create separate network message)
            local server_info_str = ""
            if _ == 1 then -- First player
                server_info_str = string.format("%.1f,%d",
                    external_server_info.cpu_usage,
                    external_server_info.mem_used
                )
                print("SERVER: Sending server info: " .. server_info_str)
            end

            parts[#parts + 1] = table.concat({
                steamid, kills, deaths,
                props_active, props_frozen,
                constraints_active, constraints_frozen,
                ping, loss, nick, server_info_str
            }, ",")
        end

        local payload = table.concat(parts, ";")
        local bytes = #payload
        net.Start("ScoreUpdate")
        net.WriteUInt(bytes, 16)
        net.WriteData(payload, bytes)
        net.Broadcast()
    end

    local function SendServerInfo()
        net.Start( "ServerInfoUpdate" )
            net.WriteFloat( external_server_info.cpu_usage  )   -- 32-bit float
            net.WriteUInt ( external_server_info.mem_used, 32 ) -- up to 4 GiB
        net.Broadcast()
    end
    timer.Create( "SendServerInfo", 2, 0, SendServerInfo )

    -- Track player statistics
    hook.Add("PlayerDeath", "scoreboard_track_deaths", function(victim, inflictor, attacker)
        if IsValid(victim) and victim:IsPlayer() then
            local victim_steamid = victim:SteamID()
            InitPlayerStats(victim)
            player_stats[victim_steamid].deaths = player_stats[victim_steamid].deaths + 1
        end

        if IsValid(attacker) and attacker:IsPlayer() and attacker ~= victim then
            local attacker_steamid = attacker:SteamID()
            InitPlayerStats(attacker)
            player_stats[attacker_steamid].kills = player_stats[attacker_steamid].kills + 1
        end
    end)

    hook.Add("PlayerInitialSpawn", "scoreboard_init_stats", function(ply)
        InitPlayerStats(ply)
    end)

    -- Server-side prop management
    net.Receive("FreezeProps", function(len, ply)
        if ply:GetUserGroup() ~= "admin" and ply:GetUserGroup() ~= "superadmin" then return end
        local target_steamid = net.ReadString()
        local target_player = player.GetBySteamID(target_steamid)
        if not IsValid(target_player) then return end

        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and ent:GetClass() == "prop_physics" and ent:CPPIGetOwner() == target_player then
                local phys = ent:GetPhysicsObject()
                if IsValid(phys) then
                    phys:EnableMotion(false)
                end
            end
        end
    end)

    net.Receive("DeleteProps", function(len, ply)
        if ply:GetUserGroup() ~= "superadmin" then return end
        local target_steamid = net.ReadString()
        local target_player = player.GetBySteamID(target_steamid)
        if not IsValid(target_player) then return end

        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and ent:GetClass() == "prop_physics" and ent:CPPIGetOwner() == target_player then
                ent:Remove()
            end
        end
    end)

    -- Read external server info every second
    timer.Create("ReadExternalServerInfo", 1, 0, ReadExternalServerInfo)
    timer.Create("SendScoreReal", 2, 0, SendRealData)
    ReadExternalServerInfo()
    SendRealData()
elseif CLIENT then
    local external_server_info = {
        cpu_usage = 0,
        mem_used = 0,
        mem_total = 8192  -- Set your server's max RAM here in MB
    }

    net.Receive("ScoreUpdate", function()
        local len  = net.ReadUInt(16)
        local raw  = net.ReadData(len)      -- already a proper string

        local players = {}

        for entry in raw:gmatch("[^;]+") do
            local f = {}
            for v in entry:gmatch("[^,]+") do f[#f+1] = v end

            local kills  = tonumber(f[2]) or 0
            local deaths = tonumber(f[3]) or 1 -- avoid div0
            

            -- Extract server info from first player's data
            if #f > 10 and f[11] ~= "" then
                local server_parts = {}
                for part in f[11]:gmatch("[^,]+") do
                    server_parts[#server_parts + 1] = part
                end
                if #server_parts == 2 then
                    external_server_info.cpu_usage = tonumber(server_parts[1]) or 0
                    external_server_info.mem_used = tonumber(server_parts[2]) or 0
                    print("Server Info Updated: CPU=" .. external_server_info.cpu_usage .. "%, RAM=" .. external_server_info.mem_used .. "/" .. external_server_info.mem_total .. "MB")
                    print(1)
                end
            end

            players[#players + 1] = {
                steamid            = f[1],
                kills              = kills,
                deaths             = deaths,
                kd                 = math.Round(kills / deaths, 2),
                props_active       = tonumber(f[4]) or 0,
                props_frozen       = tonumber(f[5]) or 0,
                constraints_active = tonumber(f[6]) or 0,
                constraints_frozen = tonumber(f[7]) or 0,
                ping               = tonumber(f[8]) or 0,
                loss               = tonumber(f[9]) or 0,
                nickname           = f[10] or ""
            }
        end
        SCOREBOARD_DATA = players
    end)

    net.Receive( "ServerInfoUpdate", function()
        external_server_info.cpu_usage = net.ReadFloat()
        external_server_info.mem_used  = net.ReadUInt(32)
    end )

    local font_scale_convar = CreateClientConVar("cl_buildhud_scale", "14", true, false)
    local alpha_convar = CreateClientConVar("cl_buildhud_alpha", "200", true, false)
    local current_scale = font_scale_convar:GetInt()

    -- Sorting state
    local sort_column = "nickname"
    local sort_ascending = true

    -- Context menu state
    local context_menu_data = nil
    local context_menu_pos = { x = 0, y = 0 }

    -- Scoreboard state
    local scoreboard_visible = false
    local scoreboard_pos = { x = 0, y = 0 }
    local scoreboard_size = { w = 800, h = 600 }

    -- Track muted players locally
    local muted_players = {}

    -- Helper function to count visual width of text (accounting for Cyrillic characters)
    local function get_visual_width(text)
        local visual_width = 0
        local i = 1
        while i <= #text do
            local byte = string.byte(text, i)
            if byte > 127 then
                -- Multi-byte UTF-8 character (like Cyrillic)
                if byte >= 194 and byte <= 223 then
                    i = i + 2                   -- 2-byte character
                elseif byte >= 224 and byte <= 239 then
                    i = i + 3                   -- 3-byte character
                elseif byte >= 240 and byte <= 244 then
                    i = i + 4                   -- 4-byte character
                else
                    i = i + 1                   -- Invalid UTF-8, treat as single byte
                end
                visual_width = visual_width + 1 -- Cyrillic displays as 1 character width
            else
                visual_width = visual_width + 1 -- ASCII character
                i = i + 1
            end
        end
        return visual_width
    end

    -- Helper function to pad text accounting for visual width
    local function pad_text_visual(text, target_width, align)
        local visual_width = get_visual_width(text)
        local padding_needed = target_width - visual_width

        if padding_needed <= 0 then
            return text -- Text is already too long
        end

        if align == "center" then
            local left_pad = math.floor(padding_needed / 2)
            local right_pad = padding_needed - left_pad
            return string.rep(" ", left_pad) .. text .. string.rep(" ", right_pad)
        elseif align == "right" then
            return string.rep(" ", padding_needed) .. text
        else -- left
            return text .. string.rep(" ", padding_needed)
        end
    end

    local function sort_players()
        if not SCOREBOARD_DATA then return end

        table.sort(SCOREBOARD_DATA, function(a, b)
            local val_a = a[sort_column]
            local val_b = b[sort_column]

            if type(val_a) == "string" then
                val_a = val_a:lower()
                val_b = val_b:lower()
            end

            if sort_ascending then
                return val_a < val_b
            else
                return val_a > val_b
            end
        end)
    end

    local function calculate_column_widths()
        if not SCOREBOARD_DATA or #SCOREBOARD_DATA == 0 then
            return { 8, 8, 6, 8, 8, 8, 8, 6, 6, 15 } -- Default widths for reordered columns
        end

        local subcolumn_widths = {}
        local subcolumn_fields = { "kills", "deaths", "kd", "props_active", "props_frozen", "constraints_active",
            "constraints_frozen", "ping", "loss", "steamid", "nickname" }
        local subcolumn_headers = { "KILLS", "DEATHS", "KD", "ACTIVE", "FROZEN", "ACTIVE", "FROZEN", "PING", "LOSS",
            "STEAMID", "NICKNAME" }

        -- Initialize with header widths
        for i, header in ipairs(subcolumn_headers) do
            subcolumn_widths[i] = math.max(get_visual_width(header) + 2, 6) -- Minimum width of 6
        end

        -- Check data widths
        for _, player in ipairs(SCOREBOARD_DATA) do
            for i, field in ipairs(subcolumn_fields) do
                if player[field] then
                    local str_val = tostring(player[field])
                    local visual_width = get_visual_width(str_val)
                    subcolumn_widths[i] = math.max(subcolumn_widths[i], visual_width + 2)
                end
            end
        end

        return subcolumn_widths
    end

    local function create_horizontal_line(widths, main_spans)
        local line = "+"
        if main_spans then
            -- Create line for main headers - reordered
            local main_sections = {
                { 3, "STATS" },       -- kills + deaths + kd
                { 2, "PROPS" },       -- active + frozen
                { 2, "CONSTRAINTS" }, -- active + frozen
                { 2, "CONNECTION" },  -- ping + loss
                { 2, "PLAYER" }       -- steamid + nickname (nickname displays the last so it wont affect the rest of scoreboard if it was in the start of the line)
            }

            for section_idx, section in ipairs(main_sections) do
                local total_width = 0
                local start_idx = 1
                if section_idx == 2 then
                    start_idx = 4
                elseif section_idx == 3 then
                    start_idx = 6
                elseif section_idx == 4 then
                    start_idx = 8
                elseif section_idx == 5 then
                    start_idx = 10
                end

                for i = 0, section[1] - 1 do
                    total_width = total_width + (widths[start_idx + i] or 8)
                end
                total_width = total_width + section[1] - 1 -- Add separators between subcolumns
                line = line .. string.rep("-", total_width) .. "+"
            end
        else
            -- Create line for subcolumns
            for _, width in ipairs(widths) do
                line = line .. string.rep("-", width) .. "+"
            end
        end
        return line
    end

    local function create_main_header_row(widths)
        local main_sections = {
            { 3, "STATS" },       -- kills + deaths + kd
            { 2, "PROPS" },       -- active + frozen
            { 2, "CONSTRAINTS" }, -- active + frozen
            { 2, "CONNECTION" },  -- ping + loss
            { 2, "PLAYER" }       -- steamid + nickname
        }

        local row = "|"
        for section_idx, section in ipairs(main_sections) do
            local span_count = section[1]
            local header_text = section[2]

            -- Calculate total width for this main column
            local total_width = 0
            local start_idx = 1
            if section_idx == 2 then
                start_idx = 4
            elseif section_idx == 3 then
                start_idx = 6
            elseif section_idx == 4 then
                start_idx = 8
            elseif section_idx == 5 then
                start_idx = 10
            end

            for i = 0, span_count - 1 do
                total_width = total_width + (widths[start_idx + i] or 8)
            end
            total_width = total_width + span_count - 1 -- Add space for internal separators

            -- Center the header text using visual width
            row = row .. pad_text_visual(header_text, total_width, "center") .. "|"
        end
        return row
    end

    local function create_text_row(texts, widths, alignment)
        alignment = alignment or {}
        local row = "|"
        for i, text in ipairs(texts) do
            local width = widths[i] or 10
            local align = alignment[i] or "center" -- Default to center
            row = row .. pad_text_visual(text, width, align) .. "|"
        end
        return row
    end

    local function generate_scoreboard_text()
        if not SCOREBOARD_DATA then return "" end

        sort_players()
        local widths = calculate_column_widths()
        local lines = {}

        -- Top border
        lines[#lines + 1] = create_horizontal_line(widths, true)

        -- Main column headers
        lines[#lines + 1] = create_main_header_row(widths)
        lines[#lines + 1] = create_horizontal_line(widths, false)

        -- Subcolumn headers - reordered
        local sub_headers = { "KILLS", "DEATHS", "KD", "ACTIVE", "FROZEN", "ACTIVE", "FROZEN", "PING", "LOSS", "STEAMID",
            "NICKNAME" }
        local alignments = { "center", "center", "center", "center", "center", "center", "center", "center", "center",
            "center", "center" }
        lines[#lines + 1] = create_text_row(sub_headers, widths, alignments)
        lines[#lines + 1] = create_horizontal_line(widths, false)

        -- Player data rows - reordered
        for _, player in ipairs(SCOREBOARD_DATA) do
            local row_data = {
                tostring(player.kills or 0),
                tostring(player.deaths or 0),
                tostring(player.kd or 0),
                tostring(player.props_active or 0),
                tostring(player.props_frozen or 0),
                tostring(player.constraints_active or 0),
                tostring(player.constraints_frozen or 0),
                tostring(player.ping or 0),
                tostring(player.loss or 0),
                player.steamid or "",
                player.nickname or ""
            }

            lines[#lines + 1] = create_text_row(row_data, widths)
            lines[#lines + 1] = create_horizontal_line(widths, false)
        end

        return table.concat(lines, "\n")
    end

    local function gen_font()
        surface.CreateFont("buildhud_monospace", {
            font = "Courier New",
            size = current_scale,
            weight = 500,
            antialias = false
        })
    end

    -- Generate htop-style system information using external data
    local function generate_htop_display()
        return external_server_info
    end

    local function draw_htop_panel(x, y, w)
        local info = generate_htop_display()
        local padding = 10
        local line_height = current_scale + 4

        -- Background
        local alpha = alpha_convar:GetInt()
        draw.RoundedBox(0, x, y, w, line_height * 4 + padding * 2, Color(0, 0, 0, alpha))
        draw.RoundedBox(0, x, y, w, 2, Color(100, 100, 100, 255))                                     -- Top border
        draw.RoundedBox(0, x, y + line_height * 4 + padding * 2 - 2, w, 2, Color(100, 100, 100, 255)) -- Bottom border
        draw.RoundedBox(0, x, y, 2, line_height * 4 + padding * 2, Color(100, 100, 100, 255))         -- Left border
        draw.RoundedBox(0, x + w - 2, y, 2, line_height * 4 + padding * 2, Color(100, 100, 100, 255)) -- Right border

        surface.SetFont("buildhud_monospace")
        surface.SetTextColor(255, 255, 255, 255)

        -- CPU usage bar
        local cpu_bar = ""
        local cpu_filled = math.floor(info.cpu_usage / 100 * 30)
        for i = 1, 30 do
            if i <= cpu_filled then
                cpu_bar = cpu_bar .. "█"
            else
                cpu_bar = cpu_bar .. "░"
            end
        end

        -- Memory usage bar
        local mem_bar = ""
        local mem_percent = info.mem_used / info.mem_total
        local mem_filled = math.floor(mem_percent * 30)
        for i = 1, 30 do
            if i <= mem_filled then
                mem_bar = mem_bar .. "█"
            else
                mem_bar = mem_bar .. "░"
            end
        end

        -- Draw htop-style info using external data
        local texts = {
            string.format("CPU: %s %.1f%%", cpu_bar, info.cpu_usage),
            string.format("MEM: %s %dM/%dM", mem_bar, info.mem_used, info.mem_total),
        }

        for i, text in ipairs(texts) do
            surface.SetTextPos(x + padding, y + padding + (i - 1) * line_height)
            surface.DrawText(text)
        end

        return line_height * 4 + padding * 2
    end

    local function handle_context_menu_action(action)
        if not context_menu_data then return end

        local player_data = context_menu_data
        local is_admin = LocalPlayer():GetUserGroup() == "admin" or LocalPlayer():GetUserGroup() == "superadmin"
        local is_superadmin = LocalPlayer():GetUserGroup() == "superadmin"

        if action == 1 then -- Mute/Unmute Voice
            local target_player = player.GetBySteamID(player_data.steamid)
            if IsValid(target_player) then
                if muted_players[player_data.steamid] then
                    target_player:SetMuted(false)
                    muted_players[player_data.steamid] = nil
                    chat.AddText(Color(0, 255, 0), "Unmuted voice: " .. player_data.nickname)
                else
                    target_player:SetMuted(true)
                    muted_players[player_data.steamid] = true
                    chat.AddText(Color(255, 255, 0), "Muted voice: " .. player_data.nickname)
                end
            else
                chat.AddText(Color(255, 0, 0), "Player not found!")
            end
        elseif action == 2 and is_admin then -- Freeze Props
            net.Start("FreezeProps")
            net.WriteString(player_data.steamid)
            net.SendToServer()
            chat.AddText(Color(0, 255, 255), "Froze all props for: " .. player_data.nickname)
        elseif action == 3 and is_superadmin then -- Delete Props
            net.Start("DeleteProps")
            net.WriteString(player_data.steamid)
            net.SendToServer()
            chat.AddText(Color(255, 100, 100), "Deleted all props for: " .. player_data.nickname)
        end

        context_menu_data = nil
    end

    local function draw_context_menu()
        if not context_menu_data then return end

        local player_data = context_menu_data
        local is_muted = muted_players[player_data.steamid] or false
        local is_admin = LocalPlayer():GetUserGroup() == "admin" or LocalPlayer():GetUserGroup() == "superadmin"
        local is_superadmin = LocalPlayer():GetUserGroup() == "superadmin"

        local menu_w, menu_h = 200, 120
        local x, y = context_menu_pos.x, context_menu_pos.y

        -- Keep menu on screen
        if x + menu_w > ScrW() then x = ScrW() - menu_w end
        if y + menu_h > ScrH() then y = ScrH() - menu_h end

        -- Background
        local alpha = alpha_convar:GetInt()
        draw.RoundedBox(0, x, y, menu_w, menu_h, Color(20, 20, 20, alpha))
        draw.RoundedBox(0, x + 1, y + 1, menu_w - 2, menu_h - 2, Color(40, 40, 40, alpha))

        -- Border
        draw.RoundedBox(0, x, y, menu_w, 2, Color(100, 100, 100, 255))
        draw.RoundedBox(0, x, y + menu_h - 2, menu_w, 2, Color(100, 100, 100, 255))
        draw.RoundedBox(0, x, y, 2, menu_h, Color(100, 100, 100, 255))
        draw.RoundedBox(0, x + menu_w - 2, y, 2, menu_h, Color(100, 100, 100, 255))

        surface.SetFont("buildhud_monospace")
        surface.SetTextColor(255, 255, 255, 255)

        local texts = {
            "PLAYER ACTIONS",
            "",
            is_muted and "1. Unmuted Voice" or "1. Mute Voice",
            is_admin and "2. Freeze Props" or "2. [ADMIN ONLY]",
            is_superadmin and "3. Delete Props" or "3. [SUPER ADMIN]"
        }

        for i, text in ipairs(texts) do
            if text ~= "" then
                surface.SetTextPos(x + 10, y + 10 + (i - 1) * (current_scale + 2))
                surface.DrawText(text)
            end
        end
    end

    local function handle_mouse_click(mx, my, button)
        if not scoreboard_visible then return end

        -- Check context menu click
        if context_menu_data then
            local menu_w, menu_h = 200, 120
            local x, y = context_menu_pos.x, context_menu_pos.y

            -- Keep menu on screen
            if x + menu_w > ScrW() then x = ScrW() - menu_w end
            if y + menu_h > ScrH() then y = ScrH() - menu_h end

            if mx >= x and mx <= x + menu_w and my >= y and my <= y + menu_h then
                -- Click inside context menu
                local line = math.floor((my - y - 10) / (current_scale + 2)) + 1
                if line == 3 then
                    handle_context_menu_action(1)
                elseif line == 4 then
                    handle_context_menu_action(2)
                elseif line == 5 then
                    handle_context_menu_action(3)
                end
            else
                -- Click outside context menu, close it
                context_menu_data = nil
            end
            return
        end

        -- Check scoreboard click
        if mx >= scoreboard_pos.x and mx <= scoreboard_pos.x + scoreboard_size.w and
            my >= scoreboard_pos.y and my <= scoreboard_pos.y + scoreboard_size.h then
            local relative_x = mx - scoreboard_pos.x - 10
            local relative_y = my - scoreboard_pos.y - 10

            -- Account for htop panel height
            local htop_height = (current_scale + 4) * 4 + 20
            relative_y = relative_y - htop_height - 10

            local line_height = current_scale + 2
            local line_num = math.floor(relative_y / line_height) + 1

            -- Check if clicked on subcolumn header for sorting (line 4)
            if line_num == 4 and SCOREBOARD_DATA then
                local widths = calculate_column_widths()
                local current_x = 1 -- Start after first '|'
                local subcolumn_fields = { "kills", "deaths", "kd", "props_active", "props_frozen", "constraints_active",
                    "constraints_frozen", "ping", "loss", "steamid", "nickname" }

                for i, width in ipairs(widths) do
                    if relative_x >= current_x and relative_x <= current_x + width then
                        local field = subcolumn_fields[i]
                        if field then
                            if sort_column == field then
                                sort_ascending = not sort_ascending
                            else
                                sort_column = field
                                sort_ascending = true
                            end
                            return
                        end
                    end
                    current_x = current_x + width + 1 -- +1 for '|'
                end
            end

            -- Check if clicked on player data for context menu (line 6 and beyond, every 2 lines)
            if line_num >= 6 and SCOREBOARD_DATA then
                local data_line = line_num - 6                                -- Adjust for headers
                local player_idx = math.floor(data_line / 2) + 1              -- Every 2 lines (data + separator)
                if player_idx <= #SCOREBOARD_DATA and data_line % 2 == 0 then -- Only on data lines, not separator lines
                    context_menu_data = SCOREBOARD_DATA[player_idx]
                    context_menu_pos.x = mx
                    context_menu_pos.y = my
                end
            end
        end
    end

    local function draw_scoreboard()
        if not scoreboard_visible then return end

        -- Update font if scale changed
        if current_scale ~= font_scale_convar:GetInt() then
            current_scale = font_scale_convar:GetInt()
            gen_font()
        end

        local scoreboard_text = generate_scoreboard_text()
        local lines = string.Split(scoreboard_text, "\n")

        surface.SetFont("buildhud_monospace")
        local line_height = current_scale + 2
        local max_width = 0

        for _, line in ipairs(lines) do
            local w, _ = surface.GetTextSize(line)
            max_width = math.max(max_width, w)
        end

        -- Calculate htop panel height
        local htop_height = (current_scale + 4) * 4 + 20

        local total_height = #lines * line_height + 20 + htop_height + 10
        local total_width = math.max(max_width + 20, 600) -- Minimum width for htop

        -- Center on screen
        scoreboard_pos.x = (ScrW() - total_width) / 2
        scoreboard_pos.y = (ScrH() - total_height) / 2
        scoreboard_size.w = total_width
        scoreboard_size.h = total_height

        -- Draw htop panel
        local htop_panel_height = draw_htop_panel(scoreboard_pos.x, scoreboard_pos.y, total_width)

        -- Draw main scoreboard background
        local alpha = alpha_convar:GetInt()
        local main_y = scoreboard_pos.y + htop_panel_height + 10
        local main_height = total_height - htop_panel_height - 10

        draw.RoundedBox(0, scoreboard_pos.x, main_y, total_width, main_height, Color(0, 0, 0, alpha))

        -- Draw outline
        draw.RoundedBox(0, scoreboard_pos.x, main_y, total_width, 2, Color(100, 100, 100, 255))                   -- Top
        draw.RoundedBox(0, scoreboard_pos.x, main_y + main_height - 2, total_width, 2, Color(100, 100, 100, 255)) -- Bottom
        draw.RoundedBox(0, scoreboard_pos.x, main_y, 2, main_height, Color(100, 100, 100, 255))                   -- Left
        draw.RoundedBox(0, scoreboard_pos.x + total_width - 2, main_y, 2, main_height, Color(100, 100, 100, 255)) -- Right

        -- Draw scoreboard text
        surface.SetTextColor(255, 255, 255, 255)
        for i, line in ipairs(lines) do
            surface.SetTextPos(scoreboard_pos.x + 10, main_y + 10 + (i - 1) * line_height)
            surface.DrawText(line)
        end

        -- Draw context menu
        draw_context_menu()
    end

    local function tab_show()
        scoreboard_visible = true
        gui.EnableScreenClicker(true) -- Enable mouse cursor
        return true
    end

    local function tab_hide()
        scoreboard_visible = false
        context_menu_data = nil
        gui.EnableScreenClicker(false) -- Disable mouse cursor
    end

    hook.Add("OnGamemodeLoaded", "tab_menu_create", function()
        gen_font()
    end)

    hook.Add("HUDPaint", "draw_custom_scoreboard", draw_scoreboard)
    hook.Add("ScoreboardHide", "tab_menu_hide", tab_hide)
    hook.Add("ScoreboardShow", "tab_menu_show", tab_show)

    -- Handle mouse clicks
    hook.Add("GUIMousePressed", "scoreboard_mouse_click", function(mouseCode, aimVector)
        if mouseCode == MOUSE_LEFT then
            local mx, my = gui.MouseX(), gui.MouseY()
            handle_mouse_click(mx, my, mouseCode)
        end
    end)
end
