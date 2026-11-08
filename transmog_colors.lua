--[[
Recolors a gear mod while the game runs. A mod that can be recolored has a recolor.json, written with its maps by
tools\recolor_maps.py: for each texture, which pixels follow the main, dark and trim colors, and how bright. Painting
writes each such texture into the mod's DAT as an uncompressed one, so nothing needs compressing here, and the
character is then redrawn to pick up the file.
--]]

local ffi = require('ffi')

local colors = {}

local MANIFEST = 'recolor.json'
local CHUNK_HEADER = 16
local TEXTURE = 0x20
local HEADER = 57           -- an uncompressed texture's own header: flag, name and a 40 byte bitmap header
local NAME_AT = 1           -- where the texture's 16 letter name sits in that header
local SIZE_AT = 21          -- where its width and height sit
-- a palette's keys in order. Built gear uses the first three; a normal piece split by colors.prepare uses all.
colors.NAMES = { 'main', 'dark', 'trim', 'color4', 'color5', 'color6', 'color7', 'color8' }
colors.LABELS = { main = 'Main', dark = 'Shading', trim = 'Trim' }

local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function write(path, data)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function u32(data, at)
    local a, b, c, d = data:byte(at + 1, at + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

-- the recolor manifest of a mod's folder, or nil. Kept, as the window asks every frame; colors.forget drops them.
local infos = {}
function colors.info(folder)
    if infos[folder] == nil then
        local text = read(folder .. '\\' .. MANIFEST)
        infos[folder] = text and vana.json.decode(text) or false
    end
    return infos[folder] or nil
end

function colors.forget()
    infos = {}
end

local function hex(text)
    return (text:gsub('..', function (pair) return string.char(tonumber(pair, 16)) end))
end

local LIFT = 1.8            -- a group made this many times brighter is painted fresh, not moved

-- an uncompressed texture chunk painted from a map. Each pixel moves as far as its group's color moved from the
-- built one, in step with its brightness, so the built colors give back the texture as it was and its detail stays.
local function paint(entry, map, palette, built, template)
    local width, height = entry.width, entry.height
    local count = width * height
    local payload = HEADER + count * 4
    local size = math.ceil((CHUNK_HEADER + payload) / 16) * 16
    local out = ffi.new('uint8_t[?]', size)
    local name = entry.texture:sub(9, 12)
    ffi.copy(out, name, 4)
    ffi.copy(out + 4, le32(TEXTURE + size / 16 * 128), 4)
    ffi.copy(out + CHUNK_HEADER, template, HEADER)
    ffi.copy(out + CHUNK_HEADER + NAME_AT, entry.texture, 16)
    ffi.copy(out + CHUNK_HEADER + SIZE_AT, le32(width) .. le32(height), 8)
    local source = ffi.cast('const uint8_t *', map)
    local pixel = out + CHUNK_HEADER + HEADER
    -- a group made much brighter, black cloth made white, would wash out its highlights if moved: it is painted in its
    -- new color instead, with its light and shade softened by how much brighter it got
    local moves, lifts = {}, {}
    for i, key in ipairs(colors.NAMES) do
        local new, old = palette[key], built[key]
        moves[i] = new and old and { new[3] - old[3], new[2] - old[2], new[1] - old[1] } or { 0, 0, 0 }    -- b, g, r
        local new_length = new and math.sqrt(new[1] ^ 2 + new[2] ^ 2 + new[3] ^ 2) or 0
        local old_length = old and math.sqrt(old[1] ^ 2 + old[2] ^ 2 + old[3] ^ 2) or 0
        if new_length > LIFT * math.max(old_length, 1) then
            lifts[i] = { color = { new[3], new[2], new[1] }, soften = math.max(0.2, math.min(1, 2 * old_length / new_length)) }
        end
    end
    local function clamp(v) return v < 0 and 0 or v > 255 and 255 or v end
    for i = 0, count - 1 do
        local at = i * 6
        local class = source[at]
        local p = pixel + i * 4
        if class == 0 then
            p[0], p[1], p[2] = source[at + 3], source[at + 4], source[at + 5]
        elseif lifts[class] then
            local lift = lifts[class]
            local shade = 1 + (source[at + 1] / 100 - 1) * lift.soften
            p[0], p[1], p[2] = clamp(lift.color[1] * shade), clamp(lift.color[2] * shade), clamp(lift.color[3] * shade)
        else
            local move, scale = moves[class], source[at + 1] / 100
            p[0] = clamp(source[at + 3] + move[1] * scale)
            p[1] = clamp(source[at + 4] + move[2] * scale)
            p[2] = clamp(source[at + 5] + move[3] * scale)
        end
        p[3] = source[at + 2]
    end
    return ffi.string(out, size)
end

-- writes the textures of one of a mod's files, or all of them without rel, in the given colors
-- ({ main = {r, g, b}, ... } in 0 to 255). Returns the files it changed.
function colors.apply(folder, palette, only)
    local info = colors.info(folder)
    if not info then return nil, 'This mod has no recolor.json.' end
    local template = hex(info.header)
    local changed = {}
    for rel, entries in pairs(info.files) do
        if only and rel:lower() ~= only:lower() then goto next_file end
        local path = folder .. '\\' .. rel
        local data = read(path)
        if not data then return nil, 'Could not read ' .. rel end
        local wanted = {}
        for _, entry in ipairs(entries) do wanted[entry.texture] = entry end
        local built = entries[1].palette or info.palette
        local parts, offset = {}, 0
        while offset + CHUNK_HEADER <= #data do
            local value = u32(data, offset + 4)
            local size = math.floor(value / 128) % 524288 * 16
            if size < CHUNK_HEADER then break end
            local entry = value % 128 == TEXTURE and wanted[data:sub(offset + CHUNK_HEADER + NAME_AT + 1, offset + CHUNK_HEADER + NAME_AT + 16)]
            if entry then
                local map = read(folder .. '\\' .. entry.map:gsub('/', '\\'))
                if not map or #map ~= entry.width * entry.height * 6 then return nil, 'Missing map for ' .. entry.texture end
                parts[#parts + 1] = paint(entry, map, palette, built, template)
            else
                parts[#parts + 1] = data:sub(offset + 1, offset + size)
            end
            offset = offset + size
        end
        parts[#parts + 1] = data:sub(offset + 1)
        if not write(path, table.concat(parts)) then return nil, 'Could not write ' .. rel end
        changed[#changed + 1] = rel
        ::next_file::
    end
    return changed
end

-- Effects, such as Gyve Doublet's wings or a weapon's glow, are folders of their own inside a piece's file: children of
-- its outer folder, apart from its sound and motion folder and, in some weapons, a folder holding the model under
-- the outer folder's own name. They can be moved from one piece's file to another's. A folder holding a model or a
-- skeleton is the piece itself, whatever its name: the relic weapons and some shields keep theirs in one ("31em" in
-- Mandau's file), and moving it out leaves the weapon invisible.
-- The sound and motion folder is named for the race the file is for, as the outer folder is: "em_s" in "70em" (Elvaan
-- male), "gl_s" in "70gl" (Galka). Its last letter is the kind of weapon: moving it would hold a sword like a katana.
local FOLDER, END, INFO = 0x01, 0x00, 0x45
local MODEL_KINDS = { [0x29] = true, [0x2A] = true }    -- skeleton, mesh

local function is_motion(name, root)
    return name:sub(3, 3) == '_' and (name:sub(1, 2) == root:sub(3, 4) or name:sub(1, 3) == 'em_')
end

-- the names of a file's sound and motion folders, as one string: a copy should keep the game's file's
function colors.motion_folders(data)
    local names, depth, offset, root = {}, 0, 0, nil
    while data and offset + CHUNK_HEADER <= #data do
        local value = u32(data, offset + 4)
        local size = math.floor(value / 128) % 524288 * 16
        if size < CHUNK_HEADER then break end
        local kind, name = value % 128, data:sub(offset + 1, offset + 4)
        if kind == FOLDER then
            depth = depth + 1
            if depth == 1 then root = name end
            if depth == 2 and is_motion(name, root) then names[#names + 1] = name end
        elseif kind == END then
            depth = depth - 1
        end
        offset = offset + size
    end
    return table.concat(names, ',')
end

local function effect_blocks(data)
    local blocks, depth, offset, root, start = {}, 0, 0, nil, nil
    local info_at, has_model
    while offset + CHUNK_HEADER <= #data do
        local value = u32(data, offset + 4)
        local size = math.floor(value / 128) % 524288 * 16
        if size < CHUNK_HEADER then break end
        local kind, name = value % 128, data:sub(offset + 1, offset + 4)
        if kind == FOLDER then
            depth = depth + 1
            if depth == 1 then root = name end
            if depth == 2 and name ~= root and not is_motion(name, root) then start, has_model = offset, false end
        elseif kind == END then
            if depth == 2 and start then
                if not has_model then blocks[#blocks + 1] = { start, offset + size } end
                start = nil
            end
            if depth == 1 and not info_at then info_at = offset end    -- the outer folder's own end
            depth = depth - 1
        elseif kind == INFO and depth == 1 then
            info_at = offset
        elseif start and MODEL_KINDS[kind] then
            has_model = true
        end
        offset = offset + size
    end
    return blocks, info_at
end

-- how many meshes a file holds: a copy with fewer than the game's file lost one to an older TransMog
function colors.mesh_count(data)
    local count, offset = 0, 0
    while data and offset + CHUNK_HEADER <= #data do
        local value = u32(data, offset + 4)
        local size = math.floor(value / 128) % 524288 * 16
        if size < CHUNK_HEADER then break end
        if value % 128 == 0x2A then count = count + 1 end
        offset = offset + size
    end
    return count
end

-- a file's effect folders, as one string
function colors.effects_of(data)
    local parts = {}
    for _, block in ipairs((effect_blocks(data))) do parts[#parts + 1] = data:sub(block[1] + 1, block[2]) end
    return table.concat(parts)
end

-- takes a file's own effect folders out and puts these in their place, before the outer folder's info, or its end
function colors.set_effects(path, effects)
    local data = read(path)
    if not data then return nil, 'Could not read ' .. path end
    local blocks = effect_blocks(data)
    local parts, from = {}, 0
    for _, block in ipairs(blocks) do
        parts[#parts + 1] = data:sub(from + 1, block[1])
        from = block[2]
    end
    parts[#parts + 1] = data:sub(from + 1)
    local stripped = table.concat(parts)
    local _, at = effect_blocks(stripped)
    if not at then return nil, 'Could not find where effects go in ' .. path end
    local out = stripped:sub(1, at) .. (effects or '') .. stripped:sub(at + 1)
    if not write(path, out) then return nil, 'Could not write ' .. path end
    return true
end

function colors.read(path)
    return read(path)
end

local COMPRESSED = 0xA1
local UNCOMPRESSED = 0x91
local BLOCKS_AT = 69        -- where a compressed texture's blocks start, after its header and format tag
local GROUPS = 8            -- colors a piece is split into for recoloring
local ROUNDS = 8            -- passes that settle the groups
local SAMPLE = 5            -- every this many pixels is used to find the groups

local function color565(v)
    return math.floor(v / 2048) % 32 * 255 / 31, math.floor(v / 32) % 64 * 255 / 63, v % 32 * 255 / 31
end

-- a texture's pixels as r, g, b, alpha (0 to 128, as the game keeps it) arrays, bottom row first as maps are. Nil
-- for a format this doesn't read.
local function decode(data, payload, width, height)
    local count = width * height
    local r, g, b = ffi.new('float[?]', count), ffi.new('float[?]', count), ffi.new('float[?]', count)
    local a = ffi.new('uint8_t[?]', count)
    local flag = data:byte(payload + 1)
    if flag == UNCOMPRESSED then
        local p = ffi.cast('const uint8_t *', data) + payload + HEADER
        for i = 0, count - 1 do
            b[i], g[i], r[i], a[i] = p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]
        end
        return r, g, b, a
    end
    if flag ~= COMPRESSED or data:sub(payload + 58, payload + 61) ~= '3TXD' then return nil end
    local p = ffi.cast('const uint8_t *', data) + payload + BLOCKS_AT
    local block = 0
    for by = 0, height / 4 - 1 do
        for bx = 0, width / 4 - 1 do
            local q = p + block * 16
            local c0, c1 = q[8] + q[9] * 256, q[10] + q[11] * 256
            local bits = q[12] + q[13] * 256 + q[14] * 65536 + q[15] * 16777216
            local r0, g0, b0 = color565(c0)
            local r1, g1, b1 = color565(c1)
            local pr = { r0, r1, (2 * r0 + r1) / 3, (r0 + 2 * r1) / 3 }
            local pg = { g0, g1, (2 * g0 + g1) / 3, (g0 + 2 * g1) / 3 }
            local pb = { b0, b1, (2 * b0 + b1) / 3, (b0 + 2 * b1) / 3 }
            for j = 0, 15 do
                local pick = math.floor(bits / 4 ^ j) % 4 + 1
                local nibble = math.floor(q[math.floor(j / 2)] / (j % 2 == 1 and 16 or 1)) % 16
                local x, y = bx * 4 + j % 4, by * 4 + math.floor(j / 4)
                local i = (height - 1 - y) * width + x
                r[i], g[i], b[i] = pr[pick], pg[pick], pb[pick]
                a[i] = math.floor(nibble * 17 * 128 / 255 + 0.5)
            end
            block = block + 1
        end
    end
    return r, g, b, a
end

-- splits a texture's pixels into its main colors: each pixel's group and the groups' average colors, biggest first.
-- Pixels group by hue more than brightness, so the lit and shaded parts of one cloth stay one color. Given the
-- groups found in another texture of the same piece, it only sorts the pixels into those, so a group means the same
-- part everywhere.
local SHADE = 0.35          -- how much brightness counts against hue in grouping

local function feature(r, g, b)
    local sum = r + g + b + 30
    return r / sum * 300, g / sum * 300, b / sum * 300, sum / 3 * SHADE
end

local function find_groups(r, g, b, count, known)
    local centers = {}
    local function distance(i, c)
        local x1, x2, x3, x4 = feature(r[i], g[i], b[i])
        local d1, d2, d3, d4 = x1 - c[1], x2 - c[2], x3 - c[3], x4 - c[4]
        return d1 * d1 + d2 * d2 + d3 * d3 + d4 * d4
    end
    local function nearest(i)
        local best, best_d = 1, math.huge
        for k = 1, #centers do
            local d = distance(i, centers[k])
            if d < best_d then best, best_d = k, d end
        end
        return best
    end
    if known then
        for k = 1, GROUPS do centers[k] = known.features[k] end
    else    -- start from pixels as unlike each other as can be found
        local sample = {}
        for i = 0, count - 1, SAMPLE * 4 do sample[#sample + 1] = i end
        centers[1] = { feature(r[sample[1]], g[sample[1]], b[sample[1]]) }
        while #centers < GROUPS do
            local far, far_d = sample[1], -1
            for _, i in ipairs(sample) do
                local d = distance(i, centers[nearest(i)])
                if d > far_d then far, far_d = i, d end
            end
            centers[#centers + 1] = { feature(r[far], g[far], b[far]) }
        end
        for _ = 1, ROUNDS do
            local sums = {}
            for k = 1, GROUPS do sums[k] = { 0, 0, 0, 0, 0 } end
            for i = 0, count - 1, SAMPLE do
                local s = sums[nearest(i)]
                local x1, x2, x3, x4 = feature(r[i], g[i], b[i])
                s[1], s[2], s[3], s[4], s[5] = s[1] + x1, s[2] + x2, s[3] + x3, s[4] + x4, s[5] + 1
            end
            for k = 1, GROUPS do
                local s = sums[k]
                if s[5] > 0 then centers[k] = { s[1] / s[5], s[2] / s[5], s[3] / s[5], s[4] / s[5] } end
            end
        end
    end
    local group = ffi.new('uint8_t[?]', count)
    local sizes, colors_sum = {}, {}
    for k = 1, GROUPS do sizes[k], colors_sum[k] = 0, { 0, 0, 0 } end
    for i = 0, count - 1 do
        local k = nearest(i)
        group[i] = k
        sizes[k] = sizes[k] + 1
        local c = colors_sum[k]
        c[1], c[2], c[3] = c[1] + r[i], c[2] + g[i], c[3] + b[i]
    end
    if known then
        return group, known
    end
    local order = {}
    for k = 1, GROUPS do order[k] = k end
    table.sort(order, function (x, y) return sizes[x] > sizes[y] end)
    local rank = {}
    for place, k in ipairs(order) do rank[k] = place end
    for i = 0, count - 1 do group[i] = rank[group[i]] end
    local ordered = { features = {} }
    for place, k in ipairs(order) do
        local n, c = math.max(sizes[k], 1), colors_sum[k]
        ordered[place] = { c[1] / n, c[2] / n, c[3] / n }
        ordered.features[place] = centers[k]
    end
    return group, ordered
end

local function length(r, g, b)
    return math.sqrt(r * r + g * g + b * b)
end

-- how many triangles each texture is drawn on, by the 16 letter name the meshes give it: a file can hold textures
-- no mesh uses, such as another color of the piece
local MESH = 0x2A
local function texture_use(data)
    local use, offset = {}, 0
    while offset + CHUNK_HEADER <= #data do
        local value = u32(data, offset + 4)
        local size = math.floor(value / 128) % 524288 * 16
        if size < CHUNK_HEADER then break end
        if value % 128 == MESH then
            local c = offset + CHUNK_HEADER
            local function u16(at)
                local lo, hi = data:byte(c + at + 1, c + at + 2)
                return (lo or 0) + (hi or 0) * 256
            end
            local at = u16(6) * 2                                   -- the draw list, from the mesh's header
            local stop = math.min(at + u16(10) * 2, size - CHUNK_HEADER)
            local current = ''
            while at + 2 <= stop do
                local op = u16(at)
                if op == 0x8010 then
                    at = at + 46
                elseif op == 0x8000 then                            -- the texture the next triangles use
                    current = data:sub(c + at + 3, c + at + 18)
                    at = at + 18
                elseif op == 0x0054 then                            -- triangles
                    local n = u16(at + 2)
                    use[current] = (use[current] or 0) + n
                    at = at + 4 + 30 * n
                elseif op == 0x5453 then                            -- a strip
                    local n = u16(at + 2)
                    use[current] = (use[current] or 0) + n
                    at = at + 34 + 10 * math.max(n - 1, 0)
                else
                    break
                end
            end
        end
        offset = offset + size
    end
    return use
end

-- makes a normal piece recolorable: copies its file into the colors mod and writes maps of its own main colors.
-- folder is the colors mod, rel the file's ROM path, source where the game reads it now, title what to call it.
function colors.prepare(folder, rel, source, title)
    local data = read(source)
    if not data then return nil, 'Could not read ' .. rel end
    vana.fs.create_dir(folder .. '\\recolor')
    local info = colors.info(folder) or { files = {} }
    info.header = info.header or ('91' .. string.rep('00', 16) .. '28000000' .. string.rep('00', 8) .. '0200200000000000'
        .. string.rep('00', 16) .. '20000000')
    -- the textures, the most drawn first: its colors stand for the piece and set the groups the others sort into
    local use, textures, offset = texture_use(data), {}, 0
    while offset + CHUNK_HEADER <= #data do
        local value = u32(data, offset + 4)
        local size = math.floor(value / 128) % 524288 * 16
        if size < CHUNK_HEADER then break end
        if value % 128 == TEXTURE then
            local name = data:sub(offset + CHUNK_HEADER + NAME_AT + 1, offset + CHUNK_HEADER + NAME_AT + 16)
            textures[#textures + 1] = { offset = offset, use = use[name] or 0, order = #textures }
        end
        offset = offset + size
    end
    table.sort(textures, function (a, b)
        if a.use ~= b.use then return a.use > b.use end
        return a.order < b.order
    end)
    local entries, palette, known = {}, nil, nil
    for _, texture in ipairs(textures) do
        local offset = texture.offset
        do
            local payload = offset + CHUNK_HEADER
            local width, height = u32(data, payload + SIZE_AT), u32(data, payload + SIZE_AT + 4)
            local r, g, b, a = decode(data, payload, width, height)
            if r then
                local count = width * height
                local group, centers = find_groups(r, g, b, count, known)
                known = known or centers
                local map = ffi.new('uint8_t[?]', count * 6)
                for i = 0, count - 1 do
                    local c = centers[group[i]]
                    local scale = length(r[i], g[i], b[i]) / math.max(length(c[1], c[2], c[3]), 1)
                    local at = i * 6
                    map[at], map[at + 1], map[at + 2] = group[i], math.min(255, scale * 100 + 0.5), a[i]
                    map[at + 3], map[at + 4], map[at + 5] = b[i], g[i], r[i]
                end
                local texture = data:sub(payload + NAME_AT + 1, payload + NAME_AT + 16)
                local name = ('%s-%s.bin'):format(rel:gsub('[\\/]', '_'):gsub('%.DAT$', ''), texture:sub(9):gsub('%s+$', ''))
                write(folder .. '\\recolor\\' .. name, ffi.string(map, count * 6))
                entries[#entries + 1] = { texture = texture, width = width, height = height, map = 'recolor/' .. name }
                if not palette then    -- the most drawn texture's colors stand for the piece
                    palette = {}
                    for k, key in ipairs(colors.NAMES) do
                        local c = centers[k]
                        palette[key] = { math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5) }
                    end
                end
            end
        end
    end
    if #entries == 0 then return nil, title .. ' has no texture this can recolor.' end
    vana.fs.create_dir((folder .. '\\' .. rel):match('^(.*)\\'))
    if not write(folder .. '\\' .. rel, data) then return nil, 'Could not write ' .. rel end
    local labels = {}
    for k, key in ipairs(colors.NAMES) do labels[key] = 'Color ' .. k end
    entries[1].palette, entries[1].labels, entries[1].title = palette, labels, title
    info.files[rel] = entries
    write(folder .. '\\' .. MANIFEST, vana.json.encode(info))
    infos[folder] = nil
    return palette
end

-- moves a prepared piece to another path in the same mod: its file and its manifest entry, maps and all
function colors.rename(folder, old_rel, new_rel)
    local info = colors.info(folder)
    if not info or not info.files[old_rel] then return false end
    local data = read(folder .. '\\' .. old_rel)
    if not data then return false end
    vana.fs.create_dir((folder .. '\\' .. new_rel):match('^(.*)\\'))
    if not write(folder .. '\\' .. new_rel, data) then return false end
    info.files[new_rel], info.files[old_rel] = info.files[old_rel], nil
    write(folder .. '\\' .. MANIFEST, vana.json.encode(info))
    os.remove(folder .. '\\' .. old_rel)
    infos[folder] = nil
    return true
end

return colors
