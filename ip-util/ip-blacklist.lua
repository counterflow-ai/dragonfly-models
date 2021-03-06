-- ----------------------------------------------
-- Copyright (c) 2018, CounterFlow AI, Inc.
-- author: Andrew Fast <af@counterflowai.com>
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE.txt file.
-- ----------------------------------------------


-- Mark events based on IP blacklists

require 'analyzer/utils'
require 'analyzer/ip-utils'

local analyzer_name = 'IP Blacklist'

function setup()
    conn = hiredis.connect()
    if conn:command('PING') ~= hiredis.status.PONG then
        dragonfly.log_event(analyzer_name..': Could not connect to redis')
        dragonfly.log_event(analyzer_name..': exiting')
        os.exit()
    end
    starttime = 0 --mle.epoch()
    redis_key = "ip_blacklist"
    local start = os.clock()

    -- Feodo Blocklist - https://feodotracker.abuse.ch/downloads/ipblocklist.txt
    -- Ransomware List - https://ransomwaretracker.abuse.ch/downloads/RW_IPBL.txt
    -- Zeus List - https://zeustracker.abuse.ch/blocklist.php?download=badips
    -- http_get (file_url, filename)

    files = { feodo = "analyzer/ipblocklist.txt", ransomware = "analyzer/RW_IPBL.txt" , zeus = "analyzer/zeus_badips.txt" }

    for name, filename in pairs(files) do
        local file, err = io.open(filename, 'rb')
        if file then
            while true do
                line = file:read()
                if line == nil then
                    break
                elseif line ~='' and not line:find("^#") then
                    local cmd = 'SET '..redis_key..':'..line..' '..name
                    local reply = conn:command_line(cmd)
                    if type(reply) == 'table' and reply.name ~= 'OK' then
                        dragonfly.log_event(cmd..' : '..reply.name)
                    end 
                end
            end
            file:close()
        end
    end
    local now = os.clock()
    local delta = now - start
    print ('Loaded '..analyzer_name..' files in '..delta..' seconds')
    dragonfly.log_event('Loaded '..analyzer_name..' files in '..delta..' seconds')
end

function loop(msg)
    local start = os.clock()
    local eve = msg
	local fields = {"ip_info.internal_ips",
                    ["ip_info.internal_ip_code"] = {ip_internal_code.SRC,
                                                    ip_internal_code.DEST},
                    ["event_type"] = {"alert",'flow'},}
    if not check_fields(eve, fields) then
        dragonfly.log_event(analyzer_name..': Required fields missing')
        dragonfly.analyze_event(default_analyzer, msg)
        return
    end

    local internal_ips = eve.ip_info.internal_ips
    local internal_ip_code = eve.ip_info.internal_ip_code
    local external_ip = get_external_ip(eve.src_ip, eve.dest_ip, internal_ip_code)
    if external_ip == nil then
        dragonfly.analyze_event(default_analyzer, msg)
        return
    end

    analytics = eve.analytics
    if not analytics then
        analytics = {}
    end
    
    ip_rep = {}
    ip_rep["ip_rep"] = 'NONE'
    local cmd = 'GET ip_blacklist:' .. external_ip
    local reply = conn:command_line(cmd)
    if type(reply) == 'table' and reply.name ~= 'OK' then
        dragonfly.log_event(analyzer_name..': '..cmd..' : '..reply.name)
    else 
        ip_rep["ip_rep"] = reply
    end

    analytics["ip_rep"] = ip_rep
    eve["analytics"] = analytics
    dragonfly.analyze_event(default_analyzer, eve) 
    local now = os.clock()
    local delta = now - start
    dragonfly.log_event(analyzer_name..': time: '..delta)
end
