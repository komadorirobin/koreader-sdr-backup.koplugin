local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local GITHUB_OWNER = "komadorirobin"
local GITHUB_REPO = "koreader-sdr-backup.koplugin"
local UPDATE_FILES = { "main.lua", "sdrbackup_updater.lua", "_meta.lua" }
local API_URL = string.format(
    "https://api.github.com/repos/%s/%s/releases/latest",
    GITHUB_OWNER,
    GITHUB_REPO
)

local Updater = {}
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/storage/emulated/0/koreader/plugins/sdrbackup.koplugin"

local function currentVersion()
    local ok, meta = pcall(dofile, PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then return tostring(meta.version) end
    return "0.0.0"
end

local function versionParts(version)
    local clean = tostring(version or ""):match("^v?([^+-]+)") or ""
    local parts = {}
    for number in (clean .. "."):gmatch("(%d+)%.") do parts[#parts + 1] = tonumber(number) or 0 end
    while #parts < 3 do parts[#parts + 1] = 0 end
    return parts
end

local function versionGreaterThan(left, right)
    local a, b = versionParts(left), versionParts(right)
    for index = 1, math.max(#a, #b) do
        local av, bv = a[index] or 0, b[index] or 0
        if av > bv then return true end
        if av < bv then return false end
    end
    return false
end

local function toast(text, timeout)
    local widget = InfoMessage:new{ text = text, timeout = timeout or 4 }
    UIManager:show(widget)
    return widget
end

local function closeWidget(widget)
    if widget then UIManager:close(widget) end
end

local function httpRequest(url, sink, accept, block_timeout, total_timeout)
    local http = require("socket/http")
    local socket = require("socket")
    local ok_socketutil, socketutil = pcall(require, "socketutil")
    if ok_socketutil then
        socketutil:set_timeout(
            block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
            total_timeout or socketutil.LARGE_TOTAL_TIMEOUT
        )
    end
    local ok, first, code, headers, status = pcall(http.request, {
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader-SDRBackup-Updater/1.0",
            ["Accept"] = accept or "*/*",
        },
        sink = sink,
        redirect = true,
    })
    if ok_socketutil then pcall(function() socketutil:reset_timeout() end) end
    if not ok then return nil, tostring(first) end
    if headers == nil then return nil, "network error (" .. tostring(code or status or first) .. ")" end
    if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
    return true
end

local function httpGet(url, accept)
    local ltn12 = require("ltn12")
    local chunks = {}
    local ok, err = httpRequest(url, ltn12.sink.table(chunks), accept)
    if not ok then return nil, err end
    return table.concat(chunks)
end

local function httpGetToFile(url, path)
    local ltn12 = require("ltn12")
    local file, open_err = io.open(path, "wb")
    if not file then return nil, "cannot create file: " .. tostring(open_err) end
    local sink = ltn12.sink.file(file)
    local ok_socketutil, socketutil = pcall(require, "socketutil")
    if ok_socketutil then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        sink = socketutil.file_sink(file)
    end
    local ok, err = httpRequest(
        url,
        sink,
        "application/octet-stream",
        ok_socketutil and socketutil.FILE_BLOCK_TIMEOUT or nil,
        ok_socketutil and socketutil.FILE_TOTAL_TIMEOUT or nil
    )
    if not ok then pcall(os.remove, path); return nil, err end
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path)
    if not attr or attr.size == 0 then pcall(os.remove, path); return nil, "downloaded file is empty" end
    return true
end

local function cleanNotes(notes)
    if type(notes) ~= "string" or notes == "" then return nil end
    notes = notes:gsub("#+%s*", ""):gsub("%*%*(.-)%*%*", "%1"):gsub("`(.-)`", "%1")
        :gsub("\r\n", "\n"):gsub("\r", "\n"):match("^%s*(.-)%s*$")
    if #notes > 700 then notes = notes:sub(1, 697) .. "..." end
    return notes ~= "" and notes or nil
end

local function parseRelease(body)
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil, "JSON support is unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or type(data.tag_name) ~= "string" then
        return nil, "invalid GitHub release response"
    end
    local version = data.tag_name:match("^v?(%d+%.%d+%.%d+)$")
    if not version then return nil, "invalid release version" end
    return {
        version = version,
        notes = cleanNotes(data.body),
    }
end

local function fetchLatestRelease()
    local body, err = httpGet(API_URL, "application/vnd.github+json")
    if not body then return nil, err end
    return parseRelease(body)
end

local function temporaryDir()
    local base
    local ok, datastorage = pcall(require, "datastorage")
    if ok and datastorage then base = datastorage:getSettingsDir() end
    base = base or "/tmp"
    return base .. "/sdrbackup-update"
end

local function sha256File(path)
    local sha2 = require("ffi/sha2")
    local feed = sha2.sha256()
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    while true do
        local chunk = file:read(256 * 1024)
        if not chunk then break end
        feed(chunk)
    end
    file:close()
    return feed()
end

local function parseChecksums(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local checksums = {}
    for line in file:lines() do
        local hash, name = line:match("^([0-9a-fA-F]+)%s+[* ]?([^/]+)$")
        if hash and #hash == 64 and name then checksums[name] = hash:lower() end
    end
    file:close()
    for file_index, name in ipairs(UPDATE_FILES) do
        if not checksums[name] then return nil, "missing checksum for " .. name end
    end
    return checksums
end

local function atomicCopy(source, target)
    local input, input_err = io.open(source, "rb")
    if not input then return nil, input_err end
    local temporary = target .. ".sdrbackup-update"
    local output, output_err = io.open(temporary, "wb")
    if not output then input:close(); return nil, output_err end
    while true do
        local chunk = input:read(128 * 1024)
        if not chunk then break end
        local wrote, write_err = output:write(chunk)
        if not wrote then
            input:close(); output:close(); pcall(os.remove, temporary)
            return nil, write_err
        end
    end
    input:close()
    output:close()
    local renamed, rename_err = os.rename(temporary, target)
    if not renamed then pcall(os.remove, temporary); return nil, rename_err end
    return true
end

local function installUpdate(release)
    local temp_dir = temporaryDir()
    local progress = toast(string.format(_("Downloading SDR Backup %s..."), release.version), 180)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")

    local function doInstall()
        local lfs = require("libs/libkoreader-lfs")
        lfs.mkdir(temp_dir)
        local raw_base = string.format(
            "https://raw.githubusercontent.com/%s/%s/v%s/sdrbackup.koplugin/",
            GITHUB_OWNER,
            GITHUB_REPO,
            release.version
        )
        local checksum_path = temp_dir .. "/files.sha256"
        local ok, err = httpGetToFile(raw_base .. "files.sha256", checksum_path)
        if not ok then return { success = false, stage = "checksum download", err = err } end
        local checksums
        checksums, err = parseChecksums(checksum_path)
        if not checksums then return { success = false, stage = "checksum parsing", err = err } end

        for file_index, name in ipairs(UPDATE_FILES) do
            local path = temp_dir .. "/" .. name
            ok, err = httpGetToFile(raw_base .. name, path)
            if not ok then return { success = false, stage = "download " .. name, err = err } end
            local actual
            actual, err = sha256File(path)
            if not actual or actual:lower() ~= checksums[name] then
                return { success = false, stage = "verification " .. name, err = err or "SHA-256 mismatch" }
            end
        end

        for file_index, name in ipairs(UPDATE_FILES) do
            ok, err = atomicCopy(temp_dir .. "/" .. name, PLUGIN_DIR .. "/" .. name)
            if not ok then return { success = false, stage = "installation " .. name, err = err } end
        end
        local meta_ok, meta = pcall(dofile, PLUGIN_DIR .. "/_meta.lua")
        if not meta_ok or type(meta) ~= "table" or tostring(meta.version) ~= release.version then
            return { success = false, stage = "installation", err = "installed version mismatch" }
        end
        return { success = true }
    end

    local function handleResult(result)
        closeWidget(progress)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err = result and result.err or "unknown error"
            logger.err("[SDRBackup] OTA update failed:", stage, err)
            return toast(string.format(_("Update failed during %s: %s"), stage, tostring(err)), 9)
        end
        UIManager:show(ConfirmBox:new{
            text = string.format(_("SDR Backup %s is installed. Restart KOReader now?"), release.version),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end

    if ok_trapper and Trapper and Trapper.dismissableRunInSubprocess then
        Trapper:wrap(function()
            local completed, result = Trapper:dismissableRunInSubprocess(doInstall, progress)
            if completed and result then
                handleResult(result)
            elseif completed == false then
                closeWidget(progress)
                toast(_("Update cancelled."))
            end
        end)
    else
        UIManager:scheduleIn(0.2, function() handleResult(doInstall()) end)
    end
end

local function showRelease(release, current)
    if not versionGreaterThan(release.version, current) then
        return toast(string.format(_("SDR Backup is up to date (%s)."), current))
    end
    local text = string.format(_("SDR Backup %s is available. You have %s."), release.version, current)
    if release.notes then text = text .. "\n\n" .. _("What's new:") .. "\n" .. release.notes end
    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("Download, verify and install now?"),
        ok_text = _("Install update"),
        cancel_text = _("Cancel"),
        ok_callback = function() installUpdate(release) end,
    })
end

function Updater._checkNow()
    local current = currentVersion()
    local progress = toast(_("Checking GitHub for updates..."), 30)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    local function check()
        local release, err = fetchLatestRelease()
        return release or { error = err }
    end
    local function handleResult(result)
        closeWidget(progress)
        if not result or result.error then
            logger.err("[SDRBackup] OTA check failed:", result and result.error)
            return toast(_("Could not check for updates: ") .. tostring(result and result.error or "unknown error"), 8)
        end
        showRelease(result, current)
    end
    if ok_trapper and Trapper and Trapper.dismissableRunInSubprocess then
        Trapper:wrap(function()
            local completed, result = Trapper:dismissableRunInSubprocess(check, progress)
            if completed and result then handleResult(result)
            elseif completed == false then closeWidget(progress); toast(_("Update check cancelled.")) end
        end)
    else
        UIManager:scheduleIn(0.2, function() handleResult(check()) end)
    end
end

function Updater.checkForUpdates()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        return NetworkMgr:runWhenOnline(function() Updater._checkNow() end)
    end
    Updater._checkNow()
end

return Updater
