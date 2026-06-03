-- ================================================================
--  Fish It! Plaza Booth Sniper v6.0
--  Path: Workspace.Islands.TradePlaza.Booths.Booth.Plane.SurfaceGui
--  Labels: [Label]=price, [Label]=name, [VariantLabel]=variant,
--          [Label]=rarity, [Label]=size, [Label]=weight(kg)
-- ================================================================

local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")
local Workspace       = game:GetService("Workspace")

local lp      = Players.LocalPlayer
local placeId = game.PlaceId
local jobId   = game.JobId

-- ────────────────────────────────
--  KONFIGURASI
-- ────────────────────────────────
local WEBHOOK    = "https://discord.com/api/webhooks/1511803435706617907/ISbwuFnRw68XU2qvSgZ3IVCmxCn01jD3hROs_jPDiraWruyBsVzVsIcJF7m7Vy070a6e"
local SCAN_WAIT  = 8
local HOP        = true
local HOP_DELAY  = 3
local MIN_PLAYER = 5

-- ────────────────────────────────
--  HTTP
-- ────────────────────────────────
local httpReq = (syn and syn.request)
    or (http and http.request)
    or (fluxus and fluxus.request)
    or http_request
    or request

if not httpReq then warn("[BoothSniper] HTTP tidak tersedia!"); return end

local function postWebhook(payload)
    local ok, body = pcall(HttpService.JSONEncode, HttpService, payload)
    if not ok then
        print("[Webhook] JSON encode gagal: " .. tostring(body))
        return
    end
    local ok2, res = pcall(httpReq, {
        Url     = WEBHOOK,
        Method  = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = body,
    })
    if not ok2 then
        print("[Webhook] HTTP request gagal: " .. tostring(res))
    elseif res and res.StatusCode and res.StatusCode >= 400 then
        print(("[Webhook] Error %d: %s"):format(res.StatusCode, tostring(res.Body):sub(1, 100)))
    else
        print("[Webhook] OK " .. tostring(res and res.StatusCode or "?"))
    end
end

local function commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- ────────────────────────────────
--  PARSER: ambil semua label dari SurfaceGui secara berurutan
-- ────────────────────────────────
local function collectOrderedLabels(inst, res, depth)
    if depth > 15 then return end
    for _, ch in ipairs(inst:GetChildren()) do
        if (ch:IsA("TextLabel") or ch:IsA("TextButton")) and ch.Text ~= "" then
            table.insert(res, { name = ch.Name, text = ch.Text })
        end
        collectOrderedLabels(ch, res, depth + 1)
    end
end

-- Parse flat label list menjadi item array
-- Pattern per item: price(Label) → name(Label) → [VariantLabel] → rarity/size/weight(Label)
local function parseItems(labels, seller)
    local items = {}

    local function isNumericPrice(tv)
        local c = tv:gsub(",", "")
        local n = tonumber(c)
        return n ~= nil and not tv:lower():find("kg") and n > 0 and n < 10000000
    end

    local function isWeight(tv)
        return tv:lower():find("kg") ~= nil
    end

    local KNOWN_RARITY = {
        shiny=true, radioactive=true, albino=true, melanistic=true, golden=true,
        glowing=true, neon=true, special=true, corrupted=true, mythic=true,
    }
    local KNOWN_SIZE = {
        big=true, small=true, tiny=true, colossal=true, giant=true,
        huge=true, massive=true, mega=true, mini=true, large=true,
    }

    local i = 1
    while i <= #labels do
        local lbl = labels[i]

        -- Cari Label yang berisi harga (angka polos)
        if lbl.name == "Label" and isNumericPrice(lbl.text) then
            local price = tonumber((lbl.text:gsub(",", "")))
            local name, variant, rarity, size, weight

            -- Label berikutnya = nama item (teks, bukan angka, bukan kg)
            i = i + 1
            if i <= #labels and labels[i].name == "Label"
                and not isNumericPrice(labels[i].text)
                and not isWeight(labels[i].text) then
                name = labels[i].text
                i = i + 1
            end

            -- VariantLabel (opsional, tapi label namanya berbeda)
            if i <= #labels and labels[i].name == "VariantLabel" then
                variant = labels[i].text
                i = i + 1
            end

            -- Sisa Labels (rarity, size, weight) sampai ketemu harga berikutnya
            while i <= #labels do
                local next = labels[i]
                -- Berhenti jika ini adalah harga item berikutnya
                if next.name == "Label" and isNumericPrice(next.text) then
                    break
                end
                if next.name == "Label" or next.name == "VariantLabel" then
                    local tv  = next.text
                    local tvl = tv:lower()
                    if isWeight(tv) then
                        weight = tv
                    elseif KNOWN_RARITY[tvl] then
                        rarity = tv
                    elseif KNOWN_SIZE[tvl] then
                        size = tv
                    end
                end
                i = i + 1
            end

            -- Simpan item jika ada nama dan harga
            if name and price and price > 0 then
                -- Skip duplikat "Total Sales" (harga terlalu besar tanpa nama item yang valid)
                local isTotal = (not name:find("%S")) -- nama kosong/spasi saja
                if not isTotal then
                    table.insert(items, {
                        name    = name,
                        price   = price,
                        variant = variant or "",
                        rarity  = rarity or "",
                        size    = size or "",
                        weight  = weight or "",
                        seller  = seller or "Unknown",
                    })
                    print(("[ITEM] %s | %s tkn | variant:%s | seller:%s"):format(
                        name, commas(price), variant or "-", seller or "?"))
                end
            end
        else
            i = i + 1
        end
    end

    return items
end

-- ────────────────────────────────
--  SCAN BOOTHS
-- ────────────────────────────────
local function scanBooths()
    local allItems = {}
    local _rawPrinted = false

    -- Navigasi ke TradePlaza.Booths
    local islands   = Workspace:FindFirstChild("Islands")
    local tradePlaza = islands and islands:FindFirstChild("TradePlaza")
    if not tradePlaza then
        -- Cari rekursif
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d.Name == "TradePlaza" then tradePlaza = d; break end
        end
    end

    if not tradePlaza then
        print("[BoothSniper] TradePlaza tidak ditemukan!")
        return allItems
    end

    local booths = tradePlaza:FindFirstChild("Booths")
    if not booths then
        -- Cari langsung di TradePlaza
        for _, ch in ipairs(tradePlaza:GetChildren()) do
            if ch.Name:lower():find("booth") then booths = ch; break end
        end
    end

    if not booths then
        print("[BoothSniper] Folder Booths tidak ditemukan di TradePlaza!")
        return allItems
    end

    print(("[BoothSniper] Scan %d booth..."):format(#booths:GetChildren()))

    -- Helper: cocokkan "Name's Booth" termasuk Unicode apostrophe (')
    local function matchBoothOwner(txt)
        if not txt or txt == "" then return nil end
        -- ASCII apostrophe
        local nm = txt:match("^(.+)'s [Bb]ooth")
        if nm then return nm end
        -- Unicode right single quote '
        nm = txt:match("^(.+)\u{2019}s [Bb]ooth")
        if nm then return nm end
        -- Just "Booth" suffix
        nm = txt:match("^(.+) [Bb]ooth$")
        if nm and #nm > 1 and #nm < 40 then return nm end
        return nil
    end

    local _rawPrinted = false

    for _, boothModel in ipairs(booths:GetChildren()) do

        -- ── LANGKAH 1: Cari seller dari SEMUA TextLabel di seluruh booth model ──
        local seller = nil
        for _, d in ipairs(boothModel:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" then
                local nm = matchBoothOwner(d.Text)
                if nm then seller = nm; break end
            end
        end
        -- Fallback: coba dari nama objek yang ada username pattern
        if not seller then
            for _, d in ipairs(boothModel:GetDescendants()) do
                if d.Name == "OwnerLabel" or d.Name == "Owner" or d.Name == "Username" then
                    if d:IsA("TextLabel") or d:IsA("TextButton") then
                        seller = (d.Text:gsub("^@", ""))
                        if seller ~= "" then break end
                    end
                end
            end
        end

        -- ── LANGKAH 2: Cari SurfaceGui item list (Plane face) ──
        local surfaceGui = nil
        local plane = boothModel:FindFirstChild("Plane")
        if plane then
            surfaceGui = plane:FindFirstChildOfClass("SurfaceGui")
        end
        -- Fallback: SurfaceGui dengan paling banyak label
        if not surfaceGui then
            local maxLabels = 0
            for _, d in ipairs(boothModel:GetDescendants()) do
                if d:IsA("SurfaceGui") then
                    local cnt = 0
                    for _, dd in ipairs(d:GetDescendants()) do
                        if (dd:IsA("TextLabel") or dd:IsA("TextButton")) and dd.Text ~= "" then
                            cnt = cnt + 1
                        end
                    end
                    if cnt > maxLabels then
                        maxLabels = cnt
                        surfaceGui = d
                    end
                end
            end
        end

        if not surfaceGui then continue end

        -- ── LANGKAH 3: Kumpulkan labels dari SurfaceGui ──
        local labels = {}
        collectOrderedLabels(surfaceGui, labels, 0)
        if #labels == 0 then continue end

        -- Seller fallback dari labels jika belum dapat
        if not seller then
            for _, lbl in ipairs(labels) do
                local nm = matchBoothOwner(lbl.text)
                if nm then seller = nm; break end
            end
        end
        if not seller then seller = "Unknown" end

        -- DEBUG: Print raw label booth pertama
        if not _rawPrinted then
            _rawPrinted = true
            print("\n[RAW] Booth: " .. seller .. " | " .. surfaceGui:GetFullName())
            for idx, lbl in ipairs(labels) do
                print(("  [%d] name='%s' text='%s'"):format(idx, lbl.name, lbl.text:sub(1, 50)))
                if idx >= 30 then print("  ... (truncated)"); break end
            end
        end

        -- ── LANGKAH 4: Parse items ──
        local items = parseItems(labels, seller)
        for _, it in ipairs(items) do
            table.insert(allItems, it)
        end
    end

    return allItems
end


-- ────────────────────────────────
--  KIRIM KE DISCORD
-- ────────────────────────────────
local function sendToDiscord(items)
    if #items == 0 then
        print("[Discord] Tidak ada item ditemukan")
        return
    end

    print(("[Discord] Mengirim %d item ke webhook..."):format(#items))

    local joinUrl  = ("https://www.roblox.com/games/start?placeId=%d&gameInstanceId=%s"):format(placeId, jobId)
    local tpScript = ('game:GetService("TeleportService"):TeleportToPlaceInstance(%d, "%s", game.Players.LocalPlayer)'):format(placeId, jobId)

    local desc = ("**[Fish It -- Snipe]** Server: %s\nScanner: @%s\nTotal: **%d item**\n[Join Server](%s)\nJoin Script:\n```\n%s\n```"):format(
        jobId:sub(1, 8), lp.Name, #items, joinUrl, tpScript)

    local footer = ("Fish It Sniper | @%s | PlaceId: %d | %s"):format(lp.Name, placeId, os.date("%d/%m/%Y %H:%M"))

    -- Build fields — semua item tanpa filter
    local fields = {}
    for i, it in ipairs(items) do
        local varStr  = it.variant ~= "" and ("\nVariant: **" .. it.variant .. "**") or ""
        local rarStr  = it.rarity  ~= "" and (" | " .. it.rarity) or ""
        local sizeStr = it.size    ~= "" and (it.size .. " ") or ""
        local wStr    = it.weight  ~= "" and (" | " .. it.weight) or ""

        local val = ("Nama: **%s**%s\nHarga: **%s Tokens**\nSeller: %s\nDetail: %s%s%s"):format(
            it.name, varStr, commas(it.price), it.seller, sizeStr, rarStr, wStr)
        table.insert(fields, {
            name   = "🔥 #" .. i .. " SNIPE",
            value  = val,
            inline = true,
        })
    end

    -- Kirim per batch 25 field
    for i = 1, #fields, 25 do
        local batch = {}
        for j = i, math.min(i + 24, #fields) do
            table.insert(batch, fields[j])
        end
        local pg = #fields > 25 and (" [" .. math.ceil(i/25) .. "/" .. math.ceil(#fields/25) .. "]") or ""
        postWebhook({
            username = "Fish It Booth Sniper",
            embeds   = {{
                title       = "[Fish It] Snipe" .. pg,
                description = (i == 1) and desc or nil,
                color       = 15105570,
                fields      = batch,
                footer      = { text = footer },
            }},
        })
        if i + 25 <= #fields then task.wait(1) end
    end

    print(("[BoothSniper] Terkirim %d item ke Discord"):format(#items))
end


-- ────────────────────────────────
--  SERVER HOP
-- ────────────────────────────────
local function hopServer()
    print("[HOP] Mencari server...")
    local list, cursor = {}, ""
    for _ = 1, 5 do
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&cursor=%s"):format(placeId, cursor)
        local ok, res = pcall(httpReq, { Url = url, Method = "GET" })
        if not ok or not res then break end
        local ok2, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
        if not ok2 or not data or not data.data then break end
        for _, s in ipairs(data.data) do
            if s.id and s.id ~= jobId and (s.playing or 0) >= MIN_PLAYER then
                table.insert(list, { id = s.id, players = s.playing or 0 })
            end
        end
        cursor = data.nextPageCursor or ""
        if cursor == "" or #list >= 50 then break end
    end

    if #list == 0 then
        print("[HOP] Tidak ada server. Retry 30s...")
        task.wait(30); return hopServer()
    end

    table.sort(list, function(a, b) return a.players > b.players end)
    print(("[HOP] %d server, masuk %s (%d players)"):format(#list, list[1].id:sub(1,12), list[1].players))

    for _, srv in ipairs(list) do
        task.wait(HOP_DELAY)
        local failed, conn = false, nil
        pcall(function()
            conn = TeleportService.TeleportInitFailed:Connect(function(p)
                if p == lp then failed = true end
            end)
        end)
        local ok = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, placeId, srv.id, lp)
        if ok then
            task.wait(15)
            if conn then pcall(function() conn:Disconnect() end) end
            if not failed then print("[HOP] Berhasil!"); task.wait(30); return end
        end
        if conn then pcall(function() conn:Disconnect() end) end
    end

    print("[HOP] Semua gagal. Retry 30s...")
    task.wait(30); hopServer()
end

-- ────────────────────────────────
--  MAIN
-- ────────────────────────────────
print("[BoothSniper] Fish It Plaza Booth Sniper v6.0")
print("[BoothSniper] Scanner: " .. lp.Name)
print("[BoothSniper] Server : " .. jobId:sub(1, 12))
print("[BoothSniper] Menunggu " .. SCAN_WAIT .. "s...")

task.wait(SCAN_WAIT)

print("[BoothSniper] Mulai scan booth...")
local items = scanBooths()
print(("[BoothSniper] Total: %d item ditemukan"):format(#items))

if #items > 0 then
    sendToDiscord(items)
else
    print("[BoothSniper] Tidak ada item. Cek apakah ada booth yang aktif di server ini.")
end

if HOP then
    print("[BoothSniper] Pindah server...")
    task.wait(2)
    hopServer()
end
