-- Worker进程初始化和定时任务
local cjson = require "cjson"

-- 只在第一个worker中运行定时任务
if ngx.worker.id() == 0 then
    log_info("启动主监控Worker...")
    
    -- 初始加载节点信息
    local function init_load_nodes()
        local nodes = load_nodes_from_storage()
        save_nodes_to_dict(nodes)
    end
    
    -- 监控MC服务器状态
    local function monitor_mc_servers()
        local dict = ngx.shared.mc_nodes
        if not dict then
            log_error("无法访问节点共享字典")
            return
        end
        
        local api_key = get_config("mcsm_api_key")
        if not api_key or api_key == "" then
            log_warn("MCSM API Key未配置，跳过监控")
            return
        end
        
        -- 获取节点列表
        local node_list_str = dict:get("node_list")
        if not node_list_str then
            log_warn("没有找到节点列表")
            return
        end
        
        local node_list = safe_json_decode(node_list_str)
        if not node_list then
            log_error("解析节点列表失败")
            return
        end
        
        log_info("开始监控 " .. #node_list .. " 个MC服务器")
        
        for _, instance_id in ipairs(node_list) do
            local node_key = "node:" .. instance_id
            local node_str = dict:get(node_key)
            
            if node_str then
                local node = safe_json_decode(node_str)
                if node and node.daemon_uuid then
                    -- 检查该节点的玩家数量
                    check_node_players(node, api_key)
                end
            end
        end
    end
    
    -- 检查单个节点的玩家数量
    function check_node_players(node, api_key)
        local httpc = require "resty.http"
        local client = httpc.new()
        client:set_timeout(_G.HTTP_TIMEOUT)
        
        -- 获取该daemon的所有实例
        local daemon_url = string.format("%s/service/remote_service_instances?uuid=%s&apikey=%s",
            _G.MC_CONFIG.mcsm_api_base, node.daemon_uuid, api_key)
        
        local res, err = client:request_uri(daemon_url, {
            method = "GET",
            headers = {
                ["Content-Type"] = "application/json"
            }
        })
        
        if not res then
            log_error("获取实例列表失败 " .. node.instance_id .. ": " .. (err or "unknown"))
            return
        end
        
        if res.status ~= 200 then
            log_error("API调用失败 " .. node.instance_id .. ": " .. res.status)
            return
        end
        
        local data = safe_json_decode(res.body)
        if not data or data.status ~= 200 then
            log_error("API响应错误 " .. node.instance_id)
            return
        end
        
        local instances = data.data or {}
        local total_players = 0
        local active_instances = 0
        
        -- 检查每个实例的玩家数量
        for _, instance in ipairs(instances) do
            if instance.instanceUuid then
                local players = get_instance_players(node.daemon_uuid, instance.instanceUuid, api_key)
                if players >= 0 then
                    total_players = total_players + players
                    active_instances = active_instances + 1
                end
            end
        end
        
        -- 更新统计信息
        local stats_dict = ngx.shared.mc_stats
        if stats_dict then
            local stats_key = "stats:" .. node.instance_id
            local stats = {
                instance_id = node.instance_id,
                total_players = total_players,
                active_instances = active_instances,
                last_check = ngx.time(),
                private_ip = node.private_ip
            }
            stats_dict:set(stats_key, safe_json_encode(stats), 300) -- 5分钟过期
        end
        
        -- 根据玩家数量决定是否需要关闭服务器
        if total_players == 0 then
            handle_idle_server(node)
        else
            -- 重置空闲计时
            local stats_dict = ngx.shared.mc_stats
            if stats_dict then
                stats_dict:delete("idle_start:" .. node.instance_id)
            end
        end
        
        log_info(string.format("节点 %s: %d 玩家, %d 活跃实例", 
            node.instance_id, total_players, active_instances))
    end
    
    -- 获取单个实例的玩家数量
    function get_instance_players(daemon_uuid, instance_uuid, api_key)
        local httpc = require "resty.http"
        local client = httpc.new()
        client:set_timeout(_G.HTTP_TIMEOUT)
        
        local query_url = string.format("%s/protected_instance/query?uuid=%s&remote_uuid=%s&apikey=%s",
            _G.MC_CONFIG.mcsm_api_base, daemon_uuid, instance_uuid, api_key)
        
        local res, err = client:request_uri(query_url, {
            method = "GET",
            headers = {
                ["Content-Type"] = "application/json"
            }
        })
        
        if not res or res.status ~= 200 then
            return -1
        end
        
        local data = safe_json_decode(res.body)
        if not data or data.status ~= 200 then
            return -1
        end
        
        -- 解析玩家数量（从状态信息中提取）
        local status_info = data.data and data.data.status or ""
        local players = string.match(status_info, "(%d+)/%d+") or "0"
        return tonumber(players) or 0
    end
    
    -- 处理空闲服务器
    function handle_idle_server(node)
        local stats_dict = ngx.shared.mc_stats
        if not stats_dict then
            return
        end
        
        local idle_key = "idle_start:" .. node.instance_id
        local idle_start = stats_dict:get(idle_key)
        local current_time = ngx.time()
        
        if not idle_start then
            -- 开始计时
            stats_dict:set(idle_key, current_time, 3600)
            log_info("服务器 " .. node.instance_id .. " 开始空闲计时")
            return
        end
        
        local idle_duration = current_time - idle_start
        if idle_duration >= _G.MC_CONFIG.idle_threshold then
            -- 空闲时间达到阈值，关闭服务器
            shutdown_ec2_instance(node.instance_id)
            stats_dict:delete(idle_key)
        else
            log_info(string.format("服务器 %s 空闲 %d 秒", node.instance_id, idle_duration))
        end
    end
    
    -- 关闭EC2实例
    function shutdown_ec2_instance(instance_id)
        -- TODO: 实现AWS EC2关闭逻辑
        log_info("准备关闭EC2实例: " .. instance_id)
        
        -- 这里可以调用AWS CLI或者使用HTTP API
        -- 目前先记录日志
        local stats_dict = ngx.shared.mc_stats
        if stats_dict then
            stats_dict:set("shutdown:" .. instance_id, ngx.time(), 3600)
        end
    end
    
    -- 设置定时器
    local function setup_timers()
        -- 立即加载节点信息
        ngx.timer.at(0, init_load_nodes)
        
        -- 定时监控（每30秒）
        local function monitor_timer()
            monitor_mc_servers()
            ngx.timer.at(_G.MC_CONFIG.check_interval, monitor_timer)
        end
        ngx.timer.at(_G.MC_CONFIG.check_interval, monitor_timer)
        
        -- 定时重新加载节点信息（每5分钟）
        local function reload_timer()
            init_load_nodes()
            ngx.timer.at(300, reload_timer)
        end
        ngx.timer.at(300, reload_timer)
    end
    
    setup_timers()
    log_info("MC监控定时任务已启动")
else
    log_info("Worker " .. ngx.worker.id() .. " 已启动")
end