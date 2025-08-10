-- 配置API处理
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

-- 设置响应头
ngx.header.content_type = "application/json"
ngx.header["Access-Control-Allow-Origin"] = "*"
ngx.header["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
ngx.header["Access-Control-Allow-Headers"] = "Content-Type"

-- 处理OPTIONS预检请求
if ngx.var.request_method == "OPTIONS" then
    ngx.status = 200
    ngx.say("")
    ngx.exit(200)
end

-- 获取当前配置
if ngx.var.request_method == "GET" then
    local api_key = get_config("mcsm_api_key", "")
    local configured = api_key ~= ""
    
    local response = {
        configured = configured,
        timestamp = ngx.time(),
        version = "2.0-openresty"
    }
    
    if configured then
        -- 获取统计信息
        local stats_dict = ngx.shared.mc_stats
        local nodes_dict = ngx.shared.mc_nodes
        
        local stats = {}
        if stats_dict and nodes_dict then
            local node_list_str = nodes_dict:get("node_list")
            if node_list_str then
                local node_list = safe_json_decode(node_list_str)
                if node_list then
                    for _, instance_id in ipairs(node_list) do
                        local stats_key = "stats:" .. instance_id
                        local node_stats_str = stats_dict:get(stats_key)
                        if node_stats_str then
                            local node_stats = safe_json_decode(node_stats_str)
                            if node_stats then
                                table.insert(stats, node_stats)
                            end
                        end
                    end
                end
            end
        end
        
        response.stats = stats
        response.total_nodes = #stats
        response.total_players = 0
        for _, stat in ipairs(stats) do
            response.total_players = response.total_players + (stat.total_players or 0)
        end
    end
    
    ngx.say(safe_json_encode(response))
    ngx.exit(200)
end

-- 保存配置
if ngx.var.request_method == "POST" then
    -- 读取请求体
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    
    if not body then
        ngx.status = 400
        ngx.say(safe_json_encode({
            success = false,
            message = "缺少请求体"
        }))
        ngx.exit(400)
    end
    
    local data = safe_json_decode(body)
    if not data then
        ngx.status = 400
        ngx.say(safe_json_encode({
            success = false,
            message = "无效的JSON格式"
        }))
        ngx.exit(400)
    end
    
    local api_key = data.api_key
    if not api_key or api_key == "" then
        ngx.status = 400
        ngx.say(safe_json_encode({
            success = false,
            message = "API Key不能为空"
        }))
        ngx.exit(400)
    end
    
    if string.len(api_key) < 32 then
        ngx.status = 400
        ngx.say(safe_json_encode({
            success = false,
            message = "API Key长度不正确"
        }))
        ngx.exit(400)
    end
    
    -- 测试API Key有效性
    local function test_api_key(key)
        local httpc = require "resty.http"
        local client = httpc.new()
        client:set_timeout(5000)
        
        local test_url = _G.MC_CONFIG.mcsm_api_base .. "/overview?apikey=" .. key
        
        local res, err = client:request_uri(test_url, {
            method = "GET",
            headers = {
                ["Content-Type"] = "application/json"
            }
        })
        
        if not res then
            return false, "网络请求失败: " .. (err or "unknown")
        end
        
        if res.status ~= 200 then
            return false, "API响应错误: " .. res.status
        end
        
        local response_data = safe_json_decode(res.body)
        if not response_data or response_data.status ~= 200 then
            return false, "API Key无效"
        end
        
        return true, "API Key验证成功"
    end
    
    -- 验证API Key
    local valid, msg = test_api_key(api_key)
    if not valid then
        ngx.status = 400
        ngx.say(safe_json_encode({
            success = false,
            message = msg
        }))
        ngx.exit(400)
    end
    
    -- 保存API Key
    local success = set_config("mcsm_api_key", api_key)
    if not success then
        ngx.status = 500
        ngx.say(safe_json_encode({
            success = false,
            message = "保存配置失败"
        }))
        ngx.exit(500)
    end
    
    -- 保存配置时间
    set_config("config_time", ngx.time())
    
    -- 触发节点扫描和自动注册
    ngx.timer.at(0, function()
        log_info("API Key已更新，触发节点扫描...")
        
        -- 在异步函数内部重新获取API Key
        local current_api_key = get_config("mcsm_api_key", "")
        if current_api_key == "" then
            log_error("异步任务中无法获取API Key")
            return
        end
        
        -- 重新加载节点信息
        local nodes = load_nodes_from_storage()
        save_nodes_to_dict(nodes)
        
        -- 自动注册节点到MCSM
        local function auto_register_nodes()
            local httpc = require "resty.http"
            local client = httpc.new()
            client:set_timeout(10000)
            
            for _, node in ipairs(nodes) do
                if node.daemon_key and node.private_ip then
                    -- 检查节点是否已存在
                    local list_url = _G.MC_CONFIG.mcsm_api_base .. "/overview?apikey=" .. current_api_key
                    local res = client:request_uri(list_url, { method = "GET" })
                    
                    if res and res.status == 200 then
                        local list_data = safe_json_decode(res.body)
                        if list_data and list_data.status == 200 then
                            local daemons = (list_data.data and list_data.data.remote) or {}
                            local exists = false
                            
                            local public_ip = get_public_ip()
                            for _, daemon in ipairs(daemons) do
                                -- 检查代理地址或直接IP地址
                                if daemon.ip == public_ip and string.find(daemon.remarks or "", node.instance_id, 1, true) then
                                    exists = true
                                    -- 更新daemon_uuid
                                    node.daemon_uuid = daemon.uuid
                                    log_info("找到已存在的守护进程(代理): " .. node.instance_id .. " UUID: " .. daemon.uuid)
                                    break
                                elseif daemon.ip == node.private_ip then
                                    exists = true
                                    -- 更新daemon_uuid
                                    node.daemon_uuid = daemon.uuid
                                    log_info("找到已存在的守护进程(直接): " .. node.instance_id .. " UUID: " .. daemon.uuid)
                                    break
                                end
                            end
                            
                            if not exists then
                                -- 计算代理端口（基于节点在列表中的索引）
                                local node_index = 1
                                for i, n in ipairs(nodes) do
                                    if n.instance_id == node.instance_id then
                                        node_index = i
                                        break
                                    end
                                end
                                local proxy_port = _G.MC_CONFIG.daemon_proxy_base + node_index - 1
                                
                                -- 创建新的守护进程连接（使用代理服务器公网IP）
                                local public_ip = get_public_ip()
                                local create_url = _G.MC_CONFIG.mcsm_api_base .. "/service/remote_service?apikey=" .. current_api_key
                                local create_data = {
                                    ip = public_ip,
                                    port = proxy_port,
                                    prefix = "",
                                    remarks = "MC服务器-" .. node.instance_id .. " (代理)",
                                    apiKey = node.daemon_key
                                }
                                
                                local create_res = client:request_uri(create_url, {
                                    method = "POST",
                                    headers = { ["Content-Type"] = "application/json" },
                                    body = safe_json_encode(create_data)
                                })
                                
                                if create_res and create_res.status == 200 then
                                    log_info("成功注册守护进程: " .. node.instance_id)
                                    
                                    -- 稍后获取UUID
                                    ngx.sleep(2)
                                    local updated_res = client:request_uri(list_url, { method = "GET" })
                                    if updated_res and updated_res.status == 200 then
                                        local updated_data = safe_json_decode(updated_res.body)
                                        if updated_data and updated_data.status == 200 then
                                            local updated_daemons = (updated_data.data and updated_data.data.remote) or {}
                                            for _, daemon in ipairs(updated_daemons) do
                                                if (daemon.ip == public_ip and string.find(daemon.remarks or "", node.instance_id, 1, true)) or daemon.ip == node.private_ip then
                                                    node.daemon_uuid = daemon.uuid
                                                    log_info("获取到守护进程UUID: " .. node.instance_id .. " UUID: " .. daemon.uuid)
                                                    break
                                                end
                                            end
                                        end
                                    end
                                else
                                    log_error("注册守护进程失败: " .. node.instance_id)
                                end
                            end
                        end
                    end
                end
            end
            
            -- 更新节点信息到共享字典
            save_nodes_to_dict(nodes)
        end
        
        auto_register_nodes()
    end)
    
    log_info("MCSM API Key已配置并验证成功")
    
    ngx.say(safe_json_encode({
        success = true,
        message = "配置保存成功，监控系统已启动",
        timestamp = ngx.time()
    }))
    ngx.exit(200)
end

-- 不支持的方法
ngx.status = 405
ngx.say(safe_json_encode({
    success = false,
    message = "不支持的HTTP方法"
}))
ngx.exit(405)