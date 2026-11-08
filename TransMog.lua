--[[
TransMog: turns DAT mods for mounts, gear and weapons on and off, from a window in the style of
VanaCore's own menus (the vcmenu library, in this folder).

In game:
  /transmog or /tm               shows the window
  /transmog <page>                shows a page: lockstyle, jobs, colors, effects, race, mounts, gear, weapons, other, about
  /transmog save <set>            saves your look as a set; /transmog wear <set> wears one
  /transmog race <race> [sex]     draws you as a race (own: your own)
  /transmog face <1a-8b>          your face and hair (own: your own)
  /transmog size <50-200>         your size, in percent (own: your own)
  /transmog list                  the mods, and which are on
  /transmog on <mod>              turns a mod on
  /transmog off <mod>             turns a mod off
  /transmog mount <target> <look>  makes a mod: <target> looks like <look>, e.g. /transmog mount Raptor Alicorn
--]]

addon.name    = 'TransMog';
addon.author  = 'Benthere';
addon.version = '2.0.1';
addon.desc    = 'Turns DAT mods for mounts, gear and weapons on and off.';

require('common');
local imgui = require('imgui');
local vc    = require('vcmenu');
local core  = require('transmog_core');

local VC = vc.colors;
local COMBO_W = 240;
local ICONS = { mount = 'star', gear = 'equip', weapon = 'spark', other = 'files' };

local win = vc.new_state('lock');
local target, look;    -- what the mount swap's two boxes have picked
local slot_key = 'body';    -- the slot the gear list is for
local find = { '' };
local set_name = { '' };
local chosen_set;    -- the set picked on the Job LockStyles page

local STATES = {
    loaded      = { 'Loaded', VC.good },
    zone_load   = { 'Zone to load', VC.gold },
    zone_remove = { 'Zone to remove', VC.gold },
};
local TAG_W, DELETE_W, SWITCH_W = 112, 62, 38;
local confirming;    -- the mod folder whose Delete has been clicked once

local function mount_row(mod)
    local v;
    imgui.AlignTextToFramePadding();
    imgui.Text(mod.title);
    imgui.SameLine();
    vc.right(TAG_W + DELETE_W + SWITCH_W);
    local x = imgui.GetCursorPosX();
    local state = STATES[core.mod_state(mod) or ''];
    if state then
        imgui.TextColored(state[2], state[1]);
    else
        imgui.TextDisabled('Off');
    end
    imgui.SameLine();
    imgui.SetCursorPosX(x + vc.z(TAG_W));
    if mod.look then
        imgui.Dummy({ vc.z(DELETE_W - 6), 1 });
        if imgui.IsItemHovered() then imgui.SetTooltip('Supplies a look in Your Looks'); end
    else
        local sure = confirming == mod.folder;
        if vc.button((sure and 'Sure?' or 'Delete') .. '##del_' .. mod.folder, sure and 'danger' or nil, DELETE_W - 6) then
            if sure then
                confirming = nil;
                core.delete_mod(mod);
                return;
            end
            confirming = mod.folder;
        end
    end
    imgui.SameLine();
    imgui.SetCursorPosX(x + vc.z(TAG_W + DELETE_W));
    v = vc.switch('mod_' .. mod.folder, '', core.is_enabled(mod));
    if v ~= nil then core.set_enabled(mod, v); end
end

local function mod_rows(category)
    local shown = false;
    for _, mod in ipairs(core.mods) do
        if mod.category == category then
            shown = true;
            if category == 'mount' then
                mount_row(mod);
            else
                local v = vc.switch_row('mod_' .. mod.folder, mod.title, core.is_enabled(mod));
                if v ~= nil then core.set_enabled(mod, v); end
            end
        end
    end
    return shown;
end

-- the mount mods for the mounts you own, by mount; a mod's mount starts its title ("Bomb as ...")
local function mount_mod_rows()
    local owned = {};
    for _, mount in ipairs(core.owned_mounts()) do owned[mount.name:lower()] = true; end
    local mine = {};
    for _, mod in ipairs(core.mods) do
        local mount = (mod.title:match('^(.-) as ') or mod.title):lower();
        if mod.category == 'mount' and owned[mount] then
            mine[#mine + 1] = { mod = mod, mount = mount };
        end
    end
    table.sort(mine, function (a, b)
        if a.mount ~= b.mount then return a.mount < b.mount; end
        return a.mod.title:lower() < b.mod.title:lower();
    end);
    for _, row in ipairs(mine) do mount_row(row.mod); end
    return #mine > 0;
end

local function conflicts()
    if next(core.conflicts) == nil then return; end
    vc.section('CONFLICTS');
    for rel, list in pairs(core.conflicts) do
        imgui.TextColored(VC.gold, rel .. ' is in: ' .. table.concat(list, ', '));
    end
end

local function mount_rows(list, picked, set)
    for _, mount in ipairs(list) do
        if imgui.Selectable(mount.name, picked ~= nil and mount.name == picked.name) then set(mount); end
    end
end

local function mount_box(label, picked, list, set)
    vc.label_row(label, COMBO_W);
    imgui.SetNextItemWidth(vc.z(COMBO_W));
    if imgui.BeginCombo('##' .. label, picked and picked.name or 'Choose...') then
        mount_rows(list(), picked, set);
        imgui.EndCombo();
    end
end

local PAGES = {};

-- the right column of a row: a mod's own look, or a piece a mod that's on changes
local function set_names()
    local names = {};
    for name in pairs(core.config.data.sets) do names[#names + 1] = name; end
    table.sort(names, function (a, b) return a:lower() < b:lower(); end);
    return names;
end

-- a piece only copied into Recolored gear says what was done to it (shown: the piece your look shows), or nothing
local function modified_tag(key, id, shown)
    if core.looks[id or 0] then return 'Custom'; end
    local titles = core.changed_by(key, id);
    if core.is_copy_only(titles) then return core.copy_reason(key, id, shown); end
    return titles and 'Modified' or nil;
end

local function modified_tip(key, id, shown)
    local look = core.looks[id or 0];
    local titles = look and { look.title } or core.changed_by(key, id);
    if core.is_copy_only(titles) and not core.copy_reason(key, id, shown) then titles = nil; end
    if titles and imgui.IsItemHovered() then
        imgui.SetTooltip('Changed by ' .. table.concat(titles, ', '));
    end
end

-- one slot of Your Look in half a row, drawn like vc.row: icon, name, then the slot and any tag at the right.
-- Returns clicked.
local function look_cell(slot, name, id)
    local x, y = vc.screen_pos();
    local w, rh, isz = math.max(vc.avail_w(), 1), vc.row_height(), vc.z(24);
    local clicked = imgui.InvisibleButton('##slot_' .. slot.key, { w, rh });
    local hovered, selected = imgui.IsItemHovered(), slot_key == slot.key;
    local dl = imgui.GetWindowDrawList();
    if selected then
        dl:AddRectFilled({ x, y + 1 }, { x + w, y + rh - 1 }, vc.u32(vc.alpha(VC.acc, 0.13)), vc.z(5), 0);
        dl:AddRectFilled({ x + 1, y + vc.z(6) }, { x + vc.z(4), y + rh - vc.z(6) }, vc.u32(VC.acc), 1, 0);
    elseif hovered then
        dl:AddRectFilled({ x, y + 1 }, { x + w, y + rh - 1 }, vc.u32({ 1, 1, 1, 0.05 }), vc.z(5), 0);
    end
    local ix, iy = x + vc.z(9), y + (rh - isz) / 2;
    dl:AddRectFilled({ ix - 1, iy - 1 }, { ix + isz + 1, iy + isz + 1 }, vc.u32(VC.field), vc.z(4), 0);
    local icon = vc.item_icon(core.icon_of(id));
    if icon ~= nil then dl:AddImage(icon.ptr, { ix, iy }, { ix + isz, iy + isz }); end
    local ty = y + (rh - select(2, vc.xy(imgui.CalcTextSize('Ag')))) / 2;
    local right = x + w - vc.z(8);
    right = right - vc.xy(imgui.CalcTextSize(slot.label));    -- the slot, in gray at the right edge
    dl:AddText({ right, ty }, vc.u32(VC.mute), slot.label);
    local tag = modified_tag(slot.key, id, true);             -- Custom or Glow just left of it
    if tag then
        right = right - vc.z(8) - vc.xy(imgui.CalcTextSize(tag));
        dl:AddText({ right, ty }, vc.u32(VC.teal), tag);
    end
    local nx = ix + isz + vc.z(9);
    local name_col = name == nil and VC.mute or (selected and { 1, 1, 1, 1 } or VC.text);
    dl:AddText({ nx, ty }, vc.u32(name_col), vc.fit_text(name or 'Worn gear', right - vc.z(8) - nx));
    return clicked;
end

PAGES.lock = function ()
    local cfg = core.config.data;
    vc.title('Lockstyle', 'Click a piece to see it on your character');
    local v = vc.switch_row('lock_on', 'TransMog ON', cfg.lock);
    if v ~= nil then core.set_lock(v); end
    local blink = vc.switch_row('no_blink', 'No blink on gear change', core.blink_setting('blink.disable'));
    if blink ~= nil then core.set_blink_setting('blink.disable', blink); end    -- on your screen only: nothing is sent
    if core.blink_setting('blink.disable') then
        vc.note("Only on your screen. Others still see you blink when your gear changes, unless you type the game's own /lockstyle on.");
        local weapons = vc.switch_row('no_blink_weapons', 'Weapons too', core.blink_setting('blink.weapons'));
        if weapons ~= nil then core.set_blink_setting('blink.weapons', weapons); end
        if core.blink_setting('blink.weapons') then
            vc.note('Weapons too is only on your screen as well.');
        end
    end
    local frame = vc.switch_row('frame_me', 'Show me beside this window', cfg.frame_me);
    if frame ~= nil then
        cfg.frame_me = frame;
        core.config:save();
    end
    if cfg.frame_me then
        vc.label_row('Camera distance', COMBO_W);
        imgui.SetNextItemWidth(vc.z(COMBO_W));
        local distance = { tonumber(cfg.frame_distance) or 4.5 };
        if imgui.SliderFloat('##frame_distance', distance, 2.5, 9, '%.1f') then cfg.frame_distance = distance[1]; end
        if imgui.IsItemDeactivatedAfterEdit() then core.config:save(); end
        vc.label_row('Push me right', COMBO_W);
        imgui.SetNextItemWidth(vc.z(COMBO_W));
        local shift = { (tonumber(cfg.frame_shift) or 0.3) / 0.6 * 100 };    -- 0.6 radians puts you near the edge
        if imgui.SliderFloat('##frame_shift', shift, 0, 100, '%.0f%%') then cfg.frame_shift = shift[1] / 100 * 0.6; end
        if imgui.IsItemDeactivatedAfterEdit() then core.config:save(); end
        -- the turn buttons sit on the row, before its slider
        local GAP, SPIN_W, TURN_W = 6, 90, 70;
        vc.label_row('Turn around me', SPIN_W + TURN_W * 2 + COMBO_W + GAP * 3);
        local spinning = core.frame_spin() ~= 0;
        if vc.button(spinning and 'Stop spin' or 'Spin', spinning and 'primary' or nil, SPIN_W) then
            core.frame_spin(spinning and 0 or 45);
        end
        imgui.SameLine(0, vc.z(GAP));
        if vc.button('Front', nil, TURN_W) then core.frame_spin(0); core.frame_angle(0); end
        imgui.SameLine(0, vc.z(GAP));
        if vc.button('Back', nil, TURN_W) then core.frame_spin(0); core.frame_angle(180); end
        imgui.SameLine(0, vc.z(GAP));
        imgui.SetNextItemWidth(math.max(vc.avail_w(), vc.z(60)));    -- the slider takes what the row has left
        local angle = { core.frame_angle() };
        if imgui.SliderFloat('##frame_angle', angle, 0, 359, '%.0f deg') then core.frame_angle(angle[1]); end
    end

    local names = set_names();
    if #names > 0 then
        vc.label_row('Start from a saved set', COMBO_W);
        imgui.SetNextItemWidth(vc.z(COMBO_W));
        if imgui.BeginCombo('##start_from', 'Choose...') then
            for _, name in ipairs(names) do
                if imgui.Selectable(name, false) then
                    core.wear_set(name);
                    set_name[1] = name;
                end
            end
            imgui.EndCombo();
        end
    end

    vc.note('A blank slot shows what you are wearing. With TransMog ON, it stays as you looked when you turned it on (locked), so changing gear does not change it; turn TransMog off and on to lock to new gear.');
    vc.section('YOUR LOOK', ('%d of %d slots'):format(core.picks_count(), #core.SLOTS));
    -- two slots a row, in slot order: head and body, hands and legs, feet and main, sub and ranged
    -- a line between the two columns
    if imgui.BeginTable('##your_look', 2, bit.bor(ImGuiTableFlags_SizingStretchSame or 0, ImGuiTableFlags_BordersInnerV or 512)) then
        for _, slot in ipairs(core.SLOTS) do
            imgui.TableNextColumn();
            local name = core.picked_name(slot.key);
            local x, y = imgui.GetCursorPos();
            if core.is_armor(slot.key) then
                imgui.SetCursorPos({ x, y + (vc.row_height() - imgui.GetFrameHeight()) / 2 });
                local checked = { core.match_slot() == slot.key };
                if imgui.Checkbox('##match_' .. slot.key, checked) then core.toggle_match_slot(slot.key); end
                if imgui.IsItemHovered() then imgui.SetTooltip('Match other slots to this piece'); end
            end
            imgui.SetCursorPos({ x + imgui.GetFrameHeight() + vc.z(6), y });
            if look_cell(slot, name, cfg.picks[slot.key]) then
                slot_key = slot.key;
                find[1] = '';
            end
            modified_tip(slot.key, cfg.picks[slot.key], true);
        end
        imgui.EndTable();
    end


    imgui.Dummy({ 0, vc.z(4) });
    imgui.SetNextItemWidth(vc.z(125));
    imgui.InputTextWithHint('##set_name', 'Set name', set_name, 32);
    imgui.SameLine();
    local ready = set_name[1] ~= '' and core.picks_count() > 0;
    if vc.button('Save set', ready and 'primary' or nil, 76) and ready then
        core.save_set(set_name[1]);
        set_name[1] = '';
    end
    imgui.SameLine();
    if vc.button('Use worn', nil, 76) then core.pick(slot_key, nil); end
    imgui.SameLine();
    if vc.button('Clear all', nil, 76) then core.clear_picks(); end

    local label = '';
    for _, slot in ipairs(core.SLOTS) do
        if slot.key == slot_key then label = slot.label:upper(); end
    end
    local items, total = core.items_for(slot_key, find[1]);
    vc.section('CHOOSE ' .. label, ('%d looks'):format(total));
    vc.search_box('##find', find, 'Search ' .. label:lower(), -1);
    -- the piece Your Look shows in this slot goes first: moved up from where it sits, or added when it is past the
    -- rows the list holds (only while not searching, or when the search finds it)
    local picked, top = cfg.picks[slot_key], nil;
    if picked then
        local rest = {};
        for _, item in ipairs(items) do
            if not top and core.same_look(slot_key, picked, item.id) then top = item; else rest[#rest + 1] = item; end
        end
        if not top and find[1] == '' then top = core.picked_item(slot_key); end
        if top then items = rest; end
    end
    local function item_row(item)
        local tag = modified_tag(slot_key, item.id);
        if vc.row('item_' .. item.id, { icon = core.icon_of(item.id), name = item.name, right = tag or (item.main_only and 'May not match' or nil),
                                        right_col = tag and VC.teal or VC.gold, right_fit = true,
                                        selected = core.same_look(slot_key, cfg.picks[slot_key], item.id) }) then
            core.pick(slot_key, item);
        end
        modified_tip(slot_key, item.id);
    end
    vc.list('##pieces', 8, function ()
        if top then item_row(top); end
        local checked = core.match_slot();
        if checked ~= '' and checked ~= slot_key and core.is_armor(slot_key) and not cfg.picks[checked] then
            vc.note('Pick a piece for the checked slot to match to it.');
        end
        local match = core.is_armor(slot_key) and core.set_match() or nil;
        if match then
            local piece = match.picks[slot_key];
            if piece and cfg.picks[slot_key] ~= piece then
                if vc.row('match_slot', { icon = piece, name = 'Match this slot to ' .. match.name,
                                          mid = core.item_name(piece) }) then
                    core.wear_slot_match(slot_key, match);
                end
            end
            if vc.row('match_set', { name = 'Match full set to ' .. match.name, mid = ('%d pieces'):format(match.count) }) then
                core.wear_match(match);
            end
        end
        local main = core.picked_item('main');
        if slot_key == 'sub' and main then
            if vc.row('same_as_main', { icon = main.id, name = 'Same as main: ' .. main.name,
                                        selected = cfg.picks.sub == main.id }) then
                core.pick('sub', main);
            end
        end
        for _, item in ipairs(items) do item_row(item); end
        if total > #items then
            vc.note(('Showing the first %d. Search to narrow it down.'):format(#items));
        end
    end);
end;

local function job_row(job, names, here)
    local x, y = imgui.GetCursorPos();
    imgui.SetCursorPos({ x + vc.z(8), y + vc.z(5) });
    if here then
        imgui.TextColored(VC.teal, job.name);
    else
        imgui.Text(job.name);
    end
    imgui.SameLine();
    local width = math.min(vc.z(COMBO_W), vc.avail_w() - vc.z(12));
    imgui.SetCursorPos({ imgui.GetWindowWidth() - width - vc.z(22), y + vc.z(2) });
    imgui.SetNextItemWidth(width);
    local set = core.job_set(job.short);
    if imgui.BeginCombo('##job_' .. job.short, set or 'None') then
        if imgui.Selectable('None', set == nil) then core.assign_job_set(job.short, nil); end
        for _, name in ipairs(names) do
            if imgui.Selectable(name, name == set) then core.assign_job_set(job.short, name); end
        end
        imgui.EndCombo();
    end
    imgui.SetCursorPos({ x, y + vc.row_height() + vc.z(4) });
end

PAGES.sets = function ()
    local sets = core.config.data.sets;
    vc.title('Job LockStyles', 'Your saved looks, and the job each loads on');
    local names = set_names();
    if #names == 0 then
        vc.note('No saved sets yet. Build a look on the Lockstyle page, then choose Save set.');
    else
        if not sets[chosen_set] then chosen_set = names[1]; end
        imgui.SetNextItemWidth(vc.z(COMBO_W));
        if imgui.BeginCombo('##chosen_set', ('%s  (%d pieces)'):format(chosen_set, core.picks_count(sets[chosen_set]))) then
            for _, name in ipairs(names) do
                if imgui.Selectable(('%s  (%d pieces)##%s'):format(name, core.picks_count(sets[name]), name), name == chosen_set) then
                    chosen_set = name;
                end
            end
            imgui.EndCombo();
        end
        imgui.SameLine();
        if vc.button('Wear', 'primary', 76) then core.wear_set(chosen_set); end
        imgui.SameLine();
        if vc.button('Delete', 'danger', 76) then
            core.delete_set(chosen_set);
            chosen_set = nil;
        end
    end
    if core.status ~= '' then vc.note(core.status); end

    vc.section('LOAD BY JOB', core.current_job() and ('You are ' .. core.current_job()) or nil);
    vc.note('Your job set is worn when you change to that job or log in. A job set to None keeps your current look.');
    if #names == 0 then return; end
    local here = core.current_job();
    vc.list('##jobs', 8, function ()
        for _, job in ipairs(core.jobs()) do
            job_row(job, names, job.short == here);
        end
    end);
end;

PAGES.mount = function ()
    vc.title('Mounts', 'Change how a mount looks');
    vc.in_font('bold', 15, function ()
        imgui.TextColored({ 0.95, 0.33, 0.33, 1 }, 'You must zone for a new mount look to take effect.');
    end);
    vc.note('The mount menu adds "Looks like: <look>" to a changed mount\'s help line after you log out and back in, or restart the game.');

    vc.section('NEW MOUNT SWAP');
    mount_box('Your Mount', target, core.owned_mounts, function (mount) target = mount; end);
    -- one look at a time: a custom look carries its own file, a standard mount doesn't
    mount_box('Transform into: Standard FFXI', look and not look.file and look or nil,
        function () return core.mounts; end, function (mount) look = mount; end);
    mount_box('Transform into: Custom Mounts', look and look.file and look or nil,
        core.mount_looks, function (mount) look = mount; end);
    local ready = target ~= nil and look ~= nil and target ~= look;
    if vc.button('Create and turn on', ready and 'primary' or nil, 170) and ready then
        local mod = core.create_mount_swap(target, look);
        if mod then core.set_enabled(mod, true); end
        target, look = nil, nil;
    end

    vc.section('MODS');
    if not mount_mod_rows() then vc.note('No mount mods yet.'); end
    conflicts();
end

local function list_page(category, title, subtitle)
    return function ()
        vc.title(title, subtitle);
        vc.section('MODS');
        if not mod_rows(category) then
            vc.note(('No %s mods yet. Add a folder to %s\\TransMog, then choose Rescan.'):format(title:lower(), core.root()));
        end
        conflicts();
    end;
end

PAGES.gear   = list_page('gear', 'Gear', 'Replace armor models');
PAGES.weapon = list_page('weapon', 'Weapons', 'Replace weapon models');
PAGES.other  = list_page('other', 'Other', 'Mods with no category');

PAGES.effects = function ()
    vc.title('Effects', 'On whatever each slot shows');
    vc.section('EFFECTS');
    local choices = core.effect_choices();
    for _, row in ipairs({ { 'body', 'Wings', choices.wings }, { 'main', 'Main glow', choices.glows },
                           { 'sub', 'Sub glow', choices.glows }, { 'range', 'Ranged glow', choices.glows } }) do
        local key, label, list = row[1], row[2], row[3];
        local current = core.effect_choice(key);
        vc.label_row(label, COMBO_W);
        imgui.SetNextItemWidth(vc.z(COMBO_W));
        if imgui.BeginCombo('##effect_' .. key, current == nil and 'Its own' or current == 'off' and 'None' or current) then
            if imgui.Selectable('Its own##' .. key, current == nil) then core.set_effect(key, nil); end
            if imgui.Selectable('None##' .. key, current == 'off') then core.set_effect(key, 'off'); end
            for _, entry in ipairs(list) do
                if imgui.Selectable(entry.name .. '##' .. key, current == entry.name) then core.set_effect(key, entry.name); end
            end
            imgui.EndCombo();
        end
    end
    vc.note('An effect on a normal piece shows on anyone you see wearing that piece too.');
    if core.status ~= '' then vc.note(core.status); end
end;

-- the Colors page: the slot being edited, and its colors as 0 to 1 floats for the pickers
local COLOR_SLOTS = { 'head', 'body', 'hands', 'legs', 'feet', 'main', 'sub', 'range' };
local tint = { slot = 'body', key = nil, edit = nil, unsaved = false, live = { true }, name = { '' }, tried = {},
               open = {} };    -- open: color name -> { true } while its picker panel is open

local function to_floats(palette)
    local out = {};
    for _, name in ipairs(core.COLOR_NAMES) do
        local c = palette[name];
        if c then out[name] = { c[1] / 255, c[2] / 255, c[3] / 255 }; end
    end
    return out;
end

local function to_bytes(edit)
    local out = {};
    for _, name in ipairs(core.COLOR_NAMES) do
        local c = edit[name];
        if c then out[name] = { math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5) }; end
    end
    return out;
end

local function slot_label(key)
    for _, slot in ipairs(core.SLOTS) do
        if slot.key == key then return slot.label; end
    end
    return key;
end

PAGES.colors = function ()
    vc.title('Colors', 'The piece in each slot of your look, ready to recolor');
    tint.slot = slot_key;    -- the slot picked on the Lockstyle page, and the other way round
    for i, key in ipairs(COLOR_SLOTS) do
        if i > 1 and i ~= 6 then imgui.SameLine(); end    -- weapons on a row of their own
        if vc.button(slot_label(key) .. '##tint_slot', tint.slot == key and 'primary' or nil, 70) then
            tint.slot, slot_key = key, key;
            find[1] = '';
        end
    end

    local target, why, normal = core.color_target(tint.slot);
    if not target and normal and not tint.tried[normal.rel] then    -- a normal piece is made recolorable on sight
        tint.tried[normal.rel] = true;
        if core.make_recolorable(tint.slot) then target, why, normal = core.color_target(tint.slot); end
    end
    vc.section(slot_label(tint.slot):upper(), target and target.name or normal and normal.name or nil);
    if not target then
        vc.note(why);
        if core.status ~= '' then vc.note(core.status); end
        return;
    end
    if core.pending then vc.note('Zone once so the game reads recolored gear.'); end
    if core.is_recolored_copy(target) then
        vc.note('This is your own copy of a normal piece: only your character wears it, so anyone else wearing it keeps its colors.');
    end
    local key = target.mod.folder .. '|' .. target.rel;
    if tint.key ~= key then
        tint.key = key;
        tint.open = {};    -- another piece: its panels start closed
        tint.edit = to_floats(core.saved_colors(target.mod, target.rel));
        tint.unsaved = false;
        tint.name[1] = core.next_color_name(target.mod, target.rel, target.name);
        local built = core.default_colors(target.mod, target.rel);
        tint.scheme = { main = to_floats({ main = built.main }).main, second = to_floats({ main = built.dark }).main };
    end
    local live = vc.switch_row('tint_live', 'Show changes on me as I pick', tint.live[1]);
    if live ~= nil then tint.live[1] = live; end

    local finished = false;
    local defaults = core.default_colors(target.mod, target.rel);    -- the game's own colors
    local saved = core.saved_colors(target.mod, target.rel);         -- the ones last saved, or the game's
    local SWATCH_W, RESET_W, GAP = 140, 64, 6;
    -- a color's row: its swatch opens its panel, Default and Saved put it back. Returns 'default', 'saved' or nil.
    local function color_row(id, label, color)
        vc.label_row(label, SWATCH_W + RESET_W * 2 + GAP * 2);
        if imgui.ColorButton('##tint_' .. id, { color[1], color[2], color[3], 1 }, 0, { vc.z(SWATCH_W), vc.z(22) }) then
            tint.open[id] = tint.open[id] or { false };
            tint.open[id][1] = not tint.open[id][1];
        end
        if imgui.IsItemHovered() then imgui.SetTooltip('Open its color panel'); end
        local pick;
        imgui.SameLine(0, vc.z(GAP));
        if vc.button('Default##tint_def_' .. id, nil, RESET_W) then pick = 'default'; end
        if imgui.IsItemHovered() then imgui.SetTooltip("Back to the game's own color"); end
        imgui.SameLine(0, vc.z(GAP));
        if vc.button('Saved##tint_sav_' .. id, nil, RESET_W) then pick = 'saved'; end
        if imgui.IsItemHovered() then imgui.SetTooltip('Back to the color last saved'); end
        return pick;
    end

    vc.section('QUICK SCHEME', 'all colors from two');
    local scheme_changed = false;
    local SCHEME = { { 'main', 'Main', 'main' }, { 'second', 'Dark and gray parts', 'dark' } };
    for _, part in ipairs(SCHEME) do
        local pick = color_row('scheme_' .. part[1], part[2], tint.scheme[part[1]]);
        local from = pick and (pick == 'default' and defaults or saved)[part[3]];
        if from then
            tint.scheme[part[1]] = to_floats({ main = from }).main;
            scheme_changed, finished = true, true;
        end
    end

    vc.section('EACH COLOR', 'click a color to open its panel');
    local labels = core.color_labels(target.mod, target.rel);
    for _, name in ipairs(core.COLOR_NAMES) do
        if tint.edit[name] then
            local pick = color_row(name, labels[name] or name, tint.edit[name]);
            local from = pick and (pick == 'default' and defaults or saved)[name];
            if from then
                tint.edit[name] = to_floats({ [name] = from })[name];
                tint.unsaved, finished = true, true;
            end
        end
    end

    -- each open panel is its own window, so several stay open at once
    local slot_name = slot_label(tint.slot);
    local panels = {};
    for _, part in ipairs(SCHEME) do
        panels[#panels + 1] = { id = 'scheme_' .. part[1], title = part[2], color = tint.scheme[part[1]], scheme = true };
    end
    for _, name in ipairs(core.COLOR_NAMES) do
        if tint.edit[name] then panels[#panels + 1] = { id = name, title = labels[name] or name, color = tint.edit[name] }; end
    end
    for _, panel in ipairs(panels) do
        local open = tint.open[panel.id];
        if open and open[1] then
            local flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize or 64, ImGuiWindowFlags_NoCollapse or 32);
            if imgui.Begin(('%s, %s##tint_panel_%s'):format(panel.title, slot_name, panel.id), open, flags) then
                if imgui.ColorPicker3('##tint_pick_' .. panel.id, panel.color) then
                    if panel.scheme then scheme_changed = true; else tint.unsaved = true; end
                end
                if imgui.IsItemDeactivatedAfterEdit() then finished = true; end
                if vc.button('Close##tint_close_' .. panel.id, nil, 76) then open[1] = false; end
            end
            imgui.End();
        end
    end
    if scheme_changed then    -- the two scheme colors make all the others
        local bytes = to_bytes({ main = tint.scheme.main, dark = tint.scheme.second });
        tint.edit = to_floats(core.color_scheme(defaults, bytes.main, bytes.dark));
        tint.unsaved = true;
    end
    if finished and tint.live[1] then core.paint(target.mod, target.rel, to_bytes(tint.edit), false); end

    imgui.Dummy({ 0, vc.z(4) });
    imgui.SetNextItemWidth(vc.z(COMBO_W));
    imgui.InputTextWithHint('##tint_name', 'Name', tint.name, 48);
    imgui.SameLine();
    local named = tint.name[1] ~= '';
    if vc.button('Save', named and 'primary' or nil, 76) and named then
        core.save_colors(target.mod, target.rel, tint.name[1], to_bytes(tint.edit));
        tint.chosen = tint.name[1];
        tint.unsaved = false;
        tint.name[1] = core.next_color_name(target.mod, target.rel, target.name);
    end
    if core.is_recolored_copy(target) then
        imgui.SameLine();
        if vc.button('Reset to original', nil, 150) and core.redetect_colors(tint.slot) then tint.key = nil; end
    end
    if vc.button('Preview', 'primary', 76) then core.paint(target.mod, target.rel, to_bytes(tint.edit), false); end
    imgui.SameLine();
    if vc.button('Revert', nil, 76) then
        local saved = core.saved_colors(target.mod, target.rel);
        tint.edit = to_floats(saved);
        tint.unsaved = false;
        core.paint(target.mod, target.rel, saved, false);
    end
    imgui.SameLine();
    if vc.button('Defaults', nil, 76) then
        tint.edit = to_floats(core.default_colors(target.mod, target.rel));
        tint.unsaved = true;
        if tint.live[1] then core.paint(target.mod, target.rel, to_bytes(tint.edit), false); end
    end
    if tint.unsaved then
        vc.note('Previewing. Save keeps these colors under the name, Revert goes back to the colors last worn. Unsaved colors go back when TransMog loads.');
    end
    if core.status ~= '' then vc.note(core.status); end

    local saves = core.color_saves(target.mod, target.rel);    -- this piece's own saves
    vc.section('SAVED COLORS', target.name);
    if #saves == 0 then
        vc.note(('No saved colors for %s yet. Name the colors and choose Save.'):format(target.name));
    else
        local chosen = saves[1];
        for _, save in ipairs(saves) do
            if save.name == tint.chosen then chosen = save; end
        end
        imgui.SetNextItemWidth(vc.z(COMBO_W));
        if imgui.BeginCombo('##tint_saves', chosen.name) then
            for _, save in ipairs(saves) do
                if imgui.Selectable(save.name .. '##tint_save', save == chosen) then tint.chosen = save.name; end
            end
            imgui.EndCombo();
        end
        imgui.SameLine();
        if vc.button('Wear##tint_save', 'primary', 76) then
            tint.edit = to_floats(chosen.palette);
            tint.unsaved = false;
            tint.name[1] = chosen.name;
            core.paint(target.mod, target.rel, chosen.palette, true);
        end
        imgui.SameLine();
        if vc.button('Delete##tint_save', 'danger', 76) then
            core.delete_color_save(target.mod, target.rel, chosen.name);
            tint.chosen = nil;
        end
    end
    vc.note('Your armor redraws to show a change, so you blink for a moment. Only you see the colors.');
end;

-- the Race page: race and sex as two rows of buttons; Mithra are only female and Galka only male
local RACE_NAMES = { 'Hume', 'Elvaan', 'Tarutaru', 'Mithra', 'Galka' };

local function race_entry(id)
    for _, entry in ipairs(core.RACES) do
        if entry.id == id then return entry; end
    end
end

local function race_id(race, sex)
    local any;
    for _, entry in ipairs(core.RACES) do
        if entry.race == race then
            any = any or entry.id;
            if entry.sex == sex then return entry.id; end
        end
    end
    return any;
end

local function race_text(id)
    local entry = race_entry(id);
    return entry and (entry.race .. ' ' .. entry.sex:lower()) or 'Unknown';
end

PAGES.race = function ()
    vc.title('Race', 'Another race, face, hair and size, on your screen only');
    local now, own = core.race();
    if not own then
        vc.note('Your own race shows here once you are in game.');
        return;
    end
    local current = race_entry(now) or race_entry(own);
    vc.section('RACE');
    vc.label_row('Race', 420);
    local opts = {};
    for _, name in ipairs(RACE_NAMES) do opts[#opts + 1] = { name, name }; end
    local race = vc.seg('race_pick', opts, current.race);
    if race then core.set_race(race_id(race, current.sex)); end
    vc.label_row('Sex', 420);
    local sex = vc.seg('sex_pick', { { 'Male', 'Male' }, { 'Female', 'Female' } }, current.sex);
    if sex then core.set_race(race_id(current.race, sex)); end
    if current.race == 'Mithra' or current.race == 'Galka' then
        vc.note(('%s are only %s.'):format(current.race, current.race == 'Mithra' and 'female' or 'male'));
    end

    -- face and hair are one number: faces 1 to 8, each with hair A or B
    local face, own_face = core.face();
    vc.section('FACE AND HAIR');
    if face then
        vc.label_row('Face', 420);
        local faces = {};
        for n = 1, 8 do faces[#faces + 1] = { n, tostring(n) }; end
        local picked_face = vc.seg('face_pick', faces, math.floor(face / 2) + 1);
        if picked_face then core.set_face((picked_face - 1) * 2 + face % 2); end
        vc.label_row('Hair', 420);
        local hair = vc.seg('hair_pick', { { 0, 'A' }, { 1, 'B' } }, face % 2);
        if hair then core.set_face(face - face % 2 + hair); end
    else
        vc.note('Your face shows here once you are in game.');
    end

    -- size: a scale of your own, from half to twice
    vc.section('SIZE');
    vc.label_row('Size', 420);
    imgui.SetNextItemWidth(vc.z(COMBO_W));
    local size = { core.size() * 100 };
    if imgui.SliderFloat('##race_size', size, 50, 200, '%.0f%%') then core.set_size(size[1] / 100); end

    vc.section('NOW');
    vc.stat('Drawn as', race_text(now), now ~= own and VC.teal or nil);
    vc.stat('Your own', race_text(own));
    if face and own_face then
        local function face_text(f) return ('Face %d%s'):format(math.floor(f / 2) + 1, f % 2 == 0 and 'A' or 'B'); end
        vc.stat('Face', face_text(face) .. (face ~= own_face and ('   (your own: ' .. face_text(own_face) .. ')') or ''),
            face ~= own_face and VC.teal or nil);
    end
    vc.stat('Size', ('%.0f%%'):format(core.size() * 100), core.size() ~= 1 and VC.teal or nil);
    local changed = now ~= own or (face and own_face and face ~= own_face) or core.size() ~= 1;
    if changed and vc.button('Back to my own', 'primary', 140) then
        core.set_race(nil); core.set_face(nil); core.set_size(nil);
    end
    vc.note('Only you see this: others see your real look, and nothing goes to the server. Every load starts on your own.');
    vc.note('Each piece shows as it looks on that race. Recolored copies are made for each race, so a piece you recolored shows its own colors until you recolor it on this race too.');
end;

PAGES.about = function ()
    vc.title('About', 'TransMog ' .. addon.version);
    vc.section('HOW IT WORKS');
    vc.note('Mods are DAT overlays, so your game files are never changed. A change shows after you zone, and only you see it.');
    vc.section('ADDING A MOD');
    vc.note(('Put a folder in %s\\TransMog, laid out like the FFXI folder (ROM\\351\\101.DAT). Add a transmog.json to name it and file it under a page.'):format(core.root()));
    vc.stat('Mods', tostring(#core.mods));
    vc.stat('On', tostring(core.enabled_count()));
    if core.status ~= '' then
        vc.section('LAST CHANGE');
        vc.note(core.status);
    end
end;

local function sidebar(nav)
    if nav.head('equip', 'Lockstyle', win.page == 'lock') then win.page = 'lock'; end
    if nav.head('list', 'Job LockStyles', win.page == 'sets') then win.page = 'sets'; end
    if nav.head('spark', 'Colors', win.page == 'colors') then win.page = 'colors'; end
    if nav.head('star', 'Effects', win.page == 'effects') then win.page = 'effects'; end
    if nav.head('test', 'Race', win.page == 'race') then win.page = 'race'; end
    nav.caption('DAT MODS');
    for _, category in ipairs(core.CATEGORIES) do
        if nav.head(ICONS[category], core.TITLES[category], win.page == category) then win.page = category; end
    end
    nav.gap();
    if nav.head('about', 'About', win.page == 'about') then win.page = 'about'; end
    nav.caption('TOOLS');
    if nav.head('refresh', 'Rescan', false) then
        core.scan();
        core.apply();
    end
end

local WINDOW = {
    id       = 'transmog',
    title    = 'TransMog',
    size     = { 720, 760 },
    min      = { 620, 620 },
    pages    = PAGES,
    sidebar  = sidebar,
    scaler   = true,
    on_scale = function (s) core.config.data.ui_scale = s; core.config:save(); end,
    subtitle = function (page)
        return core.TITLES[page] or ({ lock = 'Lockstyle', sets = 'Job LockStyles', colors = 'Colors', effects = 'Effects', race = 'Race' })[page] or 'About';
    end,
    header_right = function ()
        if core.mount_pending then return 'Mount changes required to zone to apply', VC.gold; end
        return ('%d on'):format(core.enabled_count()), VC.teal;
    end,
};

ashita.events.register('load', 'transmog_load', function ()
    core.start();
end);

ashita.events.register('unload', 'transmog_unload', function ()
    core.frame(false);    -- gives the camera back
end);

ashita.events.register('d3d_present', 'transmog_present', function ()
    win.scale = tonumber(core.config.data.ui_scale) or 1;
    vc.safe(core.tick);
    vc.window(win, WINDOW);
    vc.safe(core.frame, win.open[1] and core.config.data.frame_me == true);
end);

-- pages /tm opens by name
local PAGE_NAMES = { lockstyle = 'lock', lock = 'lock', sets = 'sets', jobs = 'sets', colors = 'colors', effects = 'effects',
                     race = 'race', mounts = 'mount', gear = 'gear', weapons = 'weapon', other = 'other', about = 'about' };

ashita.events.register('command', 'transmog_command', function (e)
    local args = e.command:args();
    local name = #args > 0 and args[1]:lower() or '';
    if name ~= '/transmog' and name ~= '/tm' then return; end
    e.blocked = true;
    if #args == 1 then
        win.open[1] = not win.open[1];
    elseif #args == 2 and PAGE_NAMES[args[2]:lower()] then    -- a page by name: /tm race, /tm colors
        win.page, win.open[1] = PAGE_NAMES[args[2]:lower()], true;
    else
        core.command(args);
    end
end);
