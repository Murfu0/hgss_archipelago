--[[
melonDS connector for Archipelago's generic BizHawk client.

This script makes melonDS speak the same TCP/JSON protocol as
`connector_bizhawk_generic.lua`, so Archipelago's existing `_bizhawk`
client can talk to melonDS without any client-side changes.

The script expects melonDS-lua's built-in Lua runtime and a matching LuaSocket.
If you want a private socket install, stage it in:
    ~/.melonds-ap-lua/socket.lua
    ~/.melonds-ap-lua/socket/core.so
or point `MELONDS_LUASOCKET_DIR` at a different folder.

Usage:
1. Load your patched ROM in melonDS.
2. Open the Lua script window and run this file.
3. Start the Archipelago client and connect as usual.
]]

local SCRIPT_VERSION = 1
local DEBUG = false

--------------------------------------------------------------------------
-- LuaSocket
--------------------------------------------------------------------------

local function luasocket_dir()
    local override = os.getenv("MELONDS_LUASOCKET_DIR")
    if override and #override > 0 then
        return override
    end
    local home = os.getenv("HOME") or ""
    return home .. "/.melonds-ap-lua"
end

do
    local dir = luasocket_dir()
    local runtime_version = _VERSION:match("%d+%.%d+")
    local versions = { runtime_version, "5.5", "5.4", "5.3", "5.2", "5.1" }
    local seen = {}
    local paths = {}
    local cpaths = {}
    for _, version in ipairs(versions) do
        if version and not seen[version] then
            seen[version] = true
            paths[#paths + 1] = dir .. "/share/lua/" .. version .. "/?.lua"
            paths[#paths + 1] = dir .. "/share/lua/" .. version .. "/?/init.lua"
            cpaths[#cpaths + 1] = dir .. "/lib/lua/" .. version .. "/?.so"
        end
    end
    paths[#paths + 1] = dir .. "/?.lua"
    paths[#paths + 1] = dir .. "/?/init.lua"
    cpaths[#cpaths + 1] = dir .. "/?.so"
    package.path = table.concat(paths, ";") .. ";" .. package.path
    package.cpath = table.concat(cpaths, ";") .. ";" .. package.cpath
end

local ok_socket, socket = xpcall(function()
    return require("socket")
end, debug.traceback)
if not ok_socket then
    print("ERROR: could not load LuaSocket (require(\"socket\") failed).")
    print(tostring(socket))
    print("")
    print("Install LuaSocket for the same Lua version melonDS-lua was built against, or stage it in " .. luasocket_dir() .. ".")
end

--------------------------------------------------------------------------
-- base64
--------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {}
for i = 1, #B64 do
    B64_LOOKUP[B64:sub(i, i)] = i - 1
end

local function base64_encode(arr)
    local out = {}
    local i = 1
    while i <= #arr do
        local b1 = arr[i]
        local b2 = arr[i + 1]
        local b3 = arr[i + 2]
        local n1 = math.floor(b1 / 4)
        local n2 = (b1 % 4) * 16 + math.floor((b2 or 0) / 16)
        local n3 = ((b2 or 0) % 16) * 4 + math.floor((b3 or 0) / 64)
        local n4 = (b3 or 0) % 64
        out[#out + 1] = B64:sub(n1 + 1, n1 + 1)
        out[#out + 1] = B64:sub(n2 + 1, n2 + 1)
        out[#out + 1] = (b2 == nil) and "=" or B64:sub(n3 + 1, n3 + 1)
        out[#out + 1] = (b3 == nil) and "=" or B64:sub(n4 + 1, n4 + 1)
        i = i + 3
    end
    return table.concat(out)
end

local function base64_decode(str)
    local out = {}
    local buffer = 0
    local bits = 0
    for c in str:gmatch(".") do
        if c == "=" then
            break
        end
        local v = B64_LOOKUP[c]
        if v ~= nil then
            buffer = buffer * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local divisor = 2 ^ bits
                out[#out + 1] = math.floor(buffer / divisor) % 256
                buffer = buffer % divisor
            end
        end
    end
    return out
end

--------------------------------------------------------------------------
-- Minimal JSON
--------------------------------------------------------------------------

local ESCAPE_MAP = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
    ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}

local function json_encode_string(s)
    local escaped = s:gsub('[%z\1-\31\\"]', function(c)
        return ESCAPE_MAP[c] or string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. escaped .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return n > 0
end

local json_encode
json_encode = function(v)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            return string.format("%d", v)
        end
        return tostring(v)
    elseif t == "string" then
        return json_encode_string(v)
    elseif t == "table" then
        local parts = {}
        if is_array(v) then
            for i = 1, #v do
                parts[i] = json_encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, val in pairs(v) do
            parts[#parts + 1] = json_encode_string(tostring(k)) .. ":" .. json_encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("cannot encode value of type " .. t)
end

local function json_decode(str)
    local pos = 1
    local parse_value

    local function skip_ws()
        local _, e = str:find("^[ \t\r\n]+", pos)
        if e then
            pos = e + 1
        end
    end

    local function parse_string()
        pos = pos + 1
        local buf = {}
        while true do
            local c = str:sub(pos, pos)
            if c == "" then
                error("unterminated string")
            end
            if c == '"' then
                pos = pos + 1
                break
            elseif c == "\\" then
                local e = str:sub(pos + 1, pos + 1)
                if e == "n" then buf[#buf + 1] = "\n"
                elseif e == "t" then buf[#buf + 1] = "\t"
                elseif e == "r" then buf[#buf + 1] = "\r"
                elseif e == "b" then buf[#buf + 1] = "\b"
                elseif e == "f" then buf[#buf + 1] = "\f"
                elseif e == "/" then buf[#buf + 1] = "/"
                elseif e == "\\" then buf[#buf + 1] = "\\"
                elseif e == '"' then buf[#buf + 1] = '"'
                elseif e == "u" then
                    local code = tonumber(str:sub(pos + 2, pos + 5), 16) or 0
                    if code < 0x80 then
                        buf[#buf + 1] = string.char(code)
                    elseif code < 0x800 then
                        buf[#buf + 1] = string.char(
                            0xC0 + math.floor(code / 0x40),
                            0x80 + (code % 0x40)
                        )
                    else
                        buf[#buf + 1] = string.char(
                            0xE0 + math.floor(code / 0x1000),
                            0x80 + (math.floor(code / 0x40) % 0x40),
                            0x80 + (code % 0x40)
                        )
                    end
                    pos = pos + 4
                else
                    buf[#buf + 1] = e
                end
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parse_number()
        local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        local numstr = str:sub(s, e)
        pos = e + 1
        return tonumber(numstr)
    end

    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            pos = pos + 1
            obj[key] = parse_value()
            skip_ws()
            local ch = str:sub(pos, pos)
            pos = pos + 1
            if ch == "}" then
                break
            end
            if ch ~= "," then
                error("expected ',' or '}' in object")
            end
        end
        return obj
    end

    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if str:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parse_value()
            skip_ws()
            local ch = str:sub(pos, pos)
            pos = pos + 1
            if ch == "]" then
                break
            end
            if ch ~= "," then
                error("expected ',' or ']' in array")
            end
        end
        return arr
    end

    parse_value = function()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif c == '"' then return parse_string()
        elseif c == "t" then pos = pos + 4 return true
        elseif c == "f" then pos = pos + 5 return false
        elseif c == "n" then pos = pos + 4 return nil
        else return parse_number() end
    end

    return parse_value()
end

--------------------------------------------------------------------------
-- Memory helpers
--------------------------------------------------------------------------

local function read_bytes(domain, address, size)
    local raw = memory.read_bytes_as_array(address, size, domain)
    local out = {}
    for i = 1, size do
        out[i] = raw[i] or 0
    end
    return out
end

local function write_bytes(domain, address, bytes)
    if domain == "ROM" then
        error("Cannot write to ROM domain")
    end
    memory.write_bytes_as_array(address, bytes, domain)
end

local function current_rom_hash()
    local hash = gameinfo.getromhash()
    if not hash or hash == "" then
        return "NULL"
    end
    return hash
end

--------------------------------------------------------------------------
-- Request handling
--------------------------------------------------------------------------

local rom_hash = current_rom_hash()
local message_queue = {}
local message_interval = 0
local message_timer = 0

local locked = false
local client_socket = nil

local function lock()
    locked = true
    if client_socket then
        client_socket:settimeout(0)
    end
end

local function unlock()
    locked = false
    if client_socket then
        client_socket:settimeout(0)
    end
end

local request_handlers = {
    ["PING"] = function()
        return { type = "PONG" }
    end,

    ["SYSTEM"] = function()
        return { type = "SYSTEM_RESPONSE", value = emu.getsystemid() }
    end,

    ["PREFERRED_CORES"] = function()
        return { type = "PREFERRED_CORES_RESPONSE", value = {} }
    end,

    ["HASH"] = function()
        return { type = "HASH_RESPONSE", value = rom_hash }
    end,

    ["MEMORY_SIZE"] = function(req)
        local ok, size = pcall(memory.getmemorydomainsize, req["domain"])
        if ok and size then
            return { type = "MEMORY_SIZE_RESPONSE", value = size }
        end
        return { type = "MEMORY_SIZE_RESPONSE", value = 0 }
    end,

    ["GUARD"] = function(req)
        local expected = base64_decode(req["expected_data"])
        local actual = read_bytes(req["domain"], req["address"], #expected)
        local validated = true
        for i = 1, #expected do
            if actual[i] ~= expected[i] then
                validated = false
                break
            end
        end
        return { type = "GUARD_RESPONSE", value = validated, address = req["address"] }
    end,

    ["LOCK"] = function()
        lock()
        return { type = "LOCKED" }
    end,

    ["UNLOCK"] = function()
        unlock()
        return { type = "UNLOCKED" }
    end,

    ["READ"] = function(req)
        local bytes = read_bytes(req["domain"], req["address"], req["size"])
        return { type = "READ_RESPONSE", value = base64_encode(bytes) }
    end,

    ["WRITE"] = function(req)
        write_bytes(req["domain"], req["address"], base64_decode(req["value"]))
        return { type = "WRITE_RESPONSE" }
    end,

    ["DISPLAY_MESSAGE"] = function(req)
        message_queue[#message_queue + 1] = req["message"]
        return { type = "DISPLAY_MESSAGE_RESPONSE" }
    end,

    ["SET_MESSAGE_INTERVAL"] = function(req)
        message_interval = req["value"] or 0
        return { type = "SET_MESSAGE_INTERVAL_RESPONSE" }
    end,
}

local function process_request(req)
    local handler = request_handlers[req["type"]]
    if handler then
        return handler(req)
    end
    return { type = "ERROR", err = "Unknown command: " .. tostring(req["type"]) }
end

--------------------------------------------------------------------------
-- Networking
--------------------------------------------------------------------------

local SOCKET_PORT_FIRST = 43055
local SOCKET_PORT_LAST = SOCKET_PORT_FIRST + 4
local MAX_LINES_PER_FRAME = 4

local STATE_NOT_CONNECTED = 0
local STATE_CONNECTED = 1

local server = nil
local current_state = STATE_NOT_CONNECTED
local recv_buffer = ""
local send_buffer = ""
local timeout_timer = 0
local prev_time = ok_socket and socket.gettime() or 0

local function initialize_server()
    if not ok_socket then
        return
    end

    local port = SOCKET_PORT_FIRST
    while port <= SOCKET_PORT_LAST do
        local srv, err = socket.bind("127.0.0.1", port)
        if srv then
            srv:settimeout(0)
            server = srv
            print("melonDS AP connector listening on 127.0.0.1:" .. port)
            return
        elseif err ~= "address already in use" and err ~= nil then
            if not tostring(err):find("in use") and not tostring(err):find("bind") then
                print("Socket error: " .. tostring(err))
                return
            end
        end
        port = port + 1
    end
    print("Too many instances of the connector already running. Exiting.")
end

local function flush_send_buffer()
    if not client_socket or #send_buffer == 0 then
        return true
    end

    while #send_buffer > 0 do
        local i, err, j = client_socket:send(send_buffer)
        if i then
            send_buffer = send_buffer:sub(i + 1)
        elseif err == "timeout" then
            if j and j > 0 then
                send_buffer = send_buffer:sub(j + 1)
            end
            return false, "timeout"
        else
            return false, err
        end
    end
    return true
end

local function queue_send(data)
    send_buffer = send_buffer .. data
    return flush_send_buffer()
end

local function receive_line()
    local chunk, err, partial = client_socket:receive("*l")
    if chunk then
        local line = recv_buffer .. chunk
        recv_buffer = ""
        return line, nil
    end
    if partial and #partial > 0 then
        recv_buffer = recv_buffer .. partial
    end
    return nil, err
end

local function send_receive()
    local message, err = receive_line()

    if err == "closed" then
        if current_state == STATE_CONNECTED then
            print("Connection to client closed")
        end
        current_state = STATE_NOT_CONNECTED
        return
    elseif err == "timeout" then
        unlock()
        return
    elseif err ~= nil then
        print(tostring(err))
        current_state = STATE_NOT_CONNECTED
        unlock()
        return
    end

    if message == nil then
        return
    end

    timeout_timer = 5

    if DEBUG then
        print("Received [" .. tostring(emu.framecount()) .. "]: " .. message)
    end

    if message == "VERSION" then
        queue_send(tostring(SCRIPT_VERSION) .. "\n")
        return
    end

    local res = {}
    local data = json_decode(message)
    local failed_guard = nil
    for i, req in ipairs(data) do
        if failed_guard ~= nil then
            res[i] = failed_guard
        else
            local status, response = pcall(process_request, req)
            if status then
                res[i] = response
                if response["type"] == "GUARD_RESPONSE" and not response["value"] then
                    failed_guard = response
                end
            else
                if type(response) ~= "string" then
                    response = "Unknown error"
                end
                res[i] = { type = "ERROR", err = response }
            end
        end
    end

    local ok, send_err = queue_send(json_encode(res) .. "\n")
    if not ok and send_err ~= "timeout" then
        print("Socket send error: " .. tostring(send_err))
        current_state = STATE_NOT_CONNECTED
        client_socket = nil
    end
end

--------------------------------------------------------------------------
-- Main tick
--------------------------------------------------------------------------

local function tick()
    if not ok_socket then
        return
    end

    if server == nil and current_state == STATE_NOT_CONNECTED then
        initialize_server()
        if server == nil then
            return
        end
    end

    local now = socket.gettime()
    local dt = now - prev_time
    prev_time = now
    timeout_timer = timeout_timer - dt
    message_timer = message_timer - dt

    if message_timer <= 0 and #message_queue > 0 then
        print(message_queue[1])
        table.remove(message_queue, 1)
        message_timer = message_interval
    end

    if current_state == STATE_NOT_CONNECTED then
        recv_buffer = ""
        if emu.framecount() % 30 == 0 and server ~= nil then
            local client = server:accept()
            if client then
                print("Client connected")
                current_state = STATE_CONNECTED
                client_socket = client
                client_socket:settimeout(0)
                send_buffer = ""
                timeout_timer = 5
            end
        end
    else
        local ok, send_err = flush_send_buffer()
        if not ok and send_err ~= "timeout" then
            print("Socket send error: " .. tostring(send_err))
            current_state = STATE_NOT_CONNECTED
            client_socket = nil
            return
        end
        if #send_buffer > 0 then
            return
        end

        local processed = 0
        repeat
            send_receive()
            processed = processed + 1
        until not locked or current_state == STATE_NOT_CONNECTED or processed >= MAX_LINES_PER_FRAME

        if timeout_timer <= 0 then
            print("Client timed out")
            current_state = STATE_NOT_CONNECTED
            client_socket = nil
        end
    end
end

--------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------

print("melonDS Archipelago connector v" .. SCRIPT_VERSION .. " started.")
if ok_socket then
    print("Waiting for the Archipelago client to connect...")
end

function _Update()
    local status, err = pcall(tick)
    if not status then
        print("Connector error: " .. tostring(err))
    end
end
