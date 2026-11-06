--[[
Estante library: scans the configured roots for documents and builds a flat,
sorted list of book entries enriched with reading status and progress.
Cheap enough to run on every show (~100 books on a Clara HD).
]]
local BookList = require("ui/widget/booklist")
local DocumentRegistry = require("document/documentregistry")
local ReadHistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Library = {}

local SKIP_EXT = { md = true, txt = true, png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, lua = true, json = true, html = true, htm = true, log = true }

local function bookInfoManager()
    -- CoverBrowser keeps its singleton here once loaded; we reuse it (shared DB + cache).
    return package.loaded["bookinfomanager"]
end
Library.bookInfoManager = bookInfoManager

-- "Debt_ The First 5,000 Years - David Graeber.EPUB" -> title, author
local function parseFilename(name, is_article)
    local base = name:gsub("%.[^.]+$", "")
    if is_article then
        base = base:gsub("^%[w%-id_%d+%]%s*", "")
        return (base:gsub("_ ", ": ")), nil
    end
    local title, author = base:match("^(.-)%s+%-%s+([^%-]+)$")
    if not title then
        title = base
    end
    title = title:gsub("_ ", ": "):gsub("%s*%(.-%)%s*$", "")
    if author then
        author = author:gsub("%s+$", "")
        if author:lower() == "unknown author" then author = nil end
    end
    return title, author
end

local function scanDir(dir, root, out, depth)
    if depth > 6 then return end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                if not name:match("%.sdr$") and not (root.is_articles and name == "archive") then
                    scanDir(path, root, out, depth + 1)
                end
            elseif attr and attr.mode == "file" then
                local ext = (name:match("%.([^.]+)$") or ""):lower()
                if not SKIP_EXT[ext] and DocumentRegistry:hasProvider(path) then
                    local rel = path:sub(#root.path + 2)
                    local shelf = rel:match("^([^/]+)/")
                    if root.is_articles then shelf = root.label end
                    table.insert(out, {
                        path = path,
                        name = name,
                        ext = ext,
                        mtime = attr.modification or 0,
                        shelf = shelf, -- nil = loose on the top shelf
                        is_article = root.is_articles or false,
                    })
                end
            end
        end
    end
end

function Library.roots()
    local roots = {}
    local home = G_reader_settings:readSetting("home_dir") or "/mnt/onboard/Books"
    table.insert(roots, { path = home, label = nil })
    local extra = G_reader_settings:readSetting("estante_extra_roots") or {}
    for _, r in ipairs(extra) do
        if r.path ~= home and lfs.attributes(r.path, "mode") == "directory" then
            table.insert(roots, r)
        end
    end
    return roots
end

function Library.scan()
    local t0 = os.clock()
    local books = {}
    for _, root in ipairs(Library.roots()) do
        if lfs.attributes(root.path, "mode") == "directory" then
            scanDir(root.path, root, books, 0)
        end
    end

    -- last opened times from history
    local last_open = {}
    ReadHistory:_read()
    for _, h in ipairs(ReadHistory.hist or {}) do
        if h.file and not last_open[h.file] then
            last_open[h.file] = h.time
        end
    end

    local BIM = bookInfoManager()
    for _, b in ipairs(books) do
        local info = BookList.getBookInfo(b.path)
        b.opened = info.been_opened or false
        b.status = b.opened and (info.status or "reading") or "new"
        b.percent = info.percent_finished or 0
        b.pages = info.pages
        b.last_open = last_open[b.path]
        local title, author = parseFilename(b.name, b.is_article)
        b.title, b.authors = title, author
        if BIM then
            local ok, bi = pcall(BIM.getBookInfo, BIM, b.path, false)
            if ok and bi then
                b.indexed = true
                if bi.title and bi.title ~= "" and not bi.ignore_meta then b.title = bi.title end
                if bi.authors and bi.authors ~= "" and not bi.ignore_meta then
                    b.authors = bi.authors:gsub("\n", ", ")
                end
                b.has_cover = bi.has_cover and not bi.ignore_cover
                b.series = bi.series
            end
        end
    end

    table.sort(books, function(a, c)
        local la, lc = a.last_open or 0, c.last_open or 0
        if la ~= lc then return la > lc end
        if a.mtime ~= c.mtime then return a.mtime > c.mtime end
        return a.title < c.title
    end)
    logger.dbg("Estante: scanned", #books, "books in", os.clock() - t0, "s")
    return books
end

-- The book on the desk: last file if it's still in progress, else most recent "reading".
function Library.current(books)
    local last = G_reader_settings:readSetting("lastfile")
    for _, b in ipairs(books) do
        if b.path == last and b.status ~= "complete" then return b end
    end
    for _, b in ipairs(books) do
        if b.status == "reading" then return b end
    end
    return nil
end

function Library.filter(books, view)
    local out = {}
    for _, b in ipairs(books) do
        local keep
        if view.kind == "all" then keep = not b.is_article
        elseif view.kind == "reading" then keep = b.status == "reading" or b.status == "abandoned"
        elseif view.kind == "unread" then keep = b.status == "new" and not b.is_article
        elseif view.kind == "finished" then keep = b.status == "complete"
        end
        if keep then table.insert(out, b) end
    end
    return out
end

return Library
