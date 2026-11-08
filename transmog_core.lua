--[[
What TransMog does, apart from its window. Each mod is a folder laid out like the FFXI folder, kept in
<pivot rootfolder>\TransMog\<mod>. An enabled mod goes first in [pivot.order], ahead of ffxi-hd and
the server's own DATs. The launcher rebuilds [pivot.order] at every start, so what's enabled is kept
in this addon's settings and put back when it loads: keep the load line in scripts\boot.txt.

This is a file of its own because the word vana. in TransMog.lua would make VanaCore load it as a
VanaCore addon, without the Ashita libraries vcmenu needs.
--]]

local core = {}
local colors = require('transmog_colors')
core.COLOR_NAMES, core.COLOR_LABELS = colors.NAMES, colors.LABELS

local MOUNT_FILE_BASE = 102705    -- a mount's file id is this plus its id in vana.gamedata.mounts
local RAPTOR_COPIES = { 102705, 102768 }    -- byte-identical to the Raptor's own file
local MOUNT_KEY_ITEM_BASE = 3072    -- a mount's companion key item is this plus its id
local EXTRA_MOUNTS = { [50] = 'Gyokko' }    -- in the game, not yet in vana.gamedata.mounts
local MAX_ORDER = 63
local ARMOR_TABLE = 0x35D380    -- in FFXiMain.dll
local ARMOR_ROWS = { head = 1, body = 2, hands = 3, legs = 4, feet = 5 }
local MODEL_ROWS = { head = 1, body = 2, hands = 3, legs = 4, feet = 5, main = 6, sub = 7, range = 8 }
local ARMOR_ROW_SIZE = 0x30
local ARMOR_RANGES = 6
local LOOK_ID_BASE = 0x100000   -- past any item id
local LOOK_ID_SLOT = 0x1000
local PREFIX = 'TransMog\\'
local MANIFEST = 'transmog.json'
local RECOLOR_MANIFEST = 'recolor.json'
local COLORS_MOD = 'transmog-colors'   -- copies of normal pieces, recolored: each a private copy only you wear
local COLORS_TITLE = 'Recolored gear'

core.CATEGORIES = { 'mount', 'gear', 'weapon', 'other' }
core.TITLES = { mount = 'Mounts', gear = 'Gear', weapon = 'Weapons', other = 'Other' }

local config = vana.settings.register({
    defaults = { enabled = {}, ui_scale = 1, lock = false, picks = {}, sets = {}, real = {}, match_slot = '', job_sets = {}, loaded = {}, colors = {}, color_saves = {}, effects = {}, private = {}, frame_me = false, frame_distance = 4.5, frame_shift = 0.3 },
})

core.config = config
core.mods = {}         -- { folder, title, category, files } by name order
core.conflicts = {}    -- file -> the enabled mods that have it, when two or more do
core.owners = {}       -- file -> the enabled mods that have it
core.changers = {}     -- slot key -> model -> the titles of the mods that change it, or false
core.looks = {}        -- pick id -> a look of an enabled mod's own, on a model no item uses
core.mounts = {}       -- { id, name } for mounts that have a model file
core.pending = false   -- a change is waiting for the next zone
core.mount_pending = false   -- one of them a mount mod turned on or off
core.status = ''

local function say(text)
    core.status = text
    print('[TransMog] ' .. text)
end

function core.root()
    local path = vana.config.get('pivot', 'rootfolder', 'pivot')
    if path:match('^%a:') then return path end
    return vana.paths.install .. '\\' .. path
end

local function read_file(path, offset, size)
    local f = io.open(path, 'rb')
    if not f then return nil end
    if offset then f:seek('set', offset) end
    local data = f:read(size or '*a')
    f:close()
    return data
end

local function other_overlays()
    local list = {}
    for i = 0, MAX_ORDER do
        local entry = vana.config.get('pivot.order', tostring(i))
        if entry and entry:sub(1, #PREFIX):lower() ~= PREFIX:lower() then
            list[#list + 1] = entry
        end
    end
    return list
end

-- where the game gets a file when TransMog has no say in it
local function served(rel)
    for _, overlay in ipairs(other_overlays()) do
        local path = overlay:match('^%a:') and overlay or (core.root() .. '\\' .. overlay)
        if vana.fs.exists(path .. '\\' .. rel) then
            return path .. '\\' .. rel
        end
    end
    local path = vana.paths.game .. '\\' .. rel
    return vana.fs.exists(path) and path or nil
end

-- 'ROM\351\101.DAT' for a file id, by the tables the game reads, which are read once
local vtable_data, ftable_data
local function read_path(id)
    if vtable_data == nil then
        local vtable, ftable = served('VTABLE.DAT'), served('FTABLE.DAT')
        vtable_data = vtable and read_file(vtable) or false
        ftable_data = ftable and read_file(ftable) or false
    end
    if not vtable_data or not ftable_data or id * 2 + 2 > #ftable_data or id + 1 > #vtable_data then return nil end
    local rom = vtable_data:byte(id + 1)
    if rom == 0 then return nil end
    local value = ftable_data:byte(id * 2 + 1) + ftable_data:byte(id * 2 + 2) * 256
    local folder = rom == 1 and 'ROM' or ('ROM' .. rom)
    return ('%s\\%d\\%d.DAT'):format(folder, math.floor(value / 128), value % 128)
end

-- the same, kept, as the window asks every frame
local paths = {}
local function file_path(id)
    if paths[id] == nil then paths[id] = read_path(id) or false end
    return paths[id] or nil
end

local function is_mount_file(rel)
    local path = rel and served(rel)
    return path ~= nil and read_file(path, 0, 4) == 'moun'
end

local function find_mount(name)
    for _, mount in ipairs(core.mounts) do
        if mount.name:lower() == name:lower() then return mount end
    end
end

local function load_mounts()
    core.mounts = {}
    local names = {}
    for id, row in pairs(vana.gamedata.all('mounts')) do names[id] = row.name end
    for id, name in pairs(EXTRA_MOUNTS) do names[id] = name end
    for id, name in pairs(names) do
        if id > 0 and name ~= '' and is_mount_file(file_path(MOUNT_FILE_BASE + id)) then
            core.mounts[#core.mounts + 1] = { id = id, name = name }
        end
    end
    table.sort(core.mounts, function (a, b) return a.name < b.name end)
end

-- the mounts you have: each is a key item
function core.owned_mounts()
    local bits = vana.game.key_items()
    local owned = {}
    if not bits then return owned end
    for _, mount in ipairs(core.mounts) do
        local id = MOUNT_KEY_ITEM_BASE + mount.id
        local byte = bits:byte(math.floor(id / 8) + 1) or 0
        if math.floor(byte / 2 ^ (id % 8)) % 2 == 1 then
            owned[#owned + 1] = mount
        end
    end
    return owned
end

-- a transmog.json can name looks of its own: { slot, model, race, name, icon, hides }, where icon is an item's and
-- hides lists slots the look covers (a hood: { "head" }), shown bare while it's worn
local function add_looks(looks, title)
    for _, look in ipairs(looks or {}) do
        local id = LOOK_ID_BASE + ARMOR_ROWS[look.slot] * LOOK_ID_SLOT + look.model
        core.looks[id] = { id = id, key = look.slot, model_id = look.model, race = look.race, name = look.name,
                           lower = look.name:lower(), icon = look.icon, title = title, hides = look.hides }
    end
end

function core.scan()
    core.mods = {}
    core.conflicts = {}
    core.looks = {}
    local base = core.root() .. '\\TransMog'
    vana.fs.create_dir(base)
    local owners = {}
    for _, folder in ipairs(vana.fs.list(base, '', 'folders') or {}) do
        local path = base .. '\\' .. folder
        local text = read_file(path .. '\\' .. MANIFEST)
        local info = text and vana.json.decode(text) or {}
        local mod = { folder = folder, title = info.title or folder,
                      category = core.TITLES[info.category] and info.category or 'other', look = info.look, files = {},
                      path = path, recolor = vana.fs.exists(path .. '\\' .. RECOLOR_MANIFEST) }
        for _, rel in ipairs(vana.fs.list(path, '', { which = 'files', deep = true }) or {}) do
            if rel:lower() ~= MANIFEST then
                mod.files[#mod.files + 1] = rel
                if config.data.enabled[folder] and rel:lower() ~= RECOLOR_MANIFEST then   -- recolor.json never reaches the game
                    local key = rel:lower()
                    owners[key] = owners[key] or {}
                    table.insert(owners[key], mod.title)
                end
            end
        end
        core.mods[#core.mods + 1] = mod
        if config.data.enabled[folder] then add_looks(info.looks, mod.title) end
    end
    table.sort(core.mods, function (a, b) return a.title:lower() < b.title:lower() end)
    for rel, list in pairs(owners) do
        if #list > 1 then core.conflicts[rel] = list end
    end
    core.owners = owners
    core.changers = {}
    colors.forget()
end

-- Mount descriptions: the help line the game shows for a highlighted mount ("Calls forth a raptor.") is one d_msg
-- file with a 256-byte record per mount, by its id, the text at byte 0x28 (215 letters at most). TransMog's own mod
-- adds the look to it for each mount with a look mod on: "Calls forth a raptor. Looks like: Deluxe Unicorn." The
-- name stays, so /mount and macros are untouched (a renamed mount list renames the commands too). The game reads
-- the file at login, and nothing goes to the server.
local NAMES_MOD = 'mount-names'
local DESC_FILE = 'ROM\\351\\85.DAT'
local OLD_NAMES_FILE = 'ROM\\351\\84.DAT'    -- the mount list this mod used to rename
local TEXT_AT, RECORD, RECORDS_AT, TEXT_MAX = 0x28, 256, 0x40, 215

local function describe_record(data, index, add)
    local at = RECORDS_AT + index * RECORD
    if at + RECORD > #data then return data end
    local rec = data:sub(at + 1, at + RECORD)
    local text = rec:sub(TEXT_AT + 1):match('^[^%z]*')
    text = (text .. ' ' .. add):sub(1, TEXT_MAX)
    local new = rec:sub(1, TEXT_AT) .. text .. string.rep('\0', RECORD - TEXT_AT - #text)
    return data:sub(1, at) .. new .. data:sub(at + RECORD + 1)
end

-- the look a mount mod puts on: its own look, or the end of its title ("Bomb as Red Rooster")
local function look_of(mod)
    return mod.look or mod.title:match(' as (.+)$')
end

local function update_mount_names()
    local looks = {}
    for _, mount in ipairs(core.mounts or {}) do
        local rel = file_path(MOUNT_FILE_BASE + mount.id)
        for _, mod in ipairs(core.mods) do
            if rel and mod.category == 'mount' and config.data.enabled[mod.folder] and look_of(mod) then
                for _, file in ipairs(mod.files) do
                    if file:lower() == rel:lower() then looks[mount.id] = look_of(mod) end
                end
            end
        end
    end
    local folder = core.root() .. '\\TransMog\\' .. NAMES_MOD
    if vana.fs.exists(folder .. '\\' .. OLD_NAMES_FILE) then vana.fs.remove(folder .. '\\' .. OLD_NAMES_FILE) end
    if next(looks) == nil then
        if config.data.enabled[NAMES_MOD] then
            config.data.enabled[NAMES_MOD] = nil
            config:save()
        end
        return
    end
    local source = served(DESC_FILE)    -- the game's or the server's, never this mod's own copy
    local data = source and read_file(source)
    if not data or data:sub(1, 5) ~= 'd_msg' then return end
    for id, look in pairs(looks) do data = describe_record(data, id, ('Looks like: %s.'):format(look)) end
    local fresh = not vana.fs.exists(folder .. '\\' .. MANIFEST)
    if not vana.fs.create_dir(folder .. '\\' .. DESC_FILE:match('^(.*)\\[^\\]+$'))
        or not vana.fs.write(folder .. '\\' .. DESC_FILE, data) then return end
    local manifest = vana.json.encode({ title = 'Mount descriptions', category = 'other' })
    if read_file(folder .. '\\' .. MANIFEST) ~= manifest then vana.fs.write(folder .. '\\' .. MANIFEST, manifest) end
    if not config.data.enabled[NAMES_MOD] then
        config.data.enabled[NAMES_MOD] = true
        config:save()
    end
    if fresh then core.scan() end
end

-- enabled mods first, then the overlays the launcher set up, in their order
function core.apply()
    update_mount_names()
    local order = {}
    for _, mod in ipairs(core.mods) do
        if config.data.enabled[mod.folder] then
            order[#order + 1] = PREFIX .. mod.folder
        end
    end
    for _, overlay in ipairs(other_overlays()) do
        order[#order + 1] = overlay
    end
    for i = 0, MAX_ORDER do
        local key = tostring(i)
        local want = order[i + 1]
        if vana.config.get('pivot.order', key) ~= want then
            vana.config.set('pivot.order', key, want)
        end
    end
end

function core.is_enabled(mod)
    return config.data.enabled[mod.folder] == true
end

function core.enabled_count()
    local count = 0
    for _, mod in ipairs(core.mods) do
        if core.is_enabled(mod) then count = count + 1 end
    end
    return count
end

-- a mount has one look: turns off the other mount mods that replace a file of this one, and returns their titles
local function turn_off_rivals(mod)
    local files, titles = {}, {}
    for _, rel in ipairs(mod.files) do files[rel:lower()] = true end
    for _, other in ipairs(core.mods) do
        if other ~= mod and other.category == 'mount' and core.is_enabled(other) then
            for _, rel in ipairs(other.files) do
                if files[rel:lower()] then
                    config.data.enabled[other.folder] = nil
                    titles[#titles + 1] = other.title
                    break
                end
            end
        end
    end
    return titles
end

-- what the game has in memory: the mods that were on at the last zone
local function mark_loaded()
    config.data.loaded = {}
    for folder in pairs(config.data.enabled) do config.data.loaded[folder] = true end
    config:save()
    core.pending, core.mount_pending = false, false
end

local function update_pending()
    core.pending, core.mount_pending = false, false
    for _, mod in ipairs(core.mods) do
        if core.is_enabled(mod) ~= (config.data.loaded[mod.folder] == true) then
            core.pending = true
            if mod.category == 'mount' then core.mount_pending = true end
        end
    end
end

-- 'loaded', 'zone_load', 'zone_remove', or nil for a mod that's off
function core.mod_state(mod)
    local on, loaded = core.is_enabled(mod), config.data.loaded[mod.folder] == true
    if on and loaded then return 'loaded' end
    if on then return 'zone_load' end
    if loaded then return 'zone_remove' end
    return nil
end

function core.delete_mod(mod)
    if mod.look then
        say(('%s supplies the %s look, so it stays.'):format(mod.title, mod.look))
        return
    end
    local path = core.root() .. '\\TransMog\\' .. mod.folder
    config.data.enabled[mod.folder] = nil
    config:save()
    core.scan()
    core.apply()
    for _, rel in ipairs(vana.fs.list(path, '', { which = 'files', deep = true }) or {}) do
        vana.fs.remove(path .. '\\' .. rel)
    end
    local folders = vana.fs.list(path, '', { which = 'folders', deep = true }) or {}
    table.sort(folders, function (a, b) return #a > #b end)
    for _, rel in ipairs(folders) do vana.fs.remove(path .. '\\' .. rel) end
    local gone = vana.fs.remove(path)
    core.scan()
    update_pending()
    say(gone and ('Deleted %s.'):format(mod.title) or ('Could not delete %s.'):format(mod.title))
end

function core.set_enabled(mod, on)
    local replaced = on and mod.category == 'mount' and turn_off_rivals(mod) or {}
    config.data.enabled[mod.folder] = on or nil
    config:save()
    core.scan()
    core.apply()
    update_pending()
    local text = ('%s is %s. It shows after you zone.'):format(mod.title, on and 'on' or 'off')
    if #replaced > 0 then
        text = ('%s Turned off %s.'):format(text, table.concat(replaced, ', '))
    end
    say(text)
end

function core.find_mod(text)
    for _, mod in ipairs(core.mods) do
        if mod.folder:lower() == text:lower() or mod.title:lower() == text:lower() then return mod end
    end
end

-- the looks made for TransMog: a mount mod whose transmog.json names one can dress any other mount
function core.mount_looks()
    local looks = {}
    for _, mod in ipairs(core.mods) do
        local rel = mod.look and mod.files[1]
        if rel then
            looks[#looks + 1] = { name = mod.look, file = core.root() .. '\\TransMog\\' .. mod.folder .. '\\' .. rel }
        end
    end
    table.sort(looks, function (a, b) return a.name < b.name end)
    return looks
end

function core.create_mount_swap(to, from)
    local source = from.file or served(file_path(MOUNT_FILE_BASE + from.id))
    local data = source and read_file(source)
    if not data then
        say('Could not read the model for ' .. from.name .. '.')
        return nil
    end
    local ids = { MOUNT_FILE_BASE + to.id }
    if to.name == 'Raptor' then
        for _, id in ipairs(RAPTOR_COPIES) do ids[#ids + 1] = id end
    end
    local slug = function (name) return (name:lower():gsub('[^%w]+', '-')) end
    local folder = ('mount-%s-as-%s'):format(slug(to.name), slug(from.name))
    local path = core.root() .. '\\TransMog\\' .. folder
    for _, id in ipairs(ids) do
        local rel = file_path(id)
        local parent = rel and (path .. '\\' .. rel:match('^(.*)\\[^\\]+$'))
        if not parent or not vana.fs.create_dir(parent) or not vana.fs.write(path .. '\\' .. rel, data) then
            say('Could not write the files for ' .. folder .. '.')
            return nil
        end
    end
    vana.fs.write(path .. '\\' .. MANIFEST, vana.json.encode({ title = to.name .. ' as ' .. from.name, category = 'mount' }))
    core.scan()
    return core.find_mod(folder)
end

-- what the commands after /transmog do; true if it was one of them
function core.command(args)
    local action = (args[2] or ''):lower()
    if action == 'list' then
        for _, mod in ipairs(core.mods) do
            print(('[TransMog] %s %s (%s)'):format(core.is_enabled(mod) and '[on] ' or '[off]', mod.folder, mod.title))
        end
    elseif action == 'on' or action == 'off' then
        local name = table.concat(args, ' ', 3)
        local mod = core.find_mod(name)
        if mod then
            core.set_enabled(mod, action == 'on')
        else
            say('No mod called ' .. name .. '.')
        end
    elseif action == 'recolor' and args[3] then    -- the piece shown in a slot, as your own copy
        if core.make_recolorable(args[3]:lower()) then core.redraw() end
    elseif action == 'mount' and args[3] and args[4] then
        local to, from = find_mount(args[3]), find_mount(args[4])
        if to and from and to ~= from then
            local mod = core.create_mount_swap(to, from)
            if mod then core.set_enabled(mod, true) end
        else
            say('Those need to be two different mounts, one word each.')
        end
    elseif (action == 'save' or action == 'wear') and args[3] then    -- /tm save Red mage look, /tm wear Red mage look
        local name = table.concat(args, ' ', 3)
        if action == 'save' then
            core.save_set(name)
        elseif config.data.sets[name] then
            core.wear_set(name)
        else
            say('No saved set called ' .. name .. '.')
        end
    elseif action == 'effect' and args[3] and args[4] then    -- /tm effect main Coruscanti, /tm effect body own|off
        local key, name = args[3]:lower(), table.concat(args, ' ', 4)
        local choice
        if name:lower() == 'own' then
            choice = nil
        elseif name:lower() == 'off' then
            choice = 'off'
        else
            for _, entry in ipairs(key == 'body' and core.effect_choices().wings or core.effect_choices().glows) do
                if entry.name:lower() == name:lower() then choice = entry.name end
            end
        end
        if not core.EFFECT_SLOTS[key] then
            say('Effects go on body, main, sub or range.')
        elseif choice == nil and name:lower() ~= 'own' then
            say('No effect called ' .. name .. '.')
        else
            core.set_effect(key, choice)
        end
    elseif action == 'race' and args[3] then    -- /tm race elvaan female, /tm race own
        local want, sex = args[3]:lower(), (args[4] or ''):lower()
        local pick
        for _, entry in ipairs(core.RACES) do
            if entry.race:lower() == want and (sex == '' or entry.sex:lower() == sex) then pick = pick or entry.id end
        end
        if want == 'own' or pick then core.set_race(pick) else say('Races: hume, elvaan, tarutaru, mithra, galka, then male or female; or own.') end
    elseif action == 'face' and args[3] then    -- /tm face 3b, /tm face own
        local n, hair = args[3]:lower():match('^([1-8])([ab]?)$')
        if args[3]:lower() == 'own' then
            core.set_face(nil)
        elseif n then
            core.set_face((tonumber(n) - 1) * 2 + (hair == 'b' and 1 or 0))
        else
            say('Faces: 1a to 8b; or own.')
        end
    elseif action == 'size' and args[3] then    -- /tm size 120, /tm size own
        local pct = tonumber((args[3]:gsub('%%', '')))
        if args[3]:lower() == 'own' then
            core.set_size(nil)
        elseif pct and pct >= 50 and pct <= 200 then
            core.set_size(pct / 100)
        else
            say('Size: 50 to 200 (percent of your own); or own.')
        end
    else
        print('[TransMog] /tm, /tm list, /tm on|off <mod>, /tm mount <target> <look>, /tm recolor <slot>, /tm save|wear <set>, /tm effect <slot> <name|own|off>, /tm race <race> [sex], /tm face <1a-8b>, /tm size <50-200>')
    end
end

-- Lockstyle: your own character is drawn in the picked pieces, in this client only. A look is written
-- to the entity and the game told to reload the model. The server's appearance packets would put your
-- real gear back, so the picked slots are rewritten in them as they arrive.

local ENTITY_TABLE = 0x47E980      -- from FFXiMain.dll
local ENTITY_FLAGS = 0xF4          -- ModelUpdateFlags
local ENTITY_LOOK = 0xFC           -- hair, then the slots in the order of core.SLOTS
local ENTITY_RACE = 0xEF           -- the race the character is drawn as: 1 to 8, as core.RACES
local ENTITY_SIZE = 0x204          -- the character's scale: -1 for the race's own size
core.FACES = 16                    -- face and hair in one number: faces 1 to 8, each with hair A and B
local RELOAD = 1                   -- VanaCore's hook lets the player's reload through only with this bit
local SYNC_TIME = 0.5              -- seconds between looks at what's drawn
local REDRAW_TIME = 0.4            -- seconds core.redraw leaves the armor off
local EFFECT_CHECK_TIME = 1        -- seconds between looks at whether a slot's effect is on what it shows
local next_effect_check = 0
local JOB_CHECK_TIME = 1           -- seconds between looks at your job
local LAST_JOB = 22                -- Rune Fencer: the ids after it aren't jobs you can be
local PACKET_LOOK = { [0x051] = 0x06, [0x00A] = 0x46, [0x00D] = 0x4A }
local STATUS_UPDATE = 0x1F         -- 0x00D's flags when it carries a look

core.SLOTS = {
    { key = 'head',   label = 'Head',   prefix = 0x1000 },
    { key = 'body',   label = 'Body',   prefix = 0x2000 },
    { key = 'hands',  label = 'Hands',  prefix = 0x3000 },
    { key = 'legs',   label = 'Legs',   prefix = 0x4000 },
    { key = 'feet',   label = 'Feet',   prefix = 0x5000 },
    { key = 'main',   label = 'Main',   prefix = 0x6000 },
    { key = 'sub',    label = 'Sub',    prefix = 0x7000 },
    { key = 'range',  label = 'Ranged', prefix = 0x8000 },
}
core.LIST_LIMIT = 400

local item_lists = {}     -- slot key -> { id, name, lower } by name, for your race
local look_lists = {}     -- slot key -> one row per look, with the pieces that share it
local index
local next_sync, dirty = 0, false
local redraw_at                    -- when the armor blanked by core.redraw goes back on
local redraw_looks = {}            -- address -> the look it had before core.redraw blanked it
local next_job_check, last_job = 0, nil

local function find_self()
    local id = vana.game.self()
    if not id then return nil end
    if index then
        local entity = vana.game.entity(index)
        if entity and entity.id == id then return entity end
    end
    for i = 0, vana.game.entity_count() - 1 do
        local entity = vana.game.entity(i)
        if entity and entity.id == id then
            index = i
            return entity
        end
    end
end

local function self_address()
    local table_at = vana.memory.module('FFXiMain.dll') + ENTITY_TABLE
    local address = vana.memory.read_uint32(table_at + index * 4)
    return address ~= 0 and address or nil
end

-- what a pick id stands for: a mod's look or an item
local function piece(id)
    return core.looks[id or 0] or vana.gamedata.items[id or 0]
end

local private_model    -- (slot key, model) -> the model of your private copy of it, or the model; set further down
local drawable         -- (slot key, model) -> false when your race has no file for that model; set further down

-- whether a piece shows as itself on the race you're drawn as: a mod's look is made for one race's file, and on
-- another race its model number is some other piece or nothing; a model with no file on your race draws nothing
local function fits(key, item)
    if item.race then
        local entity = find_self()
        return not entity or entity.race == item.race
    end
    return private_model(key, item.model_id) ~= item.model_id or drawable(key, item.model_id)
end

local function picked_model(slot)
    for key, other in pairs(config.data.picks) do    -- a slot another picked look covers shows nothing
        local look = key ~= slot.key and core.looks[other]
        if look and look.hides and fits(key, look) then
            for _, hidden in ipairs(look.hides) do
                if hidden == slot.key then return slot.prefix end
            end
        end
    end
    local id = config.data.picks[slot.key]
    local item = id and piece(id)
    if not item or not fits(slot.key, item) then return nil end    -- one that doesn't fit: your own gear shows
    return slot.prefix + private_model(slot.key, item.model_id)
end

-- Your look, worn gear and own race are each character's own, each in its own file (characters/<name>.json beside
-- this addon): every character on this PC shares one settings file, and two games running at once would each save
-- over the other's. The settings keep only the character loaded in this game. A look from before this, with no name,
-- stays with the first character it draws on.
local CHARACTERS = 'characters/'
local char_name, char_saved    -- the character this game has loaded, and its file's text as last written

local function char_path(name)
    return addon.path .. CHARACTERS .. name .. '.json'
end

local function char_text()
    return vana.json.encode({ picks = config.data.picks, real = config.data.real, own_race = config.data.own_race,
                              locked = config.data.locked })
end

-- writes this character's file when its look, gear or race changed
local function save_character()
    if not char_name then return end
    local text = char_text()
    if text == char_saved then return end
    vana.fs.create_dir(addon.path .. 'characters')
    if vana.fs.write(char_path(char_name), text) then char_saved = text end
end

local function own_character(entity)
    local name = entity.name
    if not name or name == '' or char_name == name then return false end
    save_character()    -- a character change in this game: the last one's file is up to date first
    local text = read_file(char_path(name))
    local ok, mine = pcall(vana.json.decode, text or '')
    if not ok or type(mine) ~= 'table' then mine = nil end
    if not mine then
        mine = config.data.chars and config.data.chars[name]    -- kept in the settings for a while
        if not mine and (config.data.char_of == name or not config.data.char_of) then
            local all_fit = true    -- the look in the settings: this character's, when it draws on it
            for _, slot in ipairs(core.SLOTS) do
                local item = config.data.picks[slot.key] and piece(config.data.picks[slot.key])
                if item and not fits(slot.key, item) then all_fit = false end
            end
            if all_fit then
                mine = { picks = config.data.picks, real = config.data.real, own_race = config.data.own_race }
            end
        end
    end
    mine = mine or {}
    config.data.picks, config.data.real, config.data.own_race = mine.picks or {}, mine.real or {}, mine.own_race
    config.data.locked = mine.locked
    config.data.char_of, config.data.chars = name, nil
    char_name, char_saved = name, nil
    save_character()
    config:save()
    return true
end

-- With TransMog on, a slot with no piece picked (or one that doesn't fit your race) stays as it was when you turned
-- it on, as the game's own lockstyle does: config.data.locked, taken then. Off, it shows the gear you wear.
local lock_now    -- set below
local function locked_look(key)
    return config.data.lock and config.data.locked and config.data.locked[key] or nil
end

-- the look of the gear you wear, kept for TransMog on: taken once there is one to take
lock_now = function ()
    if not config.data.lock or config.data.locked or not next(config.data.real) then return end
    config.data.locked = {}
    for key, look in pairs(config.data.real) do config.data.locked[key] = look end
end

-- the models of two-handed weapons (and hand-to-hand): real gear never has anything in the sub slot with one
-- but a grip, which draws nothing, and the game draws one held beside a sub weapon low, on the ground
local TWO_HANDED_SKILLS = { [1] = true, [4] = true, [6] = true, [7] = true, [8] = true, [10] = true, [12] = true }
local two_handed_models
local function two_handed(model)
    if not two_handed_models then
        two_handed_models = {}
        for _, row in pairs(vana.gamedata.all('items')) do
            if TWO_HANDED_SKILLS[row.skill or 0] and (row.model_id or 0) > 0 then
                two_handed_models[row.model_id] = true
            end
        end
    end
    return two_handed_models[model] == true
end

-- the model the main hand shows, before any private copy of it
local function shown_main()
    if config.data.lock then
        local id = config.data.picks.main
        local item = id and piece(id)
        if item and fits('main', item) then return item.model_id end
    end
    local real = locked_look('main') or config.data.real.main
    return real and real % 0x1000 or nil
end

local function wanted(i, slot)
    if slot.key == 'sub' and two_handed(shown_main()) then return slot.prefix end
    local model = config.data.lock and picked_model(slot)
    if model then return model end
    local real = locked_look(slot.key) or config.data.real[slot.key]    -- your gear shows your private copy of it too
    return real and (real - real % 0x1000 + private_model(slot.key, real % 0x1000)) or nil
end

local own_face, own_size    -- what the game drew before the Race page changed it

local function sync()
    local entity = find_self()
    local address = entity and self_address()
    if not address then return end
    local changed = own_character(entity)
    -- the race you picked on the Race page, held through zones; with none picked, the race the server gives is yours
    local race = vana.memory.read_uint8(address + ENTITY_RACE)
    if config.data.race then
        if race ~= config.data.race then
            vana.memory.write_uint8(address + ENTITY_RACE, config.data.race)
            changed = true
        end
    elseif race >= 1 and race <= 8 and config.data.own_race ~= race then
        config.data.own_race = race
        config:save()
    end
    -- face and hair, and size, from the Race page: with none picked, what the game draws is your own
    local face = vana.memory.read_uint16(address + ENTITY_LOOK)
    if config.data.face then
        if face ~= config.data.face then
            vana.memory.write_uint16(address + ENTITY_LOOK, config.data.face)
            changed = true
        end
    elseif face < core.FACES then
        own_face = face
    end
    local size = vana.memory.read_float(address + ENTITY_SIZE)
    local want_size = config.data.size or own_size
    if want_size and math.abs(size - want_size) > 1e-4 then
        vana.memory.write_float(address + ENTITY_SIZE, want_size)    -- shows without a reload
    elseif not config.data.size then
        own_size = size
    end
    lock_now()    -- TransMog was on before there was a locked look (from before this, or no gear seen yet)
    for i, slot in ipairs(core.SLOTS) do
        local want = wanted(i, slot)
        local at = address + ENTITY_LOOK + i * 2
        if want and vana.memory.read_uint16(at) ~= want then
            vana.memory.write_uint16(at, want)
            changed = true
        end
    end
    if changed then
        vana.memory.write_uint16(address + ENTITY_FLAGS, RELOAD)
    end
    dirty = false
end

local function remember_real(data, offset)
    for i, slot in ipairs(core.SLOTS) do
        local at = offset + (i - 1) * 2
        config.data.real[slot.key] = data:byte(at + 1) + data:byte(at + 2) * 256
    end
end

local function rewrite(data, offset)
    -- the face byte and the race byte come just before the slots: the Race page's, so a server update doesn't blink
    local function put(at, value)
        if value and at >= 0 then data = data:sub(1, at) .. string.char(value) .. data:sub(at + 2) end
    end
    put(offset - 2, config.data.face)
    put(offset - 1, config.data.race)
    for i, slot in ipairs(core.SLOTS) do
        local model = config.data.lock and picked_model(slot)
        if not model then    -- the server's look (or the locked one), with your private copies in it
            local at = offset + (i - 1) * 2
            local real = locked_look(slot.key) or (data:byte(at + 1) + data:byte(at + 2) * 256)
            local own = private_model(slot.key, real % 0x1000)
            model = (own ~= real % 0x1000 or locked_look(slot.key)) and (real - real % 0x1000 + own) or nil
        end
        if model then
            local at = offset + (i - 1) * 2
            data = data:sub(1, at) .. string.char(model % 256, math.floor(model / 256)) .. data:sub(at + 3)
        end
    end
    return data
end

local function on_packet(e)
    local offset = PACKET_LOOK[e.id]
    if not offset or e.injected then return end
    if e.id == 0x00D then
        local b1, b2, b3, b4 = e.data:byte(5, 8)
        local id = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        if id ~= vana.game.self() or e.data:byte(0x0B) ~= STATUS_UPDATE then return end
    end
    local entity = find_self()
    if entity then own_character(entity) end    -- so the gear remembered is this character's
    remember_real(e.data, offset)
    if config.data.lock or next(config.data.private or {}) or config.data.race or config.data.face then
        e.data_modified = rewrite(e.data, offset)
    end
end

-- the short name of your main job, such as WAR
function core.current_job()
    local _, _, job = vana.game.self()
    local row = job and job > 0 and vana.gamedata.jobs[job]
    return row and row.short or nil
end

-- wears the set assigned to your job when your job changes, and when you log in
local function check_job()
    local now = vana.time.clock()
    if now < next_job_check then return end
    next_job_check = now + JOB_CHECK_TIME
    local job = core.current_job()
    if not job or job == last_job then return end
    last_job = job
    local name = config.data.job_sets[job]
    if name then core.wear_set(name) end
end

function core.tick()
    check_job()
    local now = vana.time.clock()
    if now >= next_effect_check then
        next_effect_check = now + EFFECT_CHECK_TIME
        local entity = find_self()
        if entity and own_character(entity) then dirty, next_sync = true, 0 end    -- this character's look, at once
        save_character()
        core.check_private()    -- once, as soon as you're in game
        core.check_effects()
    end
    if redraw_at and now >= redraw_at then
        redraw_at = nil
        local address = find_self() and self_address()
        if address then
            for at, look in pairs(redraw_looks) do vana.memory.write_uint16(at, look) end
            vana.memory.write_uint16(address + ENTITY_FLAGS, RELOAD)
        end
        dirty, next_sync = true, 0
    end
    if not (config.data.lock or dirty or config.data.race or config.data.face or config.data.size or own_face == nil
            or next(config.data.private or {})) then return end
    if now < next_sync then return end
    next_sync = now + SYNC_TIME
    sync()
end

local function sync_now()
    dirty = true
    next_sync = 0
end

-- the mods that are on and can be recolored
function core.recolorable()
    local list = {}
    for _, mod in ipairs(core.mods) do
        if mod.recolor and core.is_enabled(mod) then list[#list + 1] = mod end
    end
    return list
end

local function color_entry(mod, rel)
    local info = colors.info(mod.path)
    local entries = info and info.files[rel]
    return info, entries and entries[1]
end

-- one of a mod's files' built colors, { main = {r, g, b}, dark = ..., trim = ... } in 0 to 255
function core.default_colors(mod, rel)
    local info, entry = color_entry(mod, rel)
    return entry and entry.palette or info and info.palette or nil
end

-- what the Colors page calls each color of a file
function core.color_labels(mod, rel)
    local _, entry = color_entry(mod, rel)
    return entry and entry.labels or core.COLOR_LABELS
end

-- the colors saved for one of a mod's files, or its built ones
function core.saved_colors(mod, rel)
    local saved = config.data.colors[mod.folder]
    return saved and saved[rel] or core.default_colors(mod, rel)
end

-- paints one of a mod's files in these colors and redraws you. With save, they are kept and painted again whenever
-- TransMog loads.
function core.paint(mod, rel, palette, save)
    local changed, err = colors.apply(mod.path, palette, rel)
    if not changed or #changed == 0 then
        say(err or ('%s has no %s to recolor.'):format(mod.title, rel))
        return false
    end
    if save then
        config.data.colors[mod.folder] = config.data.colors[mod.folder] or {}
        config.data.colors[mod.folder][rel] = palette
        config:save()
    end
    core.redraw()
    say(('%s %s.'):format(save and 'Saved the colors of' or 'Previewing colors on', mod.title))
    return true
end

-- a whole color scheme from two colors: the piece's colored groups take main, its dark and gray ones take second,
-- each keeping how light it is next to the others it joins. Bright gray groups, metal and the like, stay as built.
local SCHEME_COLORED = 0.18    -- saturation from which a group counts as colored
local SCHEME_METAL = 110       -- brightness from which a gray group is kept
local function brightness(c) return c[1] * 0.30 + c[2] * 0.59 + c[3] * 0.11 end
local function saturation(c)
    local top = math.max(c[1], c[2], c[3])
    return top > 0 and (top - math.min(c[1], c[2], c[3])) / top or 0
end

function core.color_scheme(built, main, second)
    local parts = { colored = {}, gray = {} }
    for _, name in ipairs(core.COLOR_NAMES) do
        local c = built[name]
        if c then
            if saturation(c) >= SCHEME_COLORED then
                table.insert(parts.colored, name)
            elseif brightness(c) < SCHEME_METAL then
                table.insert(parts.gray, name)
            end
        end
    end
    if #parts.colored == 0 then parts.colored, parts.gray = parts.gray, {} end    -- an all-gray piece takes main
    local out = {}
    for name, c in pairs(built) do out[name] = { c[1], c[2], c[3] } end
    for kind, target in pairs({ colored = main, gray = second }) do
        local total = 0
        for _, name in ipairs(parts[kind]) do total = total + brightness(built[name]) end
        local average = math.max(total / math.max(#parts[kind], 1), 1)
        for _, name in ipairs(parts[kind]) do    -- the lightest group gets the color, darker ones less, up to half
            local scale = math.min(1, 0.55 + 0.45 * brightness(built[name]) / average / 1.6)
            out[name] = { math.min(255, math.floor(target[1] * scale + 0.5)), math.min(255, math.floor(target[2] * scale + 0.5)),
                          math.min(255, math.floor(target[3] * scale + 0.5)) }
        end
    end
    return out
end

-- the named colors saved for one of a mod's files, oldest first: { name, palette }
function core.color_saves(mod, rel)
    local by_mod = config.data.color_saves[mod.folder]
    return by_mod and by_mod[rel] or {}
end

-- the name a new save starts with: the piece's name, then Custom and the next free number
function core.next_color_name(mod, rel, piece_name)
    local taken = {}
    for _, save in ipairs(core.color_saves(mod, rel)) do taken[save.name] = true end
    local n = 1
    while taken[('%s Custom %d'):format(piece_name, n)] do n = n + 1 end
    return ('%s Custom %d'):format(piece_name, n)
end

-- saves colors under a name, replacing a save of that name, and wears them
function core.save_colors(mod, rel, name, palette)
    config.data.color_saves[mod.folder] = config.data.color_saves[mod.folder] or {}
    local list = config.data.color_saves[mod.folder][rel] or {}
    config.data.color_saves[mod.folder][rel] = list
    local found = false
    for _, save in ipairs(list) do
        if save.name == name then
            save.palette, found = palette, true
        end
    end
    if not found then list[#list + 1] = { name = name, palette = palette } end
    if core.paint(mod, rel, palette, true) then say(('Saved %s.'):format(name)) end
end

function core.delete_color_save(mod, rel, name)
    local list = core.color_saves(mod, rel)
    for i = #list, 1, -1 do
        if list[i].name == name then table.remove(list, i) end
    end
    config:save()
    say(('Deleted %s.'):format(name))
end

-- Framing: while the window is open, VanaCore's free camera faces you from the front and turns so you stand on the
-- right of the screen, clear of the window. Positions are the game's: x and y along the ground, z height with up
-- negative; the free camera takes x, height, y.
local FRAME_HEIGHT = 1.3       -- how far above your feet the camera sits
local FRAME_TURN = 0.3         -- radians the camera turns, moving you right of the middle, unless frame_shift says
local FRAME_TILT = 0.02        -- a little downward look
local FREECAM_CLOSE_AFTER = 3  -- frames: the freecam addon opens its window when the free camera comes on
local framing = false
local frame_angle, spin_speed, spun_at = 0, 0, nil
local close_freecam_in

function core.frame(on)
    if not on then
        if framing then
            vana.camera.hold(false)
            vana.camera.free(false)
            framing = false
            close_freecam_in = nil
        end
        return
    end
    local me = find_self()
    if not me then return end
    if not framing then
        local was_on = vana.camera.state().on
        if not vana.camera.free(true) then return end
        framing = true
        -- only the window this turn-on opened: one you had open for your own free camera stays
        if not was_on then close_freecam_in = FREECAM_CLOSE_AFTER end
    end
    if close_freecam_in then
        close_freecam_in = close_freecam_in - 1
        if close_freecam_in <= 0 then
            close_freecam_in = nil
            pcall(function () AshitaCore:GetChatManager():QueueCommand(-1, '/freecam close') end)
        end
    end
    if not vana.camera.state().have then return end
    vana.camera.hold(true)
    local distance = tonumber(config.data.frame_distance) or 4.5
    if spin_speed ~= 0 then
        local now = vana.time.clock()
        frame_angle = (frame_angle + spin_speed * (now - (spun_at or now))) % 360
        spun_at = now
    end
    local around = math.rad(frame_angle)    -- how far round you the camera has gone from your front
    local ahead_x, ahead_y = math.cos(me.heading - around), -math.sin(me.heading - around)
    local x, y = me.x + ahead_x * distance, me.y + ahead_y * distance
    local yaw = math.atan2(me.y - y, me.x - x) + (tonumber(config.data.frame_shift) or FRAME_TURN)
    vana.camera.set_pose(x, me.z - FRAME_HEIGHT, y, yaw, FRAME_TILT)
end

function core.framing()
    return framing
end

-- turning the framed camera round you: an angle in degrees from your front, and a spin in degrees a second
function core.frame_angle(degrees)
    if degrees then frame_angle = degrees % 360 end
    return frame_angle
end

function core.frame_spin(speed)
    if speed then
        spin_speed, spun_at = speed, nil
    end
    return spin_speed
end

-- the game keeps a model it has drawn, so a changed file shows only after the model is swapped out and back:
-- this draws your armor and weapons bare for a moment, then puts them back
function core.redraw()
    local address = find_self() and self_address()
    if not address then return false end
    redraw_looks = {}
    for i, slot in ipairs(core.SLOTS) do
        if MODEL_ROWS[slot.key] then
            local at = address + ENTITY_LOOK + i * 2
            redraw_looks[at] = vana.memory.read_uint16(at)
            vana.memory.write_uint16(at, slot.prefix)
        end
    end
    vana.memory.write_uint16(address + ENTITY_FLAGS, RELOAD)
    redraw_at = vana.time.clock() + REDRAW_TIME
    return true
end

local function build_list(key)
    local list = {}
    local entity = find_self()
    if not entity then return nil end    -- not loaded yet, as while zoning: try again later rather than keep nothing
    local race_mask = 2 ^ entity.race
    for id, row in pairs(vana.gamedata.all('items')) do
        local fits, own_slot = false, false
        for _, name in ipairs(row.slot_names or {}) do
            if name == key then own_slot = true end
            if name == key or (key == 'sub' and name == 'main') then fits = true end
        end
        if fits and (row.model_id or 0) > 0 and bit.band(row.races or 0, race_mask) ~= 0 then
            list[#list + 1] = { id = id, name = row.name, lower = row.name:lower(), main_only = not own_slot,
                                  model = row.model_id }
        end
    end
    table.sort(list, function (a, b) return a.lower < b.lower end)
    return list
end

-- which of the pieces with one look names it: one that fits the slot, then the plainest name
local function better_name(a, b)
    if a.main_only ~= b.main_only then return b.main_only end
    local a_plus, b_plus = a.lower:find('%+%d+$') ~= nil, b.lower:find('%+%d+$') ~= nil
    if a_plus ~= b_plus then return b_plus end
    if #a.lower ~= #b.lower then return #a.lower < #b.lower end
    return a.lower < b.lower
end

-- one row per look: a slot's pieces with the same model look the same (+1, +2, +3 and so on)
local function build_looks(key)
    item_lists[key] = item_lists[key] or build_list(key)
    if not item_lists[key] then return nil end
    local by_model, looks = {}, {}
    for _, piece in ipairs(item_lists[key]) do
        local group = by_model[piece.model]
        if not group then
            group = {}
            by_model[piece.model] = group
            looks[#looks + 1] = group
        end
        group[#group + 1] = piece
    end
    for i, group in ipairs(looks) do
        table.sort(group, better_name)
        looks[i] = { id = group[1].id, name = group[1].name, lower = group[1].lower,
                     main_only = group[1].main_only, pieces = group }
    end
    table.sort(looks, function (a, b) return a.lower < b.lower end)
    return looks
end

-- the looks for a slot with a name holding text. A look found by a name it hides shows that name.
-- The second value is how many there are in all.
function core.items_for(key, text)
    look_lists[key] = look_lists[key] or build_looks(key)
    local found, total = {}, 0
    text = text:lower()
    local entity = find_self()
    for _, look in pairs(core.looks) do
        if look.key == key and entity and look.race == entity.race and look.lower:find(text, 1, true) then
            total = total + 1
            found[total] = look
        end
    end
    for _, look in ipairs(look_lists[key] or {}) do
        local shown =(text == '' or look.lower:find(text, 1, true)) and look or nil
        if not shown then
            for _, piece in ipairs(look.pieces) do
                if piece.lower:find(text, 1, true) then
                    shown = piece
                    break
                end
            end
        end
        if shown then
            total = total + 1
            if total <= core.LIST_LIMIT then found[total] = shown end
        end
    end
    return found, total
end

-- the file of an armor model on your race, by the table the game reads: a pointer per race, then a row per slot
-- of six (first file, count) ranges in model order
local function armor_file(key, model)
    local entity = find_self()
    local row = MODEL_ROWS[key]
    if not entity or not row then return nil end
    local base = vana.memory.module('FFXiMain.dll') + ARMOR_TABLE
    local at = vana.memory.read_uint32(base + entity.race * 4) + row * ARMOR_ROW_SIZE
    for i = 0, ARMOR_RANGES - 1 do
        local first = vana.memory.read_uint32(at + i * 8)
        local count = vana.memory.read_uint32(at + i * 8 + 4)
        if model < count then return first + model end
        model = model - count
    end
end

-- Private copies: a recolored normal piece is a copy only your character wears, so nobody else wearing that piece
-- changes on your screen. About 3,400 model numbers per slot point at file numbers with no file in the game's or the
-- server's tables, so no item can use them. A copy takes one: its file goes in the colors mod at ROM\511\<n>.DAT and
-- down (game and server folders stop at 384), the lookup tables learn that file number, and your look shows that
-- model wherever it would show the piece. The tables are the server's own plus ours, written into the colors mod for
-- the next start and patched into the game's copy in memory now, so a new copy shows at once. Each start checks the
-- server hasn't taken a number since, and moves the copy if it has. config.data.private, by the piece's own file:
-- { key, model, race, pmodel, fid, rel, value }. Nothing goes to the server.
local PRIVATE_DIR = 511           -- the first private folder; the next 128 copies go in 510, and so on
local PRIVATE_FIRST_MODEL = 400   -- model numbers below this are left to the game
local MODEL_COUNT = 4096
local VT_ROM = 1                  -- a file table byte for the ROM folder
local TABLES_PROBE = 64           -- bytes compared at each place a table could start

local base_tables    -- { vt, ft } as the game and the server have them, without ours; read once
local function tables()
    if not base_tables then
        local vt, ft = served('VTABLE.DAT'), served('FTABLE.DAT')
        base_tables = { vt = vt and read_file(vt) or '', ft = ft and read_file(ft) or '' }
    end
    return base_tables
end

local function has_file(id)
    local byte = tables().vt:byte(id + 1)
    return byte ~= nil and byte ~= 0
end

local function privates()
    config.data.private = config.data.private or {}
    return config.data.private
end

local function race_now()
    local entity = find_self()
    return entity and entity.race
end

drawable = function (key, model)
    if model == 0 then return true end
    local file = armor_file(key, model)
    if not file or #tables().vt == 0 then return true end    -- can't tell yet
    return has_file(file)
end

-- A file new to a mod's folder reaches the game only from the next zone (VanaCore's overlays take in what's there
-- then), so a copy written to a new file would draw nothing till then: a body with wings put on in a gear change goes
-- invisible. A few empty spare files wait at the next free private paths, made at each zone for the ones after it, and
-- a copy written over one shows at once. A copy whose file is newer than the last zone shows the piece itself, without
-- its colors or effect, until the next zone.
local SPARES = 10    -- enough for a few gear changes between zones, each slot with an effect getting a new copy
local fresh = {}    -- private paths whose file was made since the last zone

private_model = function (key, model)
    local race = race_now()
    for _, entry in pairs(privates()) do
        if entry.key == key and entry.model == model and entry.race == race then
            return fresh[entry.rel] and model or entry.pmodel
        end
    end
    return model
end

-- the next free private paths, in the order claim takes them
local function free_paths(count)
    local used, list = {}, {}
    for _, entry in pairs(privates()) do used[entry.rel] = true end
    for n = 0, 128 * 64 - 1 do
        local dir = PRIVATE_DIR - math.floor(n / 128)
        local rel = ('ROM\\%d\\%d.DAT'):format(dir, n % 128)
        if not used[rel] then
            list[#list + 1] = { rel = rel, dir = dir }
            if #list >= count then break end
        end
    end
    return list
end

local function make_spares()
    local folder = core.root() .. '\\TransMog\\' .. COLORS_MOD
    if not vana.fs.exists(folder .. '\\' .. MANIFEST) then return end    -- nothing recolored yet: no folder to wait in
    for _, spare in ipairs(free_paths(SPARES)) do
        local path = folder .. '\\' .. spare.rel
        if not vana.fs.exists(path) then
            vana.fs.create_dir(folder .. '\\ROM\\' .. spare.dir)
            if vana.fs.write(path, '') then fresh[spare.rel] = true end
        end
    end
end

-- at a zone, every file there is the game's to read: copies made since show as themselves now
local function zoned()
    fresh = {}
    make_spares()
end

-- the piece's own file for a private copy's file, else the file itself
local function original_rel(rel)
    for own, entry in pairs(privates()) do
        if entry.rel == rel then return own end
    end
    return rel
end

-- a free model number for a slot on your race, and a free private path: nil and why when there is none
local function claim(key)
    local race = race_now()
    if not race then return nil, 'Your character is not loaded yet.' end
    local used_models, used_files, used_paths = {}, {}, {}
    for _, entry in pairs(privates()) do
        if entry.key == key and entry.race == race then used_models[entry.pmodel] = true end
        used_files[entry.fid], used_paths[entry.rel] = true, true
    end
    local size = #tables().vt
    for model = PRIVATE_FIRST_MODEL, MODEL_COUNT - 1 do
        local fid = not used_models[model] and armor_file(key, model)
        if fid and fid < size and not used_files[fid] and not has_file(fid) then
            for n = 0, 128 * 64 - 1 do
                local dir = PRIVATE_DIR - math.floor(n / 128)
                local rel = ('ROM\\%d\\%d.DAT'):format(dir, n % 128)
                if not used_paths[rel] then
                    return { key = key, race = race, pmodel = model, fid = fid, rel = rel, value = dir * 128 + n % 128 }
                end
            end
        end
    end
    return nil, 'There is no free model number left for this slot.'
end

-- the game's own tables in memory, found once: each sits at the start of a 64 KB block, the FTABLE after the VTABLE
local live
local function hex(text)
    return (text:gsub('.', function (c) return ('%02X '):format(c:byte()) end))
end

local function probe_at(data, from)    -- a varied stretch from `from` on
    for at = from, #data - TABLES_PROBE, TABLES_PROBE do
        local piece, kinds, count = data:sub(at + 1, at + TABLES_PROBE), {}, 0
        for i = 1, #piece do
            if not kinds[piece:byte(i)] then kinds[piece:byte(i)], count = true, count + 1 end
        end
        if count >= 2 then return at, hex(piece) end    -- a VTABLE holds little but 0 and 1
    end
end

local function find_live()
    if live ~= nil then return live or nil end
    live = false
    local base = tables()
    if #base.vt == 0 then return nil end
    local v_at, v_probe = probe_at(base.vt, 40960)
    local v_at2, v_probe2 = probe_at(base.vt, math.floor(#base.vt / 2))
    local f_at, f_probe = probe_at(base.ft, 81920)
    if not v_at or not v_at2 or not f_at then return nil end
    -- where they were last time: the game keeps them there until it restarts, so a reload needn't search again
    local last = config.data.tables_at
    if last and vana.memory.find(last.vt + v_at, TABLES_PROBE, v_probe) ~= 0
        and vana.memory.find(last.vt + v_at2, TABLES_PROBE, v_probe2) ~= 0
        and vana.memory.find(last.ft + f_at, TABLES_PROBE, f_probe) ~= 0 then
        live = { vt = last.vt, ft = last.ft }
        return live
    end
    for block = 0x10000, 0x7FFF0000, 0x10000 do
        if vana.memory.find(block + v_at, TABLES_PROBE, v_probe) ~= 0
            and vana.memory.find(block + v_at2, TABLES_PROBE, v_probe2) ~= 0 then
            for step = 1, 64 do
                local f_block = block + step * 0x10000
                if vana.memory.find(f_block + f_at, TABLES_PROBE, f_probe) ~= 0 then
                    live = { vt = block, ft = f_block }
                    config.data.tables_at = { vt = block, ft = f_block }
                    config:save()
                    return live
                end
            end
        end
    end
    return nil
end

-- the game reads its tables once, at its start, before TransMog's folders are in the DAT order, so it always starts
-- from the server's own; each session our copies' file numbers are written into its copy in memory
local function update_tables()
    local folder = core.root() .. '\\TransMog\\' .. COLORS_MOD
    for _, name in ipairs({ 'VTABLE.DAT', 'FTABLE.DAT' }) do    -- tables an earlier TransMog wrote: not wanted
        if vana.fs.exists(folder .. '\\' .. name) then vana.fs.remove(folder .. '\\' .. name) end
    end
    local race, mine = race_now(), {}
    for _, entry in pairs(privates()) do
        if entry.race == race and entry.fid < #tables().vt then mine[#mine + 1] = entry end
    end
    if #mine == 0 then return true end
    local at = find_live()
    if not at then return false end
    for _, entry in ipairs(mine) do
        vana.memory.write_uint8(at.vt + entry.fid, VT_ROM)
        vana.memory.write_uint16(at.ft + entry.fid * 2, entry.value)
    end
    return true
end

-- a moved copy's old file number gets the server's entry back
local function forget_number(fid)
    local at = live or nil
    if not at or not fid then return end
    local base = tables()
    vana.memory.write_uint8(at.vt + fid, base.vt:byte(fid + 1) or 0)
    vana.memory.write_uint16(at.ft + fid * 2, (base.ft:byte(fid * 2 + 1) or 0) + (base.ft:byte(fid * 2 + 2) or 0) * 256)
end

-- a copy for the piece in its own file, made from the source file: the copy, or nil and why
local function make_private(key, own_rel, model, source, name)
    local entry, why = claim(key)
    if not entry then return nil, why end
    entry.model = model
    local folder = core.root() .. '\\TransMog\\' .. COLORS_MOD
    local new_file = not vana.fs.exists(folder .. '\\' .. entry.rel)    -- not a spare: the game can't read it yet
    local palette, err = colors.prepare(folder, entry.rel, source, name)
    if not palette then return nil, err end
    if new_file then fresh[entry.rel] = true end
    privates()[own_rel] = entry
    config:save()
    update_tables()
    make_spares()    -- the next copy finds one waiting
    return entry
end

-- the slot and model of a file on your race, by the model table: nil when no slot's models reach it
local function model_of(file)
    local entity = find_self()
    if not entity then return nil end
    local base = vana.memory.module('FFXiMain.dll') + ARMOR_TABLE
    for key, row in pairs(MODEL_ROWS) do
        local at, model = vana.memory.read_uint32(base + entity.race * 4) + row * ARMOR_ROW_SIZE, 0
        for i = 0, ARMOR_RANGES - 1 do
            local first, count = vana.memory.read_uint32(at + i * 8), vana.memory.read_uint32(at + i * 8 + 4)
            if file >= first and file < first + count then return key, model + file - first end
            model = model + count
        end
    end
end

-- the file number of a path, by the game's and the server's tables
local function file_of(rel)
    local rom, dir, n = rel:match('^ROM(%d*)\\(%d+)\\(%d+)%.DAT$')
    if not rom then return nil end
    local vt_byte, value = tonumber(rom ~= '' and rom or '1'), tonumber(dir) * 128 + tonumber(n)
    local base = tables()
    local lo, hi = value % 256, math.floor(value / 256)
    for id = 0, #base.vt - 1 do
        if base.vt:byte(id + 1) == vt_byte and base.ft:byte(id * 2 + 1) == lo and base.ft:byte(id * 2 + 2) == hi then
            return id
        end
    end
end

-- moves a copy's file and colors to a new private path: when its number has been taken, or a shared copy from
-- before private copies (entry nil: own_rel is then where the shared copy sits)
local function move_private(own_rel, entry)
    local folder = core.root() .. '\\TransMog\\' .. COLORS_MOD
    local from = entry and entry.rel or own_rel
    local key, model = entry and entry.key, entry and entry.model
    if not entry then
        local file = file_of(own_rel)
        if file then key, model = model_of(file) end
    end
    if not key then return false end
    local new = claim(key)
    if not new then return false end
    new.model = model
    local new_file = not vana.fs.exists(folder .. '\\' .. new.rel)
    if not colors.rename(folder, from, new.rel) then return false end
    if new_file then fresh[new.rel] = true end
    for _, store in ipairs({ config.data.colors, config.data.color_saves }) do
        local saved = store[COLORS_MOD]
        if saved and saved[from] ~= nil then saved[new.rel], saved[from] = saved[from], nil end
    end
    if entry then forget_number(entry.fid) end
    privates()[own_rel] = new
    config:save()
    return true
end

-- once you're in game: shared copies from before become private, copies whose number the game or the server took
-- move, and the tables are written and taught to the game
local private_checked = false
function core.check_private()
    if private_checked or not race_now() then return end
    private_checked = true
    local info = colors.info(core.root() .. '\\TransMog\\' .. COLORS_MOD)
    local moved = 0
    local mine = {}
    for _, entry in pairs(privates()) do mine[entry.rel] = true end
    for rel in pairs(info and info.files or {}) do
        if not mine[rel] and rel:match('^ROM%d*\\%d+\\%d+%.DAT$') then
            if move_private(rel, nil) then moved = moved + 1 end
        end
    end
    for own_rel, entry in pairs(privates()) do
        if entry.race == race_now() and (has_file(entry.fid) or armor_file(entry.key, entry.pmodel) ~= entry.fid) then
            if move_private(own_rel, entry) then moved = moved + 1 end
        end
    end
    update_tables()
    if moved > 0 then
        say(('Made %d recolored piece%s yours alone.'):format(moved, moved == 1 and '' or 's'))
        core.redraw()
    end
end

-- the titles of the mods that change how an item looks on your race, or nil
function core.changed_by(key, id)
    local item = vana.gamedata.items[id or 0]
    if not item then return nil end
    core.changers[key] = core.changers[key] or {}
    local known = core.changers[key][item.model_id]
    if known == nil then
        local file = armor_file(key, item.model_id)
        local rel = file and file_path(file)
        known = rel and (privates()[rel] and { COLORS_TITLE } or core.owners[rel:lower()]) or false
        core.changers[key][item.model_id] = known
    end
    return known or nil
end

-- what the Colors page can recolor in an armor slot: the piece you show there, if a recolorable mod draws it.
-- Returns { mod, rel, name } or nil and why not.
function core.color_target(key)
    if not MODEL_ROWS[key] then return nil, 'This slot has no model to recolor.' end
    local id = config.data.picks[key]
    local item = id and piece(id)
    local model, name
    if item then
        model, name = item.model_id, item.name
    else
        local look = config.data.real[key]
        if not look then return nil, 'Nothing is shown in this slot yet.' end
        model, name = look % 0x1000, 'Worn gear'
    end
    local file = armor_file(key, model)
    local own = file and file_path(file)
    if not own then return nil, ('%s has no model file.'):format(name) end
    local private = privates()[own]
    local rel = private and private.rel or own    -- your private copy of the piece, when you have one
    for _, mod in ipairs(core.recolorable()) do
        local info = colors.info(mod.path)
        for path in pairs(info and info.files or {}) do
            if path:lower() == rel:lower() then return { mod = mod, rel = path, name = name } end
        end
    end
    return nil, ('%s is a normal item.'):format(name), { rel = own, name = name, model = model, key = key }
end

-- splits a recolored normal piece into its colors again, from the game's own file. Its saved colors are dropped, as
-- they follow the old split.
function core.redetect_colors(key)
    local target = core.color_target(key)
    if not target or target.mod.folder ~= COLORS_MOD then return false end
    local source = served(original_rel(target.rel))
    local palette, err = source and colors.prepare(target.mod.path, target.rel, source, target.name)
    if not palette then
        say(err or ('Could not find the file for %s.'):format(target.name))
        return false
    end
    if config.data.colors[COLORS_MOD] then config.data.colors[COLORS_MOD][target.rel] = nil end
    if config.data.color_saves[COLORS_MOD] then config.data.color_saves[COLORS_MOD][target.rel] = nil end
    config:save()
    core.forget_effect(key)    -- the copy is fresh from the game's file, so its effect goes on again
    core.redraw()
    say(('Reset %s to its original colors.'):format(target.name))
    return true
end

-- whether a slot shows a normal piece made recolorable, which can have its colors found again
function core.is_recolored_copy(target)
    return target ~= nil and target.mod.folder == COLORS_MOD
end

-- makes the normal piece shown in an armor slot recolorable, by copying its file into the colors mod. The first
-- time turns that mod on, which shows after a zone.
function core.make_recolorable(key)
    local target, why, normal = core.color_target(key)
    if target then return true end
    if not normal then
        say(why)
        return false
    end
    local source = served(normal.rel)
    if not source then
        say(('Could not find the file for %s.'):format(normal.name))
        return false
    end
    local folder = core.root() .. '\\TransMog\\' .. COLORS_MOD
    vana.fs.create_dir(folder)
    if not vana.fs.exists(folder .. '\\' .. MANIFEST) then
        vana.fs.write(folder .. '\\' .. MANIFEST, vana.json.encode({ title = COLORS_TITLE, category = 'other' }))
    end
    local entry, err = make_private(key, normal.rel, normal.model, source, normal.name)
    if not entry then
        say(err)
        return false
    end
    if not config.data.enabled[COLORS_MOD] then
        config.data.enabled[COLORS_MOD] = true
        config:save()
        core.scan()
        core.apply()
        update_pending()
        say(('%s can be recolored now. Zone once so the game reads recolored gear.'):format(normal.name))
    else
        core.scan()
        say(('%s can be recolored now, as a copy only you wear.'):format(normal.name))
    end
    sync_now()    -- your look moves onto your copy
    return true
end

-- Effects: wings from a body, or a weapon's glow, put on the piece shown in a slot by moving the effect's folder into
-- that piece's file. Like recoloring, a normal piece is copied into the colors mod first.
core.EFFECT_SLOTS = { body = 'wings', main = 'glow', sub = 'glow', range = 'glow' }
local effect_list
local effect_shown = {}    -- slot -> the file the slot's effect was last put in

-- { wings = { { name, item } }, glows = { { name, model } } }, from effects.json beside this file
function core.effect_choices()
    if not effect_list then
        local text = read_file(addon.path .. 'effects.json')
        effect_list = text and vana.json.decode(text) or { wings = {}, glows = {} }
    end
    return effect_list
end

-- what a slot shows as its effect: nil for the piece's own, 'off', or the name of a choice
function core.effect_choice(key)
    return config.data.effects[key]
end

local function effect_source(key, choice)
    local list = core.effect_choices()
    for _, entry in ipairs(key == 'body' and list.wings or list.glows) do
        if entry.name == choice then
            local model = entry.model or (vana.gamedata.items[entry.item] or {}).model_id
            local file = model and armor_file(key == 'body' and 'body' or 'main', model)
            local rel = file and file_path(file)
            return rel and served(rel)
        end
    end
end

-- gives a piece's file in a mod of ours its own effects again: a copy the game's, gear built here none
local function effects_changed()
    config.data.effects_changed = config.data.effects_changed or {}
    return config.data.effects_changed
end

local function restore_effects(rel)
    if not rel then return end
    if effects_changed()[rel] then
        effects_changed()[rel] = nil
        config:save()
    end
    for _, mod in ipairs(core.recolorable()) do
        local info = colors.info(mod.path)
        if info and info.files[rel] then
            local source = mod.folder == COLORS_MOD and served(original_rel(rel))
            colors.set_effects(mod.path .. '\\' .. rel, source and colors.effects_of(colors.read(source) or '') or '')
            return
        end
    end
end

-- A copy whose model an older TransMog moved out with an effect (a relic weapon's, kept in a folder of its own) is
-- copied again from the game's file; its colors and effects are put back on it after.
local function repair_copy(mod, rel)
    local path = mod.path .. '\\' .. rel
    local source = served(original_rel(rel))
    local original = source and read_file(source)
    if not original or colors.mesh_count(read_file(path)) >= colors.mesh_count(original) then return end
    local f = io.open(path, 'wb')
    if not f then return end
    f:write(original)
    f:close()
    effects_changed()[rel] = true    -- so it gets its own effects back too
end

-- puts the chosen effect on the piece shown in a slot. With redraw, you are redrawn to show it.
function core.apply_effect(key, redraw)
    local choice = config.data.effects[key]
    local target = core.color_target(key)
    if not target and choice == nil then return true end
    if not target then
        if not core.make_recolorable(key) then return false end
        target = core.color_target(key)
        if not target then return false end
    end
    local effects = ''
    if choice == nil then    -- the piece's own, from the game's file; gear built here has none
        local source = core.is_recolored_copy(target) and served(original_rel(target.rel))
        effects = source and colors.effects_of(colors.read(source) or '') or ''
    elseif choice ~= 'off' then
        local source = effect_source(key, choice)
        if not source then
            say(('Could not find the file for %s.'):format(choice))
            return false
        end
        effects = colors.effects_of(colors.read(source) or '')
    end
    local ok, err = colors.set_effects(target.mod.path .. '\\' .. target.rel, effects)
    if not ok then
        say(err)
        return false
    end
    effects_changed()[target.rel] = choice ~= nil or nil    -- a file with another effect gets its own back next load
    config:save()
    effect_shown[key] = target.rel
    if redraw then core.redraw() end
    return true
end

function core.set_effect(key, choice)
    config.data.effects[key] = choice
    config:save()
    if core.apply_effect(key, true) then
        say(choice == nil and 'Back to the piece\'s own effect.' or choice == 'off' and 'Effect off.' or
            ('%s effect on.'):format(choice))
    end
end

-- why a piece in the colors mod differs from the game's, or nil when it is only a copy: 'Recolored' for saved colors,
-- and, when shown is set (the piece is the one your look shows), the effect put on it
function core.copy_reason(key, id, shown)
    local item = vana.gamedata.items[id or 0]
    local file = item and armor_file(key, item.model_id)
    local rel = file and file_path(file)
    if not rel then return nil end
    rel = privates()[rel] and privates()[rel].rel or rel
    local reasons = {}
    local saved = config.data.colors[COLORS_MOD]
    if saved and saved[rel] then reasons[#reasons + 1] = 'Recolored' end
    local choice = config.data.effects[key]
    if shown and choice ~= nil and effect_shown[key] == rel then
        reasons[#reasons + 1] = choice == 'off' and 'No effect' or key == 'body' and 'Wings' or 'Glow'
    end
    return #reasons > 0 and table.concat(reasons, ', ') or nil
end

function core.is_copy_only(titles)
    return titles ~= nil and #titles == 1 and titles[1] == COLORS_TITLE
end

function core.forget_effect(key)
    effect_shown[key] = nil
end

-- a slot showing a different piece than its effect was put on gets it again
function core.check_effects()
    for key in pairs(config.data.effects) do
        local target = core.color_target(key)
        local rel = target and target.rel
        if not target then
            local _, _, normal = core.color_target(key)
            rel = normal and normal.rel
        end
        if rel and effect_shown[key] ~= rel then
            restore_effects(effect_shown[key])    -- the effect is the slot's: the piece it leaves gets its own back
            effect_shown[key] = rel    -- tried once per piece, so a piece that can't take it isn't tried every second
            core.apply_effect(key, true)
        end
    end
end

-- which item's icon a pick shows
function core.icon_of(id)
    local look = core.looks[id or 0]
    return look and look.icon or id
end

-- the item of a slot's list a pick counts as: its look's row, so a +3 in a saved set shows on the plain row
function core.same_look(key, a, b)
    local one, two = piece(a), piece(b)
    return one ~= nil and two ~= nil and one.model_id == two.model_id
end

local ARMOR = { head = true, body = true, hands = true, legs = true, feet = true }
local match_cache = {}    -- item id -> { picks, count, name }
local anchor              -- { key, id }: the armor piece clicked last

local function stem(lower)
    return lower:match('^[%a]+') or lower
end

local function plus(lower)
    return lower:match('%+%d+$') or ''
end

-- how well a piece matches: the same model and name is the set itself. Many armors share a first word
-- (Ebur has over a dozen sets) and some unrelated pieces share a model number, so each alone counts for less.
local function match_score(piece, item)
    local same_stem = stem(piece.lower) == stem(item.lower)
    local same_model = piece.model == item.model
    if same_stem and same_model then return 3 end
    if same_stem then return 2 end
    if same_model then return 1 end
    return 0
end

local function best_piece(key, item)
    item_lists[key] = item_lists[key] or build_list(key)
    local best, best_score
    for _, piece in ipairs(item_lists[key] or {}) do
        local score = match_score(piece, item)
        if score > 0 then
            score = score * 1000 + (plus(piece.lower) == plus(item.lower) and 100 or 0) - #piece.lower
            if not best or score > best_score then
                best, best_score = piece, score
            end
        end
    end
    return best
end

-- the armor piece matches are made from: the slot you checked, or with none checked the last piece
-- clicked while it's still worn, else the body, else any
local function match_source()
    local picks = config.data.picks
    local checked = config.data.match_slot
    if checked ~= '' then return checked, picks[checked] end
    if anchor and picks[anchor.key] == anchor.id then return anchor.key, anchor.id end
    if picks.body then return 'body', picks.body end
    for _, slot in ipairs(core.SLOTS) do
        if ARMOR[slot.key] and picks[slot.key] then return slot.key, picks[slot.key] end
    end
end

-- the set of that piece: { picks = { slot key = item id }, count, name }, or nil
function core.set_match()
    local key, id = match_source()
    local row = id and vana.gamedata.items[id]
    if not row then return nil end
    if match_cache[id] ~= nil then return match_cache[id] or nil end
    local item = { lower = row.name:lower(), model = row.model_id }
    local match = { picks = {}, count = 0, name = row.name }
    for _, slot in ipairs(core.SLOTS) do
        if ARMOR[slot.key] and slot.key ~= key then
            local piece = best_piece(slot.key, item)
            if piece then
                match.picks[slot.key] = piece.id
                match.count = match.count + 1
            end
        end
    end
    match_cache[id] = match.count > 0 and match or false
    return match_cache[id] or nil
end

function core.wear_match(match)
    for key, id in pairs(match.picks) do config.data.picks[key] = id end
    config:save()
    if config.data.lock then
        sync_now()
    else
        core.set_lock(true)
    end
    say(('Matched %d pieces to %s.'):format(match.count, match.name))
end

function core.wear_slot_match(key, match)
    config.data.picks[key] = match.picks[key]
    config:save()
    if config.data.lock then
        sync_now()
    else
        core.set_lock(true)
    end
end

function core.item_name(id)
    local item = piece(id)
    return item and item.name or ''
end

function core.match_slot()
    return config.data.match_slot
end

-- only one slot is checked: checking another moves it, and checking the same one again clears it
function core.toggle_match_slot(key)
    config.data.match_slot = config.data.match_slot == key and '' or key
    config:save()
end

function core.is_armor(key)
    return ARMOR[key] == true
end

function core.picked_name(key)
    local id = config.data.picks[key]
    local item = id and piece(id)
    return item and item.name or nil
end

function core.picked_item(key)
    local id = config.data.picks[key]
    local item = id and piece(id)
    return item and { id = id, name = item.name } or nil
end

function core.picks_count(picks)
    local count = 0
    for _ in pairs(picks or config.data.picks) do count = count + 1 end
    return count
end

-- VanaCore's own settings for the blink on a gear change: key is blink.disable, or blink.weapons for weapons too
function core.blink_setting(key)
    return vana.config.get('client', key) == '1'
end

function core.set_blink_setting(key, on)
    vana.config.set('client', key, on and '1' or '0')
    vana.config.reload()
end

-- Race: the race and sex your character is drawn as, on your screen only. Others see your real one, and nothing goes
-- to the server. Gear shows as each piece looks on that race.
core.RACES = {
    { id = 1, race = 'Hume', sex = 'Male' }, { id = 2, race = 'Hume', sex = 'Female' },
    { id = 3, race = 'Elvaan', sex = 'Male' }, { id = 4, race = 'Elvaan', sex = 'Female' },
    { id = 5, race = 'Tarutaru', sex = 'Male' }, { id = 6, race = 'Tarutaru', sex = 'Female' },
    { id = 7, race = 'Mithra', sex = 'Female' }, { id = 8, race = 'Galka', sex = 'Male' },
}

-- the race you're drawn as now, and your own
function core.race()
    return config.data.race or config.data.own_race, config.data.own_race
end

-- face and hair now (0 to 15), and your own; nil before the game has drawn you
function core.face()
    return config.data.face or own_face, own_face
end

-- the scale you're drawn at, as a share of your own size (1 is your own)
function core.size()
    return config.data.size or 1
end

-- face and hair from 0 to 15, or nil for your own
function core.set_face(face)
    if face == own_face then face = nil end
    config.data.face = face
    local address = find_self() and self_address()
    if address and not face and own_face then
        vana.memory.write_uint16(address + ENTITY_LOOK, own_face)
        vana.memory.write_uint16(address + ENTITY_FLAGS, RELOAD)
    end
    sync_now()
end

-- a scale from 0.5 to 2, or nil for your own size
function core.set_size(scale)
    if scale and math.abs(scale - 1) < 0.005 then scale = nil end
    config.data.size = scale
    sync_now()
end

-- draws you as a race, or as your own with nil
function core.set_race(id)
    if id == config.data.own_race then id = nil end
    config.data.race = id
    config:save()
    local address = find_self() and self_address()
    if address and not id and config.data.own_race then    -- back to your own straight away
        vana.memory.write_uint8(address + ENTITY_RACE, config.data.own_race)
        vana.memory.write_uint16(address + ENTITY_FLAGS, RELOAD)
    end
    sync_now()
end

function core.set_lock(on)
    if on and not config.data.lock then
        local entity = find_self()
        if entity and not next(config.data.real) then
            for i, slot in ipairs(core.SLOTS) do
                config.data.real[slot.key] = entity.models[i + 1]
            end
        end
        config.data.locked = nil    -- taken below, from the gear you wear now
    end
    if not on then config.data.locked = nil end
    config.data.lock = on
    lock_now()
    config:save()
    sync_now()
end

function core.pick(key, item)
    config.data.picks[key] = item and item.id or nil
    if item and ARMOR[key] then anchor = { key = key, id = item.id } end
    config:save()
    if item and not config.data.lock then
        core.set_lock(true)
    else
        sync_now()
    end
end

function core.clear_picks()
    config.data.picks = {}
    config:save()
    sync_now()
end

function core.save_set(name)
    local set = {}
    for key, id in pairs(config.data.picks) do set[key] = id end
    config.data.sets[name] = set
    config:save()
    say(('Saved %s.'):format(name))
end

function core.wear_set(name)
    local set = config.data.sets[name]
    if not set then return end
    config.data.picks = {}
    for key, id in pairs(set) do config.data.picks[key] = id end
    config:save()
    if config.data.lock then
        sync_now()
    else
        core.set_lock(true)
    end
    say(('Wearing %s.'):format(name))
end

function core.jobs()
    local jobs = {}
    for id, row in pairs(vana.gamedata.all('jobs')) do
        if id > 0 and id <= LAST_JOB and row.name ~= '' then jobs[#jobs + 1] = { id = id, short = row.short, name = row.name } end
    end
    table.sort(jobs, function (a, b) return a.id < b.id end)
    return jobs
end

function core.job_set(short)
    return config.data.job_sets[short]
end

function core.assign_job_set(short, name)
    config.data.job_sets[short] = name
    config:save()
    if name and short == core.current_job() then core.wear_set(name) end
end

function core.delete_set(name)
    config.data.sets[name] = nil
    for short, set in pairs(config.data.job_sets) do
        if set == name then config.data.job_sets[short] = nil end
    end
    config:save()
    say(('Deleted %s.'):format(name))
end

function core.start()
    vana.on('packet_in', on_packet)
    if vana.config.get('pivot', 'enabled') ~= '1' then
        print('[TransMog] Pivot is off, so mods will not load. Untick Ignore Pivot in the launcher.')
    end
    load_mounts()
    -- every load starts on each option's own: the pieces' own effects, and your own race
    config.data.effects = {}
    config.data.race, config.data.face, config.data.size = nil, nil, nil
    core.scan()
    for _, mod in ipairs(core.mods) do
        if mod.category == 'mount' and core.is_enabled(mod) then turn_off_rivals(mod) end
    end
    config:save()
    core.scan()
    core.apply()
    -- every recolorable piece is painted again: in its saved colors, or else its own, so a rebuilt mod or a preview
    -- left unsaved never stays in colors the Colors page doesn't show
    for _, mod in ipairs(core.recolorable()) do
        local saved = config.data.colors[mod.folder] or {}
        local info = colors.info(mod.path)    -- effects left on pieces no slot shows any more go; the shown get theirs
        for rel in pairs(info and info.files or {}) do
            if mod.folder == COLORS_MOD then repair_copy(mod, rel) end
            colors.apply(mod.path, saved[rel] or core.default_colors(mod, rel), rel)
            -- only a file given another effect needs its own back (every file, the first time, as nothing was noted)
            if not config.data.effects_noted or effects_changed()[rel] then restore_effects(rel) end
        end
    end
    config.data.effects_noted = true
    config:save()
    update_pending()
    local function on_zone() mark_loaded(); zoned(); sync_now() end
    vana.on('zone_change', on_zone)
    vana.on('login', on_zone)
    make_spares()
end

return core
