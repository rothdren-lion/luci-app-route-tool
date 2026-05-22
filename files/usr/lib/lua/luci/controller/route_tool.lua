-- Route Tool LuCI Controller
-- by 数码罗记 · godsun.pro
module("luci.controller.route_tool", package.seeall)

function index()
    entry({"admin", "system", "route_tool"}, template("route_tool/index"), _("Route Tool"), 88)
    entry({"admin", "system", "route_tool", "api"}, call("api"), nil).leaf = true
    entry({"admin", "system", "route_tool", "backup"}, call("backup"), nil).leaf = true
    entry({"admin", "system", "route_tool", "write"}, call("write"), nil).leaf = true
    entry({"admin", "system", "route_tool", "sysupgrade"}, call("sysupgrade"), nil).leaf = true
    entry({"admin", "system", "route_tool", "health"}, call("health"), nil).leaf = true
end

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
    local cmd = "/usr/libexec/route-tool write " .. shellquote(part) .. " " .. shellquote(tmp) .. " YES 2>&1"
    local out = sys.exec(cmd)
    os.remove(tmp)
    luci.http.write_json({ ok = true, message = out })
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
    elseif action == "emmc" then
        luci.http.write(run_storage("storage_health.sh", "", "2>/dev/null"))
        luci.http.write("\n")
        luci.http.write(run_storage("storage_detail.sh", "", "2>/dev/null"))
    elseif action == "memory_info" then
        luci.http.write(run_storage("storage_memory.sh", "info", "2>/dev/null"))
    elseif action == "memory_quick" then
        -- Quick pressure: ~25% of available, capped 64-256MB, keeps /tmp reserve for LuCI/SSH.
        luci.http.write(run_storage("storage_memory.sh", "quick", "2>&1"))
    elseif action == "memory_standard" then
        -- Standard pressure: ~60% of available, capped 128-1024MB, keeps /tmp reserve.
        luci.http.write(run_storage("storage_memory.sh", "standard", "2>&1"))
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
