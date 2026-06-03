-- ═══════════════════════════════════════════════════════════════
--  Fish It! Plaza Booth Sniper v5.0
--  Metode: Hook Replion RemoteEvent → scan SEMUA listing otomatis
--  Tidak ada filter item manual — semua listing terdeteksi
-- ═══════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local TeleportService   = game:GetService("TeleportService")

local lp      = Players.LocalPlayer
local placeId = game.PlaceId
local jobId   = game.JobId

-- ══════════════════════════════
--  CONFIG — edit bagian ini
-- ══════════════════════════════
local CFG = {
    WEBHOOK    = "https://discord.com/api/webhooks/1511803435706617907/ISbwuFnRw68XU2qvSgZ3IVCmxCn01jD3hROs_jPDiraWruyBsVzVsIcJF7m7Vy070a6e",
    HOP        = true,    -- auto pindah server setelah scan
    SCAN_WAIT  = 10,      -- detik tunggu data Replion masuk sebelum scan
    HOP_DELAY  = 5,       -- detik sebelum hop
    MIN_PLAYER = 10,      -- minimal pemain di server tujuan
    DEBUG      = false,   -- true = print semua listing yang ditemukan
}

-- ══════════════════════════════
--  HTTP
-- ══════════════════════════════
local httpReq = (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

if not httpReq then
    warn("[BoothSniper] HTTP tidak tersedia!")
    return
end

-- ══════════════════════════════
--  UTILITY
-- ══════════════════════════════
local function commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function postWebhook(body)
    if not CFG.WEBHOOK or CFG.WEBHOOK:find("DISINI") then return end
    pcall(httpReq, {
        Url     = CFG.WEBHOOK,
        Method  = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = HttpService:JSONEncode(body),
    })
end

-- ══════════════════════════════
--  REPLION HOOK
--  Intercept semua RemoteEvent di game
--  dan merge payload-nya ke indexData
-- ══════════════════════════════
local indexData = {}
local hooked    = {}

local function mergeTable(dst, src, depth)
    if type(src) ~= "table" or depth > 12 then return end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            mergeTable(dst[k], v, depth + 1)
        else
            dst[k] = v
        end
    end
end

local function hookRemote(rem)
    if hooked[rem] then return end
    hooked[rem] = true
    pcall(function()
        rem.OnClientEvent:Connect(function(...)
            for _, arg in ipairs({...}) do
                if type(arg) == "table" then
                    mergeTable(indexData, arg, 0)
                end
            end
        end)
    end)
end

local function hookTree(parent, depth)
    if depth > 14 then return end
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("RemoteEvent") then hookRemote(child) end
        pcall(hookTree, child, depth + 1)
    end
end

-- Hook semua remote yang sudah ada
hookTree(game, 0)

-- Watch remote baru yang muncul
game.DescendantAdded:Connect(function(obj)
    if obj:IsA("RemoteEvent") then hookRemote(obj) end
end)

-- ══════════════════════════════
--  EXTRACT LISTINGS
--  Cari semua entry yang punya field Price + Name
--  di dalam indexData secara rekursif
-- ══════════════════════════════

-- Key-key yang biasa dipakai game Fish It di Replion
local CONTAINER_KEYS = {
    "Booths","booths","Booth","booth",
    "Plaza","plaza","PlazaItems",
    "Listings","listings","Listing",
    "Market","market","Marketplace",
    "Shop","shop","Store","store",
    "Items","items","ForSale","forsale",
    "Data","data","PlayerData",
}

local function extractAll(tbl, path, depth, out)
    if type(tbl) ~= "table" or depth > 16 then return end

    -- Cek apakah tabel ini adalah listing
    local price = tonumber(
        tbl.Price   or tbl.price   or tbl.Cost   or tbl.cost
        or tbl.Tokens or tbl.tokens or tbl.TokenPrice
    )
    local name = tbl.Name or tbl.name or tbl.DisplayName or tbl.displayName
                 or tbl.ItemName or tbl.itemName

    if price and price > 0 and name and type(name) == "string" and name ~= "" then
        local uid = tostring(
            tbl.UUID or tbl.uuid or tbl.UID or tbl.uid
            or tbl.ListingId or tbl.listingId or tbl.Id or tbl.id or path
        )
        local key = uid.."_"..tostring(price)
        if not out[key] then
            out[key] = {
                uid     = uid,
                name    = name,
                price   = price,
                seller  = tostring(
                    tbl.Seller or tbl.seller or tbl.Owner or tbl.owner
                    or tbl.SellerName or tbl.PlayerName or tbl.Username or "Unknown"
                ),
                rap     = tonumber(tbl.RAP or tbl.rap or tbl.RecentAveragePrice or 0) or 0,
                alp     = tonumber(tbl.ALP or tbl.alp or tbl.AvgListedPrice or 0) or 0,
                alpCnt  = tonumber(tbl.ALPCount or tbl.ListingCount or 0) or 0,
                variant = tostring(tbl.VariantId or tbl.variantId or tbl.Variant or tbl.variant or ""),
                rarity  = tostring(tbl.Rarity or tbl.rarity or ""),
                itype   = tostring(tbl.ItemType or tbl.itemType or tbl.Type or tbl.type or ""),
                weight  = (function()
                    if type(tbl.Metadata) == "table" then
                        return tonumber(tbl.Metadata.Weight or tbl.Metadata.weight or 0) or 0
                    end
                    return tonumber(tbl.Weight or tbl.weight or 0) or 0
                end)(),
                path    = path,
            }
        end
    end

    -- Rekursi ke container keys terlebih dahulu
    for _, ck in ipairs(CONTAINER_KEYS) do
        if type(tbl[ck]) == "table" then
            extractAll(tbl[ck], path.."."..ck, depth + 1, out)
        end
    end

    -- Lalu rekursi ke semua anak (numeric/string key)
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            local ks = tostring(k)
            -- Hindari double-proses container key
            local skip = false
            for _, ck in ipairs(CONTAINER_KEYS) do
                if ks == ck then skip = true; break end
            end
            if not skip then
                extractAll(v, path.."."..ks, depth + 1, out)
            end
        end
    end
end

-- ══════════════════════════════
--  BUILD DISPLAY NAME
-- ══════════════════════════════
local function displayName(it)
    local s = it.name
    if it.variant ~= "" and it.variant ~= "None"
       and it.variant ~= "Default" and it.variant ~= "0" then
        s = s.." ["..it.variant.."]"
    end
    if it.rarity ~= "" and it.rarity ~= "Common" and it.rarity ~= "0" then
        s = s.." ("..it.rarity..")"
    end
    return s
end

-- ══════════════════════════════
--  BUILD & SEND DISCORD EMBED
-- ══════════════════════════════
local sentKeys = {}

local function buildAndSend(items)
    -- Filter anti-spam: hanya kirim yang belum pernah dikirim
    local fresh = {}
    for _, it in ipairs(items) do
        local k = it.uid.."_"..it.price
        if not sentKeys[k] then
            sentKeys[k] = os.clock()
            table.insert(fresh, it)
        end
    end
    if #fresh == 0 then return end

    local joinUrl = ("https://www.roblox.com/games/start?placeId=%d&gameInstanceId=%s"):format(placeId, jobId)
    local tpScript = ('game:GetService("TeleportService"):TeleportToPlaceInstance(%d,"%s",game.Players.LocalPlayer)'):format(placeId, jobId)

    local desc = ("**Server:** `%s`\n**Scanner:** @%s\n**Total:** %d listing (≤ %d tokens)\n\n🔗 **[Join Server](%s)**\n```\n%s\n```"):format(
        jobId:sub(1, 12), lp.Name, #fresh, CFG.MAX_PRICE, joinUrl, tpScript
    )

    -- Buat fields (max 25 per embed Discord)
    local allFields = {}
    for _, it in ipairs(fresh) do
        local nm     = displayName(it)
        local rapStr = it.rap > 0 and commas(it.rap) or "N/A"
        local rapPct = it.rap > 0 and math.floor(it.price / it.rap * 100) or 0
        local saveStr = it.rap > 0 and commas(it.rap - it.price) or "0"
        local alpStr = it.alp > 0
            and (commas(it.alp).." ("..math.floor(it.price / it.alp * 100).."%)")
            or "N/A"

        local typeStr = it.itype ~= "" and ("Type: `%s`\n"):format(it.itype) or ""

        table.insert(allFields, {
            name   = "🔥 SNIPE",
            value  = ("**%s**\nHarga: `%s` Tokens\nSeller: `%s`\n%sRAP: `%s` (%d%%)\nSave: `%s`\nALP: `%s`"):format(
                nm, commas(it.price), it.seller, typeStr, rapStr, rapPct, saveStr, alpStr
            ),
            inline = true,
        })
    end

    -- Kirim dalam batch 25 field per embed
    local batchSize = 25
    for i = 1, #allFields, batchSize do
        local batch = {}
        for j = i, math.min(i + batchSize - 1, #allFields) do
            table.insert(batch, allFields[j])
        end

        local embedTitle = ("🎣 Fish It Booth — %d Item ≤ %d Tokens"):format(#fresh, CFG.MAX_PRICE)
        if #allFields > batchSize then
            local page = math.ceil(i / batchSize)
            local total = math.ceil(#allFields / batchSize)
            embedTitle = embedTitle..(" [%d/%d]"):format(page, total)
        end

        postWebhook({
            username   = "Fish It Booth Sniper",
            avatar_url = "https://tr.rbxcdn.com/180DAY-"..lp.UserId,
            embeds     = {{
                title       = embedTitle,
                description = (i == 1) and desc or nil,
                color       = 3066993,
                fields      = batch,
                footer      = { text = "Fish It Sniper | @"..lp.Name.." | "..os.date("%d/%m %H:%M") },
            }},
        })

        if i + batchSize <= #allFields then task.wait(1) end
    end

    print(("✅ Dikirim %d listing ke Discord"):format(#fresh))

    -- Cleanup sentKeys lama (>10 menit)
    local now = os.clock()
    for k, t in pairs(sentKeys) do
        if now - t > 600 then sentKeys[k] = nil end
    end
end

-- ══════════════════════════════
--  SCAN FUNCTION
-- ══════════════════════════════
local scanNum = 0

local function doScan()
    scanNum = scanNum + 1
    print(("\n[SCAN #%d] %s"):format(scanNum, os.date("%H:%M:%S")))

    -- Extract semua listing dari data Replion yang sudah dikumpulkan
    local found = {}
    extractAll(indexData, "root", 0, found)

    -- Konversi dict → array (semua listing, tanpa filter harga)
    local items = {}
    for _, it in pairs(found) do
        table.insert(items, it)
    end

    -- Sort: harga termurah dulu
    table.sort(items, function(a, b) return a.price < b.price end)

    print(("📦 Dari Replion: %d listing ditemukan"):format(#items))

    if CFG.DEBUG then
        for i, it in ipairs(items) do
            print(("  #%d [%s] %s | %s tkn | RAP:%s | seller:%s | path:%s"):format(
                i, it.itype, it.name, commas(it.price), commas(it.rap), it.seller, it.path:sub(1,60)
            ))
        end
    end

    if #items == 0 then
        print("⚠️ Tidak ada listing yang cocok. Coba FS.dump() untuk lihat data mentah.")
        return
    end

    buildAndSend(items)
end

-- ══════════════════════════════
--  SERVER HOP
-- ══════════════════════════════
local hopNum = 0

local function fetchServers()
    local list, cursor, pages = {}, "", 0
    repeat
        pages = pages + 1
        local urlFmt = "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&cursor=%s"
        local url = urlFmt:format(placeId, cursor)
        local ok, res = pcall(httpReq, { Url = url, Method = "GET" })
        if not ok or not res then break end
        local ok2, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
        if not ok2 or not data or not data.data then break end
        for _, s in ipairs(data.data) do
            local cnt = s.playing or 0
            if s.id and s.id ~= jobId and cnt >= CFG.MIN_PLAYER then
                table.insert(list, { id = s.id, players = cnt, maxPlr = s.maxPlayers or 0 })
            end
        end
        cursor = data.nextPageCursor or ""
    until cursor == "" or #list >= 100 or pages >= 5
    table.sort(list, function(a, b) return a.players > b.players end)
    return list
end

local function hopServer()
    hopNum = hopNum + 1
    print(("\n[HOP #%d]"):format(hopNum))

    local servers = fetchServers()
    if #servers == 0 then
        print("⚠️ Tidak ada server tersedia. Retry 30s...")
        task.wait(30)
        return hopServer()
    end

    print(("📋 %d server (min %d players)"):format(#servers, CFG.MIN_PLAYER))

    postWebhook({
        username = "Fish It Booth Sniper",
        embeds   = {{
            title = "🔄 Server Hop #"..hopNum,
            description = ("**From:** `%s`\n**To:** `%s` (%d players)"):format(
                jobId:sub(1,12), servers[1].id:sub(1,12), servers[1].players),
            color  = 15844367,
            footer = { text = "@"..lp.Name.." • "..os.date("%H:%M:%S") },
        }},
    })

    for _, srv in ipairs(servers) do
        task.wait(CFG.HOP_DELAY)
        print(("  → %s (%d/%d players)"):format(srv.id:sub(1,12), srv.players, srv.maxPlr))

        local failed = false
        local conn
        pcall(function()
            conn = TeleportService.TeleportInitFailed:Connect(function(plr)
                if plr == lp then failed = true end
            end)
        end)

        local ok = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, placeId, srv.id, lp)
        if ok then
            task.wait(15)
            if conn then pcall(function() conn:Disconnect() end) end
            if not failed then
                print("✅ Teleport berhasil!")
                task.wait(30); return
            end
        end
        if conn then pcall(function() conn:Disconnect() end) end
        print("  ⚠️ Gagal, coba server lain...")
    end

    print("❌ Semua server gagal. Retry 30s...")
    task.wait(30)
    hopServer()
end

-- ══════════════════════════════
--  QUEUE ON TELEPORT
-- ══════════════════════════════
local function setupQueue()
    local url = pcall(function() return getgenv().FISH_SCRIPT_URL end)
        and getgenv().FISH_SCRIPT_URL or nil

    local qs = url
        and ('task.wait(5)\nloadstring(game:HttpGet("'..url..'"))()')
        or 'task.wait(3)\nprint("[FishSniper] Set getgenv().FISH_SCRIPT_URL untuk auto-execute!")'

    local ok = false
    if queue_on_teleport then pcall(queue_on_teleport, qs); ok = true
    elseif syn and syn.queue_on_teleport then pcall(syn.queue_on_teleport, qs); ok = true
    elseif fluxus and fluxus.queue_on_teleport then pcall(fluxus.queue_on_teleport, qs); ok = true
    end
    print(ok and "✅ Queue on teleport aktif!" or "⚠️ queue_on_teleport tidak tersedia")
end

-- ══════════════════════════════
--  DEBUG: DUMP DATA MENTAH
-- ══════════════════════════════
local function dumpIndex()
    print("\n📂 ══ REPLION DATA DUMP ══")
    local n = 0
    local function d(t, pre, depth)
        if type(t) ~= "table" or depth > 5 then return end
        for k, v in pairs(t) do
            n = n + 1; if n > 400 then print("[...truncated]"); return end
            if type(v) == "table" then
                print(pre..tostring(k).." {}")
                d(v, pre.."  ", depth + 1)
            else
                print(pre..tostring(k).." = "..tostring(v):sub(1, 80))
            end
        end
    end
    d(indexData, "  ", 0)
    print(("══ END (%d entries) ══\n"):format(n))
end

-- ══════════════════════════════
--  MAIN
-- ══════════════════════════════
print("[FishSniper] Fish It! Plaza Booth Sniper v5.0")
print("[FishSniper] Method : Replion Hook (scan all)")
print("[FishSniper] Scanner: "..lp.Name)
print("[FishSniper] Server : "..jobId:sub(1,12))
print("[FishSniper] AutoHop: "..(CFG.HOP and "ON" or "OFF"))

setupQueue()

-- Tunggu data Replion masuk
print(("\n⏳ Menunggu %ds agar data Replion terisi..."):format(CFG.SCAN_WAIT))
task.wait(CFG.SCAN_WAIT)

-- Scan 1x lalu langsung hop
doScan()

if CFG.HOP then
    print("\n🔄 Scan selesai — pindah server...")
    task.wait(2)
    hopServer()
end

-- ══════════════════════════════
--  GLOBAL COMMANDS (F9 Console)
-- ══════════════════════════════
getgenv().FS = {
    scan    = doScan,
    dump    = dumpIndex,
    hop     = hopServer,
    webhook = function(u) CFG.WEBHOOK = u; print("[FS] Webhook set") end,
    debug   = function(v) CFG.DEBUG = v;   print("[FS] Debug: "..tostring(v)) end,
    hop_on  = function(v) CFG.HOP = v;     print("[FS] AutoHop: "..tostring(v)) end,
}

print("[FS] Commands: FS.scan() | FS.dump() | FS.hop() | FS.debug(true) | FS.hop_on(false)")
