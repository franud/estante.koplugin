--[[
Estante stats: read-only queries against the Statistics plugin database.
Everything degrades to nil if the DB is missing or busy.
]]
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Stats = {}

local function dbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

local function withDB(fn)
    local path = dbPath()
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local SQ3 = require("lua-ljsqlite3/init")
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok or not conn then return nil end
    local ok2, res = pcall(fn, conn)
    pcall(conn.close, conn)
    if not ok2 then
        logger.warn("Estante stats query failed:", res)
        return nil
    end
    return res
end

local function midnight(t)
    local d = os.date("*t", t or os.time())
    d.hour, d.min, d.sec = 0, 0, 0
    return os.time(d)
end

function Stats.overview()
    return withDB(function(conn)
        local res = {}
        local today = midnight()

        local row = conn:exec(string.format(
            "SELECT count(*), sum(d) FROM (SELECT sum(duration) AS d FROM page_stat_data WHERE start_time >= %d GROUP BY id_book, page)", today))
        res.today_pages = row and tonumber(row[1][1]) or 0
        res.today_secs = row and tonumber(row[2][1]) or 0

        -- pages per day for the last 7 days (oldest first)
        local week_start = today - 6 * 86400
        local per_day = {}
        local rows = conn:exec(string.format(
            "SELECT date(start_time,'unixepoch','localtime') AS d, count(DISTINCT id_book || '-' || page) FROM page_stat_data WHERE start_time >= %d GROUP BY d", week_start))
        if rows then
            for i = 1, #rows[1] do per_day[rows[1][i]] = tonumber(rows[2][i]) end
        end
        res.week = {}
        for i = 0, 6 do
            local t = week_start + i * 86400 + 3600 * 12
            local key = os.date("%Y-%m-%d", t)
            table.insert(res.week, { day = os.date("%a", t):sub(1, 1), pages = per_day[key] or 0, today = (i == 6) })
        end

        -- streak of consecutive reading days ending today (or yesterday)
        local days = conn:exec(string.format(
            "SELECT DISTINCT date(start_time,'unixepoch','localtime') FROM page_stat_data WHERE start_time >= %d", today - 400 * 86400))
        local set = {}
        if days then for i = 1, #days[1] do set[days[1][i]] = true end end
        local streak, t = 0, today + 3600 * 12
        if not set[os.date("%Y-%m-%d", t)] then t = t - 86400 end
        while set[os.date("%Y-%m-%d", t)] do
            streak = streak + 1
            t = t - 86400
        end
        res.streak = streak
        return res
    end)
end

-- Seconds-per-page for one book and an estimate of the time left.
function Stats.book(path, percent, pages)
    local md5
    local ok, ds = pcall(DocSettings.open, DocSettings, path)
    if ok and ds then
        md5 = ds:readSetting("partial_md5_checksum")
        pages = pages or ds:readSetting("doc_pages")
    end
    if not md5 then return nil end
    return withDB(function(conn)
        local stmt = conn:prepare("SELECT id, total_read_time, total_read_pages, pages FROM book WHERE md5 = ? ORDER BY last_open DESC LIMIT 1")
        local r = stmt:reset():bind(md5):step()
        stmt:close()
        if not r then return nil end
        local read_time, read_pages = tonumber(r[2]) or 0, tonumber(r[3]) or 0
        local total = pages or tonumber(r[4])
        local res = { read_time = read_time, read_pages = read_pages, total_pages = total }
        if read_pages > 5 and read_time > 0 and total then
            res.sec_per_page = read_time / read_pages
            local left_pages = math.max(0, math.floor(total * (1 - (percent or 0)) + 0.5))
            res.pages_left = left_pages
            res.secs_left = left_pages * res.sec_per_page
        end
        return res
    end)
end

return Stats
