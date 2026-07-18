-- Route Tool LuCI Controller
-- by 数码罗记 · godsun.pro
module("luci.controller.route_tool", package.seeall)

function index()
    entry({"admin", "system", "route_tool"}, template("route_tool/index"), _("Route Tool"), 88)
    entry({"admin", "system", "route_tool", "api"}, call("api"), nil).leaf = true
    entry({"admin", "system", "route_tool", "backup"}, call("backup"), nil).leaf = true
    entry({"admin", "system", "route_tool", "write"}, call("write"), nil).leaf = true
    entry({"admin", "system", "route_tool", "sysupgrade"}, call("sysupgrade"), nil).leaf = true
    entry({"admin", "system", "route_tool", "update"}, call("update"), nil).leaf = true
    entry({"admin", "system", "route_tool", "health"}, call("health"), nil).leaf = true
    entry({"admin", "system", "route_tool", "alloc_storage"}, call("alloc_storage"), nil).leaf = true
    entry({"admin", "system", "route_tool", "write_status"}, call("write_status"), nil).leaf = true
end

local CURRENT_VERSION = "0.3.24-1"
local UPDATE_RELEASE_API_URL = "https://api.github.com/repos/rothdren-lion/luci-app-route-tool/releases/latest"

local function allowed_part(p)
    return p == "gpt" or p == "cdt" or p == "art" or p == "ART" or p == "appsbl" or p == "factory" or p == "mibib" or p == "bl2" or p == "BL2" or p == "fip" or p == "FIP" or p == "config" or p == "Config" or p == "u-boot" or p == "uboot"
end

local function shellquote(s)
    s = tostring(s or "")
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function storage_script(name)
    local fs = require "nixio.fs"
    local p1 = "/usr/bin/" .. name
    local p2 = "/usr/libexec/route-tool.d/" .. name
    -- Prefer bundled scripts to avoid stale /usr/bin storage-health leftovers.
    if fs.access(p2) then return p2 end
    return p1
end

local function run_storage(name, args, err)
    local sys = require "luci.sys"
    return sys.exec(storage_script(name) .. " " .. (args or "") .. " " .. (err or "2>&1"))
end

local function upload_tmp_path(prefix)
    local nixio = require "nixio"
    return "/tmp/" .. (prefix or "route-tool-upload") .. "-" .. tostring(os.time()) .. "-" .. tostring(nixio.getpid()) .. ".bin"
end

local function job_id(kind)
    local nixio = require "nixio"
    return "route-tool-" .. (kind or "job") .. "-" .. tostring(os.time()) .. "-" .. tostring(nixio.getpid())
end

local function safe_job_id(id)
    return type(id) == "string" and id:match("^route%-tool%-[%w%-]+%-%d+%-%d+$") ~= nil
end

local function job_tmp_path(id, suffix)
    if not safe_job_id(id) then return nil end
    return "/tmp/" .. id .. (suffix or "")
end

local function safe_tmp_path(path)
    -- Validate generated /tmp paths before shelling out; partition names are separately whitelisted.
    return type(path) == "string" and path:match("^/tmp/route%-tool%-[%w%-]+%-%d+%-%d+%.bin$") ~= nil
end

local function recv_upload(field, tmp)
    local ok = false
    luci.http.setfilehandler(function(meta, chunk, eof)
        if not meta or meta.name ~= field then return end
        if chunk and #chunk > 0 then
            local f = io.open(tmp, "ab")
            if f then
                f:write(chunk)
                f:close()
                ok = true
            end
        end
    end)
    luci.http.formvalue(field)
    if not ok then os.remove(tmp) end
    return ok
end

function api()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write(sys.exec("/usr/libexec/route-tool list 2>/dev/null"))
end

function backup()
    local part = luci.http.formvalue("part") or ""
    if not allowed_part(part) then
        luci.http.status(400, "Bad Request")
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write("不支持的分区")
        return
    end
    local filename = part .. ".bin"
    luci.http.header("Content-Disposition", "attachment; filename=" .. filename)
    luci.http.prepare_content("application/octet-stream")
    local fp = io.popen("/usr/libexec/route-tool backup " .. shellquote(part) .. " 2>/tmp/route-tool-last-error")
    if fp then
        while true do
            local chunk = fp:read(8192)
            if not chunk then break end
            luci.http.write(chunk)
        end
        fp:close()
    end
end


function write()
    local part = luci.http.formvalue("part") or ""
    if not allowed_part(part) then
        luci.http.status(400, "Bad Request")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ ok = false, message = "不支持的分区" })
        return
    end

    local tmp = upload_tmp_path("route-tool-upload")
    if not safe_tmp_path(tmp) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ ok = false, message = "上传临时路径不安全，已取消。" })
        return
    end
    local ok = recv_upload("image", tmp)

    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    if not ok then
        luci.http.write_json({ ok = false, message = "没有收到上传文件" })
        return
    end

    -- Write runs in background to avoid uhttpd CGI timeout (dd on large partitions can take minutes).
    -- Frontend polls /write_status for the result.
    local status_id = job_id("write")
    local status_file = job_tmp_path(status_id, ".txt")
    if not status_file then
        os.remove(tmp)
        luci.http.write_json({ ok = false, message = "写入任务状态路径不安全，已取消。" })
        return
    end
    os.remove(status_file)
    sys.exec(string.format(
        "( /usr/libexec/route-tool write %s %s YES >%s 2>&1; rc=$?; rm -f %s; echo \"RC=$rc\" >>%s ) &",
        shellquote(part), shellquote(tmp), shellquote(status_file), shellquote(tmp), shellquote(status_file)
    ))
    luci.http.write_json({ ok = true, message = "正在后台写入 " .. part .. "，请等待...", async = true, status_id = status_id })
end

function write_status()
    local fs = require "nixio.fs"
    luci.http.prepare_content("application/json")
    local status_id = luci.http.formvalue("id") or ""
    local status_file = ""
    if status_id == "" then
        -- Backward-compatible fallback for older frontends during an in-place upgrade.
        status_file = "/tmp/route-tool-write-status.txt"
    else
        status_file = job_tmp_path(status_id, ".txt")
        if not status_file then
            luci.http.write_json({ running = false, ok = false, message = "写入任务 ID 不合法。" })
            return
        end
    end
    local content = fs.readfile(status_file) or ""
    if content == "" then
        luci.http.write_json({ running = true, message = "正在写入，请稍候..." })
    else
        -- Check if write has finished (RC= line present)
        local rc = content:match("RC=(%d+)")
        if rc then
            os.remove(status_file)
            local ok = (tonumber(rc) == 0)
            -- Strip the RC= line from message
            local msg = content:gsub("RC=%d+\n?$", "")
            luci.http.write_json({
                running = false,
                ok = ok,
                message = msg ~= "" and msg or (ok and "写入完成" or "写入失败 (exit " .. rc .. ")")
            })
        else
            luci.http.write_json({ running = true, message = "正在写入，请稍候..." })
        end
    end
end

local function json_error(message)
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = false, message = message })
end

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function version_key(v)
    v = trim(v):gsub("^v", "")
    local main, rel = v:match("^(.-)%-(%d+)$")
    if not main then
        main = v
        rel = "0"
    end
    local parts = {}
    for n in main:gmatch("%d+") do
        parts[#parts + 1] = tonumber(n) or 0
    end
    return parts, tonumber(rel) or 0
end

local function version_compare(a, b)
    local ap, ar = version_key(a)
    local bp, br = version_key(b)
    local max = math.max(#ap, #bp)
    for i = 1, max do
        local x = ap[i] or 0
        local y = bp[i] or 0
        if x < y then return -1 end
        if x > y then return 1 end
    end
    if ar < br then return -1 end
    if ar > br then return 1 end
    return 0
end

local function update_fetch_cmd(url, out)
    return "(command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 12 --max-time 60 " .. shellquote(url) .. " -o " .. shellquote(out) .. ") || (command -v wget >/dev/null 2>&1 && wget -q -T 60 -O " .. shellquote(out) .. " " .. shellquote(url) .. ")"
end

local function fetch_latest_release()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local jsonc = require "luci.jsonc"
    local tmp = "/tmp/route-tool-release-meta.json"
    os.remove(tmp)
    local rc = sys.call(update_fetch_cmd(UPDATE_RELEASE_API_URL, tmp) .. " >/tmp/route-tool-release-check.log 2>&1")
    local raw = trim(fs.readfile(tmp) or "")
    os.remove(tmp)
    if rc ~= 0 or raw == "" then
        local msg = sys.exec("tail -n 8 /tmp/route-tool-release-check.log 2>/dev/null")
        return nil, "检查更新失败。" .. (msg ~= "" and ("\n" .. msg) or "")
    end
    local meta = jsonc.parse(raw)
    if type(meta) ~= "table" then
        return nil, "更新信息解析失败。"
    end
    local latest_tag = trim(meta.tag_name or "")
    local latest_version = latest_tag:gsub("^v", "")
    local ipk_url = ""
    local assets = meta.assets or {}
    if type(assets) == "table" then
        for _, asset in ipairs(assets) do
            local name = tostring(asset.name or "")
            local url = tostring(asset.browser_download_url or "")
            if url ~= "" and name:match("%.ipk$") then
                ipk_url = url
                local asset_version = name:match("^luci%-app%-route%-tool_(.+)_.+%.ipk$")
                if asset_version and asset_version ~= "" then
                    latest_version = asset_version
                end
                break
            end
        end
    end
    if ipk_url == "" then
        return nil, "最新 release 未找到 ipk 资产。"
    end
    if latest_version == "" then
        latest_version = latest_tag
    end
    return { tag = latest_tag, version = latest_version, ipk_url = ipk_url }, nil
end

function update()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local action = luci.http.formvalue("action") or "check"
    luci.http.prepare_content("application/json")

    if action == "check" then
        local release, err = fetch_latest_release()
        if not release then
            luci.http.write_json({ ok = false, current = CURRENT_VERSION, message = err or "检查更新失败。" })
            return
        end
        luci.http.write_json({
            ok = true,
            current = CURRENT_VERSION,
            latest = release.version,
            release_tag = release.tag,
            update_available = (version_compare(release.version, CURRENT_VERSION) > 0),
            ipk_url = release.ipk_url
        })
        return
    elseif action == "install" then
        local confirm = luci.http.formvalue("confirm") or ""
        if confirm ~= "YES" then
            luci.http.write_json({ ok = false, current = CURRENT_VERSION, message = "缺少确认参数，已取消在线更新。" })
            return
        end
        local release, err = fetch_latest_release()
        if not release then
            luci.http.write_json({ ok = false, current = CURRENT_VERSION, message = err or "下载更新包失败。" })
            return
        end
        if version_compare(release.version, CURRENT_VERSION) <= 0 then
            luci.http.write_json({ ok = false, current = CURRENT_VERSION, latest = release.version, message = "当前已是最新版本，无需在线更新。" })
            return
        end
        local tmp = "/tmp/luci-app-route-tool-ota.ipk"
        os.remove(tmp)
        local rc = sys.call(update_fetch_cmd(release.ipk_url, tmp) .. " >/tmp/route-tool-update-install.log 2>&1")
        if rc ~= 0 or not fs.access(tmp) then
            local msg = sys.exec("tail -n 8 /tmp/route-tool-update-install.log 2>/dev/null")
            luci.http.write_json({ ok = false, current = CURRENT_VERSION, message = "下载更新包失败。" .. (msg ~= "" and ("\n" .. msg) or "") })
            return
        end
        -- Try opkg first; if it fails with the known ar/ipk parser issue, attempt manual extraction.
        local install_log = "/tmp/route-tool-update-install-opkg.log"
        os.remove(install_log)
        local install_rc = sys.call("opkg install --force-reinstall " .. shellquote(tmp) .. " >" .. shellquote(install_log) .. " 2>&1")
        local out = fs.readfile(install_log) or ""
        if install_rc ~= 0 and out:match("Malformed package file") then
            local fallback_log = "/tmp/route-tool-update-install-fallback.log"
            os.remove(fallback_log)
            local fallback = "cd /tmp && " ..
                "rm -f debian-binary control.tar.gz data.tar.gz && " ..
                "(command -v ar >/dev/null 2>&1 && ar x " .. shellquote(tmp) .. " || tar -xzf " .. shellquote(tmp) .. " 2>/dev/null) && " ..
                "[ -s data.tar.gz ] && [ -s control.tar.gz ] && " ..
                "tar -xzf data.tar.gz -C / && " ..
                "mkdir -p /usr/lib/opkg/info && " ..
                "tar -xzf control.tar.gz -C /usr/lib/opkg/info/ && " ..
                "rm -f debian-binary control.tar.gz data.tar.gz && " ..
                "echo 'Manual install completed (ipk extraction fallback).'"
            install_rc = sys.call(fallback .. " >" .. shellquote(fallback_log) .. " 2>&1")
            out = fs.readfile(fallback_log) or ""
        end
        os.remove(tmp)
        if install_rc ~= 0 then
            luci.http.write_json({ ok = false, current = CURRENT_VERSION, message = "安装更新包失败。" .. (out ~= "" and ("\n" .. out) or "") })
            return
        end
        sys.call("rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/* /tmp/luci-* 2>/dev/null || true")
        sys.call("/etc/init.d/rpcd restart >/dev/null 2>&1 || true")
        sys.call("/etc/init.d/uhttpd restart >/dev/null 2>&1 || true")
        luci.http.write_json({ ok = true, current = CURRENT_VERSION, message = out ~= "" and out or "在线更新已完成，LuCI 已刷新。" })
        return
    end

    luci.http.write_json({ ok = false, current = CURRENT_VERSION, message = "未知更新动作。" })
end

function sysupgrade()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local upgrader = fs.access("/sbin/sysupgrade") and "/sbin/sysupgrade" or "sysupgrade"

    luci.http.prepare_content("application/json")

    if upgrader == "sysupgrade" and sys.call("command -v sysupgrade >/dev/null 2>&1") ~= 0 then
        luci.http.write_json({ ok = false, message = "系统未找到 sysupgrade 命令。" })
        return
    end

    local tmp = upload_tmp_path("route-tool-sysupgrade")
    if not safe_tmp_path(tmp) then
        luci.http.write_json({ ok = false, message = "上传临时路径不安全，已取消。" })
        return
    end
    local ok = recv_upload("image", tmp)
    local confirm = luci.http.formvalue("confirm", true) or ""
    local keep = luci.http.formvalue("keep", true) or "1"

    if confirm ~= "YES" then
        os.remove(tmp)
        luci.http.status(400, "Bad Request")
        luci.http.write_json({ ok = false, message = "缺少确认参数，已取消固件更新。" })
        return
    end

    if not ok then
        luci.http.write_json({ ok = false, message = "没有收到上传文件" })
        return
    end

    local test_cmd = upgrader .. " -T " .. shellquote(tmp) .. " >/tmp/route-tool-sysupgrade-test.log 2>&1"
    if sys.call(test_cmd) ~= 0 then
        local msg = sys.exec("tail -n 8 /tmp/route-tool-sysupgrade-test.log 2>/dev/null")
        os.remove(tmp)
        luci.http.write_json({ ok = false, message = "固件校验未通过，不是本机兼容 sysupgrade 固件。" .. (msg ~= "" and ("\n" .. msg) or "") })
        return
    end

    local opts = (keep == "1") and "" or " -n"
    -- '&' only reports launcher status, not sysupgrade's final result; return the launcher PID and log later failures.
    local cmd = "(sleep 1; " .. upgrader .. opts .. " " .. shellquote(tmp) .. " >/tmp/route-tool-sysupgrade.log 2>&1; echo $? >/tmp/route-tool-sysupgrade.rc) >/dev/null 2>&1 & echo $!"
    local pid = (sys.exec(cmd) or ""):match("(%d+)")
    if not pid then
        os.remove(tmp)
        luci.http.write_json({ ok = false, message = "启动 sysupgrade 失败，请检查 /tmp/route-tool-sysupgrade.log" })
        return
    end

    luci.http.write_json({
        ok = true,
        message = "sysupgrade 校验通过并已启动：将更新 OpenWrt 固件并自动重启。",
        keep_config = (keep == "1"),
        launcher_pid = pid
    })
end

function health()
    local sys = require "luci.sys"
    local action = luci.http.formvalue("action") or "overview"
    luci.http.prepare_content("text/plain; charset=utf-8")
    if action == "overview" then
        luci.http.write(run_storage("storage_system.sh", "", "2>/dev/null"))
        luci.http.write("\n")
        luci.http.write(run_storage("storage_capacity.sh", "", "2>/dev/null"))
        luci.http.write("\n")
        luci.http.write(run_storage("storage_health.sh", "", "2>/dev/null"))
        luci.http.write("\n")
        luci.http.write(run_storage("storage_nand.sh", "", "2>/dev/null"))
        luci.http.write("\n")
        luci.http.write(run_storage("storage_detail.sh", "", "2>/dev/null"))
        luci.http.write("\n")
        luci.http.write(run_storage("storage_memory.sh", "info", "2>/dev/null"))
    elseif action == "emmc" then
        luci.http.write(run_storage("storage_health.sh", "", "2>/dev/null"))
        luci.http.write("\n")
        luci.http.write(run_storage("storage_detail.sh", "", "2>/dev/null"))
    elseif action == "memory_info" then
        luci.http.write(run_storage("storage_memory.sh", "info", "2>/dev/null"))
    elseif action == "memory_quick" then
        -- Quick pressure: ~25% of available, capped 64-256MB, keeps /tmp reserve for LuCI/SSH.
        local qsize = luci.http.formvalue("size_mb") or ""
        local qargs = "quick"
        if qsize and tonumber(qsize) and tonumber(qsize) > 0 then
            qargs = "quick " .. tostring(math.floor(tonumber(qsize)))
        end
        luci.http.write(run_storage("storage_memory.sh", qargs, "2>&1"))
    elseif action == "memory_standard" then
        -- Standard pressure: ~60% of available, capped 128-1024MB, keeps /tmp reserve.
        local ssize = luci.http.formvalue("size_mb") or ""
        local sargs = "standard"
        if ssize and tonumber(ssize) and tonumber(ssize) > 0 then
            sargs = "standard " .. tostring(math.floor(tonumber(ssize)))
        end
        luci.http.write(run_storage("storage_memory.sh", sargs, "2>&1"))
    elseif action == "memory_capacity" then
        -- Capacity test: real memtester if available, else fallback to tmpfs pressure.
        -- Optional size_mb parameter for dropdown/manual override.
        local size_mb = luci.http.formvalue("size_mb") or ""
        local cap_args = "capacity"
        if size_mb and tonumber(size_mb) and tonumber(size_mb) > 0 then
            cap_args = "capacity " .. tostring(math.floor(tonumber(size_mb)))
        end
        luci.http.write(run_storage("storage_memory.sh", cap_args, "2>&1"))
    elseif action == "memory_full" then
        -- Full pressure: fill /tmp until ENOSPC (No space left on device = PASS).
        -- WARNING: this may briefly make LuCI/SSH unresponsive until cleanup runs.
        luci.http.write(run_storage("storage_memory.sh", "full", "2>&1"))
    elseif action == "soc" then
        luci.http.write(run_storage("storage_system.sh", "", "2>&1"))
    elseif action == "coremark" then
        luci.http.write(run_storage("storage_system.sh", "coremark", "2>&1"))
    elseif action == "ports" then
        luci.http.write(run_storage("storage_system.sh", "", "2>&1"))
    elseif action == "nand" then
        luci.http.write(run_storage("storage_nand.sh", "", "2>/dev/null"))
    elseif action == "capacity" then
        luci.http.write(run_storage("storage_capacity.sh", "", "2>/dev/null"))
    elseif action == "speed" then
        luci.http.write(run_storage("storage_speed.sh", "standard", "2>&1"))
    elseif action == "speed_cleanup" then
        luci.http.write(run_storage("storage_speed.sh", "cleanup", "2>&1"))
    elseif action == "bootlog" then
        luci.http.write(run_storage("storage_bootlog.sh", "summary 120", "2>&1"))
    elseif action == "smart" then
        luci.http.write(run_storage("storage_smart.sh", "quick", "2>&1"))
    elseif action == "analyze" then
        luci.http.write(run_storage("storage_analyze.sh", "", "2>&1"))
    else
        luci.http.write("ERROR=unknown action\nAVAILABLE=overview,capacity,ports,emmc,nand,speed,memory_quick,memory_standard,memory_full,bootlog,analyze\n")
    end
end

function alloc_storage()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local action = luci.http.formvalue("action") or "preview"
    luci.http.prepare_content("application/json")

    local confirm = ""
    if action == "create" then confirm = "YES" end

    local cmd = "/usr/libexec/route-tool alloc_storage " .. shellquote(confirm) .. " >/tmp/route-tool-alloc-out 2>&1"
    local rc = sys.call(cmd)
    local out = fs.readfile("/tmp/route-tool-alloc-out") or ""
    os.remove("/tmp/route-tool-alloc-out")

    luci.http.write_json({
        ok = (rc == 0),
        action = action,
        message = out ~= "" and out or (rc == 0 and "操作完成" or "操作失败 (exit " .. tostring(rc) .. ")")
    })
end
