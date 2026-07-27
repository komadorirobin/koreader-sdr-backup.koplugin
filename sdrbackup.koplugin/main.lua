local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local dump = require("dump")
local logger = require("logger")
local _ = require("gettext")
local Updater = require("sdrbackup_updater")

local lfs = require("libs/libkoreader-lfs")
local json = require("json")

local SDRBackup = WidgetContainer:new{
    name = "sdrbackup",
    is_doc_only = false,
}

local INTERNAL_ROOT = "/storage/emulated/0"
local KOREADER_DIR = INTERNAL_ROOT .. "/koreader"
local SETTINGS_FILE = KOREADER_DIR .. "/sdrbackup_settings.lua"
local ACTIVE_MANIFEST_FILE = KOREADER_DIR .. "/sdrbackup_active_manifest.json"
local PENDING_RESTORE_FILE = KOREADER_DIR .. "/sdrbackup_pending_restore.json"
local RESTORE_STAGE_DIR = KOREADER_DIR .. "/.sdrbackup-restore"
local PROGRESS_INTERVAL = 10
local VERSION = "1.1.2"

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function joinPath(left, right)
    if left:sub(-1) == "/" then return left .. right end
    return left .. "/" .. right
end

local function fileExists(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file"
end

local function directoryExists(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "directory"
end

local function mkdirp(path)
    if directoryExists(path) then return true end
    local current = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        current = current == "/" and "/" .. part or (current == "" and part or current .. "/" .. part)
        if not directoryExists(current) then
            local ok, err = lfs.mkdir(current)
            if not ok and not directoryExists(current) then return nil, err end
        end
    end
    return true
end

local function parentDir(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function safeRelative(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("\0", 1, true) then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return true
end

local function readAll(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local value = file:read("*a")
    file:close()
    return value
end

local function writeAll(path, value)
    local ok, err = mkdirp(parentDir(path))
    if not ok then return nil, err end
    local temporary = path .. ".tmp"
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, open_err end
    local wrote, write_err = file:write(value)
    file:close()
    if not wrote then
        os.remove(temporary)
        return nil, write_err
    end
    os.remove(path)
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, rename_err
    end
    return true
end

local function copyFile(source, target)
    local input, input_err = io.open(source, "rb")
    if not input then return nil, input_err end
    local ok, mkdir_err = mkdirp(parentDir(target))
    if not ok then input:close(); return nil, mkdir_err end
    local temporary = target .. ".sdrbackup-part"
    local output, output_err = io.open(temporary, "wb")
    if not output then input:close(); return nil, output_err end
    while true do
        local chunk = input:read(128 * 1024)
        if not chunk then break end
        local wrote, err = output:write(chunk)
        if not wrote then
            input:close(); output:close(); os.remove(temporary)
            return nil, err
        end
    end
    input:close()
    output:close()
    os.remove(target)
    local renamed, rename_err = os.rename(temporary, target)
    if not renamed then os.remove(temporary); return nil, rename_err end
    return true
end

local function encodeJson(value)
    local ok, result = pcall(json.encode, value)
    if ok and type(result) == "string" then return result end
    return nil, tostring(result)
end

local function decodeJson(value)
    local ok, result = pcall(json.decode, value)
    if ok and type(result) == "table" then return result end
    return nil, tostring(result)
end

local function urlEncode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function formatBytes(value)
    local size = tonumber(value) or 0
    local units = { "B", "KiB", "MiB", "GiB" }
    local index = 1
    while size >= 1024 and index < #units do size = size / 1024; index = index + 1 end
    if index == 1 then return string.format("%d %s", size, units[index]) end
    return string.format("%.1f %s", size, units[index])
end

function SDRBackup:loadSettings()
    local ok, settings = pcall(dofile, SETTINGS_FILE)
    if not ok or type(settings) ~= "table" then settings = {} end
    self.server_url = trim(settings.server_url)
    self.token = trim(settings.token)
    self.active_backup_id = trim(settings.active_backup_id)
end

function SDRBackup:saveSettings()
    local value = "return " .. dump({
        server_url = self.server_url,
        token = self.token,
        active_backup_id = self.active_backup_id,
    }) .. "\n"
    local ok, err = writeAll(SETTINGS_FILE, value)
    if not ok then logger.warn("[SDRBackup] Could not save settings:", err) end
end

function SDRBackup:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 })
end

function SDRBackup:setProgress(text)
    if Trapper:isWrapped() then
        Trapper:info(text)
        return
    end
    if self.progress_widget then UIManager:close(self.progress_widget) end
    self.progress_widget = InfoMessage:new{ text = text }
    UIManager:show(self.progress_widget)
    UIManager:forceRePaint()
end

function SDRBackup:closeProgress()
    if Trapper:isWrapped() then
        Trapper:clear()
        return
    end
    if self.progress_widget then
        UIManager:close(self.progress_widget)
        self.progress_widget = nil
    end
end

function SDRBackup:baseUrl()
    return trim(self.server_url):gsub("/+$", "")
end

function SDRBackup:httpRequest(method, path, source, length, sink, block_timeout, total_timeout)
    if self:baseUrl() == "" or self.token == "" then return nil, nil, _("Server address or token is missing") end
    local http = require("socket/http")
    local socketutil_ok, socketutil = pcall(require, "socketutil")
    if socketutil_ok then
        socketutil:set_timeout(
            block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
            total_timeout or socketutil.LARGE_TOTAL_TIMEOUT
        )
    end
    local chunks = {}
    local request = {
        url = self:baseUrl() .. path,
        method = method,
        headers = {
            ["X-SDRBackup-Token"] = self.token,
            ["Content-Length"] = tostring(length or 0),
            ["Content-Type"] = "application/octet-stream",
            ["User-Agent"] = "KOReader-SDRBackup/" .. VERSION,
        },
        source = source,
        sink = sink or require("ltn12").sink.table(chunks),
    }
    local ok, result, code, headers, status = pcall(http.request, request)
    if socketutil_ok then pcall(function() socketutil:reset_timeout() end) end
    if not ok then return nil, nil, tostring(result) end
    local body = sink and "" or table.concat(chunks)
    if not headers then return tonumber(code), body, tostring(status or result or code) end
    return tonumber(code), body, nil
end

function SDRBackup:jsonRequest(method, path, value, block_timeout, total_timeout)
    local body = ""
    if value ~= nil then
        local err
        body, err = encodeJson(value)
        if not body then return nil, nil, err end
    end
    local ltn12 = require("ltn12")
    local code, response, request_err = self:httpRequest(
        method,
        path,
        ltn12.source.string(body),
        #body,
        nil,
        block_timeout,
        total_timeout
    )
    if request_err then return nil, nil, request_err end
    local decoded = {}
    if response ~= "" then decoded = decodeJson(response) or {} end
    return code, decoded, nil
end

function SDRBackup:runSubprocess(task)
    if not Trapper:isWrapped() then return true, task() end
    return Trapper:dismissableRunInSubprocess(task, false)
end

function SDRBackup:runTask(task)
    Trapper:wrap(function()
        local ok, err = xpcall(task, debug.traceback)
        if not ok then
            Trapper:reset()
            logger.err("[SDRBackup] Task failed:", err)
            self:showMessage(_("SDR Backup stopped after an internal error:\n") .. tostring(err), 12)
        end
    end)
end

function SDRBackup:uploadFile(backup_id, entry)
    local file, err = io.open(entry.source_path, "rb")
    if not file then return nil, err end
    local closed = false
    local function source()
        local chunk = file:read(128 * 1024)
        if not chunk and not closed then file:close(); closed = true end
        return chunk
    end
    local path = "/api/v1/backups/" .. urlEncode(backup_id) .. "/file?path=" .. urlEncode(entry.backup_path)
    local code, response_body, request_err = self:httpRequest("PUT", path, source, entry.size)
    if not closed then file:close() end
    if request_err then return nil, request_err end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    return true
end

function SDRBackup:downloadFile(backup_id, backup_path, target)
    local ok, err = mkdirp(parentDir(target))
    if not ok then return nil, err end
    local temporary = target .. ".sdrbackup-part"
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, open_err end
    local ltn12 = require("ltn12")
    local path = "/api/v1/backups/" .. urlEncode(backup_id) .. "/file?path=" .. urlEncode(backup_path)
    local code, response_body, request_err = self:httpRequest("GET", path, nil, 0, ltn12.sink.file(file))
    if request_err or code ~= 200 then
        pcall(os.remove, temporary)
        return nil, request_err or ("HTTP " .. tostring(code))
    end
    os.remove(target)
    local renamed, rename_err = os.rename(temporary, target)
    if not renamed then os.remove(temporary); return nil, rename_err end
    return true
end

function SDRBackup:discoverRoots()
    local roots = {}
    if directoryExists(INTERNAL_ROOT) then
        roots[#roots + 1] = { id = "internal", kind = "internal", label = "Intern lagring", path = INTERNAL_ROOT }
    end
    if directoryExists("/storage") then
        for name in lfs.dir("/storage") do
            if name ~= "." and name ~= ".." and name ~= "emulated" and name ~= "self" then
                local path = "/storage/" .. name
                if directoryExists(path) then
                    roots[#roots + 1] = { id = "removable-" .. name, kind = "removable", label = name, path = path }
                end
            end
        end
    end
    table.sort(roots, function(a, b) return a.id < b.id end)
    return roots
end

function SDRBackup:addFile(manifest, root, absolute_path, relative_path, category)
    if not safeRelative(relative_path) then return end
    local attr = lfs.attributes(absolute_path)
    if not attr or attr.mode ~= "file" then return end
    manifest.files[#manifest.files + 1] = {
        root_id = root.id,
        relative_path = relative_path,
        original_absolute_path = absolute_path,
        backup_path = "roots/" .. root.id .. "/" .. relative_path,
        source_path = absolute_path,
        category = category,
        size = attr.size or 0,
        mtime = attr.modification or 0,
    }
end

function SDRBackup:walkFiles(directory, callback)
    local ok, iterator, state = pcall(lfs.dir, directory)
    if not ok or not iterator then return end
    for name in iterator, state do
        if name ~= "." and name ~= ".." then
            local path = joinPath(directory, name)
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                self:walkFiles(path, callback)
            elseif attr and attr.mode == "file" then
                callback(path, attr)
            end
        end
    end
end

function SDRBackup:scanSdrDirectories(manifest, root)
    local function visit(directory, relative)
        local ok, iterator, state = pcall(lfs.dir, directory)
        if not ok or not iterator then
            manifest.scan_warnings[#manifest.scan_warnings + 1] = directory .. ": " .. tostring(iterator)
            return
        end
        for name in iterator, state do
            if name ~= "." and name ~= ".." then
                local absolute = joinPath(directory, name)
                local child_relative = relative == "" and name or relative .. "/" .. name
                local attr = lfs.attributes(absolute)
                if attr and attr.mode == "directory" then
                    if name:sub(-4):lower() == ".sdr" then
                        manifest.sdr_directories[#manifest.sdr_directories + 1] = {
                            root_id = root.id,
                            relative_path = child_relative,
                            original_absolute_path = absolute,
                        }
                        self:walkFiles(absolute, function(file_path)
                            local file_relative = child_relative .. file_path:sub(#absolute + 1)
                            file_relative = file_relative:gsub("^/", "")
                            self:addFile(manifest, root, file_path, file_relative, "sdr")
                        end)
                    elseif child_relative ~= "Android/data" and child_relative ~= "Android/obb" then
                        visit(absolute, child_relative)
                    end
                end
            end
        end
    end
    visit(root.path, "")
end

function SDRBackup:scanGlobalState(manifest, internal_root)
    local settings_dir = KOREADER_DIR .. "/settings"
    if directoryExists(settings_dir) then
        self:walkFiles(settings_dir, function(path)
            local relative = path:sub(#INTERNAL_ROOT + 2)
            local name = path:match("([^/]+)$") or ""
            local lower = name:lower()
            local is_lua_setting = lower:match("%.lua$") or lower:match("%.lua%.old$")
            local is_state_database = lower:match("^statistics%.sqlite3")
                or lower:match("^vocabulary_builder%.sqlite3")
                or lower:match("^bookshelf_hardcover%.sqlite3")
            if is_lua_setting or is_state_database then
                self:addFile(manifest, internal_root, path, relative, "global")
            end
        end)
    end
    local ok, iterator, state = pcall(lfs.dir, KOREADER_DIR)
    if ok and iterator then
        for name in iterator, state do
            local path = joinPath(KOREADER_DIR, name)
            if fileExists(path) and (
                name == "settings.reader.lua"
                or name == "defaults.custom.lua"
                or name:lower():find("history", 1, true)
            ) then
                self:addFile(manifest, internal_root, path, "koreader/" .. name, "global")
            end
        end
    end
end

function SDRBackup:createManifest()
    local roots = self:discoverRoots()
    local manifest = {
        schema_version = 1,
        plugin_version = VERSION,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        roots = {},
        sdr_directories = {},
        files = {},
        scan_warnings = {},
    }
    local internal
    for root_index, root in ipairs(roots) do
        manifest.roots[#manifest.roots + 1] = {
            id = root.id, kind = root.kind, label = root.label, original_path = root.path,
        }
        if root.kind == "internal" then internal = root end
        self:scanSdrDirectories(manifest, root)
    end
    if internal then self:scanGlobalState(manifest, internal) end
    table.sort(manifest.files, function(a, b) return a.backup_path < b.backup_path end)
    table.sort(manifest.sdr_directories, function(a, b)
        return (a.root_id .. "/" .. a.relative_path) < (b.root_id .. "/" .. b.relative_path)
    end)
    return manifest
end

function SDRBackup:saveActiveManifest(manifest)
    local encoded, err = encodeJson(manifest)
    if not encoded then return nil, err end
    return writeAll(ACTIVE_MANIFEST_FILE, encoded)
end

function SDRBackup:loadActiveManifest()
    local value, err = readAll(ACTIVE_MANIFEST_FILE)
    if not value then return nil, err end
    return decodeJson(value)
end

function SDRBackup:performUpload(manifest, backup_id, uploaded)
    uploaded = uploaded or {}
    local total_bytes, sent_bytes, skipped = 0, 0, 0
    for entry_index, entry in ipairs(manifest.files) do total_bytes = total_bytes + (tonumber(entry.size) or 0) end
    for index, entry in ipairs(manifest.files) do
        if uploaded[entry.backup_path] == tonumber(entry.size) then
            skipped = skipped + 1
            sent_bytes = sent_bytes + (tonumber(entry.size) or 0)
        else
            local attr = lfs.attributes(entry.source_path)
            if not attr or attr.mode ~= "file" or attr.size ~= tonumber(entry.size) then
                return nil, string.format(_("Source file changed or disappeared: %s. Start a new backup."), entry.source_path)
            end
            if index == 1 or index % PROGRESS_INTERVAL == 0 then
                self:setProgress(string.format(_("Backing up %d/%d\n%s / %s"), index, #manifest.files, formatBytes(sent_bytes), formatBytes(total_bytes)))
            end
            local completed, ok, err = self:runSubprocess(function()
                return self:uploadFile(backup_id, entry)
            end)
            if not completed then return nil, _("Backup cancelled.") end
            if not ok then return nil, string.format("%s: %s", entry.relative_path, tostring(err)) end
            sent_bytes = sent_bytes + (tonumber(entry.size) or 0)
        end
    end
    self:setProgress(_("The computer is verifying the backup..."))
    local completed, code, result, err = self:runSubprocess(function()
        return self:jsonRequest("POST", "/api/v1/backups/" .. urlEncode(backup_id) .. "/complete", {})
    end)
    if not completed then return nil, _("Backup cancelled.") end
    if err then return nil, err end
    if code ~= 200 or result.state ~= "complete" then
        return nil, string.format(_("Verification failed: %d files are missing"), #(result.missing or {}))
    end
    self.active_backup_id = ""
    self:saveSettings()
    os.remove(ACTIVE_MANIFEST_FILE)
    return {
        files = #manifest.files,
        directories = #manifest.sdr_directories,
        bytes = result.total_bytes or total_bytes,
        skipped = skipped,
    }
end

function SDRBackup:startNewBackupNow()
    self:setProgress(_("Scanning all storage for .sdr folders..."))
    local completed, manifest = self:runSubprocess(function() return self:createManifest() end)
    if not completed then
        self:closeProgress()
        return self:showMessage(_("Backup cancelled."), 4)
    end
    if #manifest.scan_warnings > 0 then
        self:closeProgress()
        local shown = {}
        for index = 1, math.min(3, #manifest.scan_warnings) do shown[#shown + 1] = manifest.scan_warnings[index] end
        return self:showMessage(string.format(_("Backup was not started because %d folders could not be scanned:\n%s"), #manifest.scan_warnings, table.concat(shown, "\n")), 12)
    end
    if #manifest.files == 0 and #manifest.sdr_directories == 0 then
        self:closeProgress()
        return self:showMessage(_("No .sdr folders or KOReader history files were found."), 6)
    end
    local saved, save_err = self:saveActiveManifest(manifest)
    if not saved then self:closeProgress(); return self:showMessage(_("Could not save manifest: ") .. tostring(save_err), 7) end
    self:setProgress(string.format(_("Found %d .sdr folders and %d files. Contacting the computer..."), #manifest.sdr_directories, #manifest.files))
    completed, code, response, err = self:runSubprocess(function()
        return self:jsonRequest("POST", "/api/v1/backups", manifest)
    end)
    if not completed then
        self:closeProgress()
        return self:showMessage(_("Backup cancelled."), 4)
    end
    if err or code ~= 201 or not response.backup_id then
        self:closeProgress()
        return self:showMessage(_("Could not start backup: ") .. tostring(err or ("HTTP " .. tostring(code))), 8)
    end
    self.active_backup_id = response.backup_id
    self:saveSettings()
    local result, upload_err = self:performUpload(manifest, self.active_backup_id)
    self:closeProgress()
    if not result then return self:showMessage(_("Backup paused after an error. Use 'Resume interrupted backup'.\n") .. tostring(upload_err), 10) end
    self:showMessage(string.format(_("Backup complete.\n%d .sdr folders, %d files, %s."), result.directories, result.files, formatBytes(result.bytes)), 8)
end

function SDRBackup:startNewBackup()
    UIManager:show(ConfirmBox:new{
        text = _("Create a complete backup of all .sdr folders plus KOReader history, statistics and collections?\n\nKeep the receiver running on the computer."),
        ok_text = _("Back up"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            UIManager:scheduleIn(0.1, function()
                self:runTask(function() self:startNewBackupNow() end)
            end)
        end,
    })
end

function SDRBackup:resumeBackup()
    if self.active_backup_id == "" then return self:showMessage(_("There is no interrupted backup."), 4) end
    local manifest, manifest_err = self:loadActiveManifest()
    if not manifest then return self:showMessage(_("The local resume manifest is missing: ") .. tostring(manifest_err), 7) end
    self:setProgress(_("Checking what has already reached the computer..."))
    local completed, code, response, err = self:runSubprocess(function()
        return self:jsonRequest("GET", "/api/v1/backups/" .. urlEncode(self.active_backup_id) .. "/uploaded")
    end)
    if not completed then self:closeProgress(); return self:showMessage(_("Backup cancelled."), 4) end
    if err or code ~= 200 then self:closeProgress(); return self:showMessage(_("Could not resume: ") .. tostring(err or ("HTTP " .. tostring(code))), 7) end
    local uploaded = {}
    for entry_index, entry in ipairs(response.files or {}) do uploaded[entry.backup_path] = tonumber(entry.size) end
    local result, upload_err = self:performUpload(manifest, self.active_backup_id, uploaded)
    self:closeProgress()
    if not result then return self:showMessage(_("Backup remains paused.\n") .. tostring(upload_err), 10) end
    self:showMessage(string.format(_("Backup complete. %d already transferred files were skipped."), result.skipped), 8)
end

function SDRBackup:rootMap(manifest)
    local current = self:discoverRoots()
    local internal, removable = nil, {}
    for root_index, root in ipairs(current) do
        if root.kind == "internal" then internal = root.path else removable[#removable + 1] = root.path end
    end
    local mapping = {}
    for old_root_index, old_root in ipairs(manifest.roots or {}) do
        if old_root.kind == "internal" then
            mapping[old_root.id] = internal
        elseif #removable == 1 then
            mapping[old_root.id] = removable[1]
        else
            for root_index, root in ipairs(current) do
                if root.kind == "removable" and root.label == old_root.label then mapping[old_root.id] = root.path end
            end
        end
        if not mapping[old_root.id] then
            return nil, string.format(_("Could not map storage root '%s'. Insert the memory card; only one removable card may be connected during restore."), old_root.label or old_root.id)
        end
    end
    return mapping
end

function SDRBackup:restoreBackupNow(backup_id)
    self:setProgress(_("Downloading backup manifest..."))
    local code, manifest, err = self:jsonRequest("GET", "/api/v1/backups/" .. urlEncode(backup_id) .. "/manifest")
    if err or code ~= 200 then self:closeProgress(); return self:showMessage(_("Could not read backup: ") .. tostring(err or code), 8) end
    local mapping, map_err = self:rootMap(manifest)
    if not mapping then self:closeProgress(); return self:showMessage(map_err, 10) end

    for directory_index, directory in ipairs(manifest.sdr_directories or {}) do
        if safeRelative(directory.relative_path) then
            local ok, mkdir_err = mkdirp(joinPath(mapping[directory.root_id], directory.relative_path))
            if not ok then self:closeProgress(); return self:showMessage(_("Could not create folder: ") .. tostring(mkdir_err), 8) end
        end
    end

    local pending = { backup_id = backup_id, files = {} }
    for index, entry in ipairs(manifest.files or {}) do
        if not safeRelative(entry.relative_path) then
            self:closeProgress(); return self:showMessage(_("Unsafe path in manifest: ") .. tostring(entry.relative_path), 8)
        end
        if index == 1 or index % PROGRESS_INTERVAL == 0 then
            self:setProgress(string.format(_("Restoring %d/%d files"), index, #manifest.files))
        end
        local target = joinPath(mapping[entry.root_id], entry.relative_path)
        if entry.category == "global" then
            local stage = joinPath(RESTORE_STAGE_DIR, entry.backup_path)
            local downloaded, download_err = self:downloadFile(backup_id, entry.backup_path, stage)
            if not downloaded then self:closeProgress(); return self:showMessage(_("Restore stopped: ") .. tostring(download_err), 9) end
            pending.files[#pending.files + 1] = { source = stage, target = target }
        else
            local downloaded, download_err = self:downloadFile(backup_id, entry.backup_path, target)
            if not downloaded then self:closeProgress(); return self:showMessage(_("Restore stopped: ") .. tostring(download_err), 9) end
        end
    end

    self:closeProgress()
    if #pending.files > 0 then
        local encoded, encode_err = encodeJson(pending)
        local wrote, write_err = encoded and writeAll(PENDING_RESTORE_FILE, encoded)
        if not wrote then return self:showMessage(_(".sdr folders were restored, but global history could not be staged: ") .. tostring(write_err or encode_err), 10) end
        UIManager:show(ConfirmBox:new{
            text = _("All .sdr folders are restored to their recorded locations.\n\nKOReader must now close. Open it once: the plugin installs the staged history/statistics and closes automatically. Open KOReader a second time to use the restored data."),
            ok_text = _("Close KOReader"),
            cancel_text = _("Later"),
            ok_callback = function() os.exit() end,
        })
    else
        self:showMessage(_("Restore complete."), 6)
    end
end

function SDRBackup:confirmRestore(backup)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Restore backup %s?\n\n%d .sdr folders and %d files will be written to their original relative locations. Existing files with the same names will be replaced."), backup.backup_id, backup.sdr_directory_count or 0, backup.file_count or 0),
        ok_text = _("Restore"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            UIManager:scheduleIn(0.1, function() self:restoreBackupNow(backup.backup_id) end)
        end,
    })
end

function SDRBackup:getRestoreMenu()
    local code, response, err = self:jsonRequest("GET", "/api/v1/backups")
    if err or code ~= 200 then
        return { { text = _("Could not contact computer: ") .. tostring(err or code), enabled = false } }
    end
    local items = {}
    for backup_index, backup in ipairs(response.backups or {}) do
        local selected = backup
        items[#items + 1] = {
            text = string.format("%s  (%d SDR, %s)", backup.backup_id, backup.sdr_directory_count or 0, formatBytes(backup.total_bytes)),
            callback = function() self:confirmRestore(selected) end,
        }
    end
    if #items == 0 then items[1] = { text = _("No completed backups on the computer"), enabled = false } end
    return items
end

function SDRBackup:testConnection()
    self:setProgress(_("Testing connection..."))
    local completed, code, response, err = self:runSubprocess(function()
        return self:jsonRequest("GET", "/api/v1/ping", nil, 3, 5)
    end)
    self:closeProgress()
    if not completed then return self:showMessage(_("Connection test cancelled."), 4) end
    if code == 200 then self:showMessage(_("Connection works."), 4)
    else self:showMessage(_("Connection failed: ") .. tostring(err or ("HTTP " .. tostring(code))), 7) end
end

function SDRBackup:showTokenConfig()
    local dialog
    dialog = InputDialog:new{
        title = _("Backup token from the computer"),
        input = self.token,
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                self.token = trim(dialog:getInputText())
                self:saveSettings()
                UIManager:close(dialog)
                self:showMessage(_("Settings saved."), 3)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SDRBackup:showServerConfig()
    local dialog
    dialog = InputDialog:new{
        title = _("Computer server address"),
        input = self.server_url,
        input_hint = "http://192.168.1.10:54321",
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Next"), callback = function()
                self.server_url = trim(dialog:getInputText())
                UIManager:close(dialog)
                self:showTokenConfig()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SDRBackup:applyPendingRestore()
    if not fileExists(PENDING_RESTORE_FILE) then return end
    local raw, read_err = readAll(PENDING_RESTORE_FILE)
    local pending, decode_err = raw and decodeJson(raw)
    if not pending or type(pending.files) ~= "table" then
        logger.warn("[SDRBackup] Invalid pending restore:", read_err or decode_err)
        return
    end
    UIManager:scheduleIn(0.5, function()
        local errors = {}
        for entry_index, entry in ipairs(pending.files) do
            local ok, err = copyFile(entry.source, entry.target)
            if not ok then errors[#errors + 1] = tostring(entry.target) .. ": " .. tostring(err) end
        end
        if #errors > 0 then
            self:showMessage(_("Could not activate all staged history files:\n") .. table.concat(errors, "\n"), 12)
            return
        end
        os.remove(PENDING_RESTORE_FILE)
        self:showMessage(_("Restored history and statistics are now installed. KOReader closes once more; open it again."), 4)
        UIManager:scheduleIn(4, function() os.exit() end)
    end)
end

function SDRBackup:init()
    self:loadSettings()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    self:applyPendingRestore()
end

function SDRBackup:addToMainMenu(menu_items)
    local sub_items = {
        { text = _("Create complete backup"), callback = function() self:startNewBackup() end },
        {
            text = _("Resume interrupted backup"),
            enabled_func = function() return self.active_backup_id ~= "" and fileExists(ACTIVE_MANIFEST_FILE) end,
            callback = function() self:runTask(function() self:resumeBackup() end) end,
        },
        { text = _("Restore from backup"), sub_item_table_func = function() return self:getRestoreMenu() end },
        { text = _("Test connection"), callback = function()
            self:runTask(function() self:testConnection() end)
        end },
        { text = _("Check for plugin updates"), callback = function() Updater.checkForUpdates() end },
        { text = _("Configure computer"), callback = function() self:showServerConfig() end },
        {
            text_func = function()
                if self.server_url == "" then return _("Status: not configured") end
                return _("Status: ") .. self.server_url
            end,
            enabled = false,
        },
    }
    menu_items.sdr_backup = {
        text = _("SDR Backup"),
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

return SDRBackup
