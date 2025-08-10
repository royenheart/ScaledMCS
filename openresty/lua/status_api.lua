-- 状态API处理
local cjson = require "cjson"

-- 设置响应头
ngx.header.content_type = "application/json"
ngx.header["Access-Control-Allow-Origin"] = "*"

-- 只支持GET请求
if ngx.var.request_method ~= "GET" then
    ngx.status = 405
    ngx.say(safe_json_encode({
        error = "仅支持GET请求"
    }))
    ngx.exit(405)
end

-- 获取系统状态
local function get_system_status()
    local api_key = get_config("mcsm_api_key", "")
    local configured = api_key ~= ""
    local config_time = get_config("config_time", 0)
    
    local status = {
        configured = configured,
        config_time = config_time,
        current_time = ngx.time(),
        version = "2.0-openresty",
        worker_id = ngx.worker.id(),
        worker_count = ngx.worker.count()
    }
    
    if not configured then
        status.message = "API Key未配置"
        return status
    end
    
    -- 获取节点信息
    local nodes_dict = ngx.shared.mc_nodes
    local stats_dict = ngx.shared.mc_stats
    
    if not nodes_dict or not stats_dict then
        status.error = "无法访问共享存储"
        return status
    end
    
    -- 获取节点列表
    local node_list_str = nodes_dict:get("node_list")
    local nodes = {}
    
    -- 确保cjson将空表编码为数组而不是对象
    cjson.encode_empty_table_as_object(false)
    
    if node_list_str then
        local node_list = safe_json_decode(node_list_str)
        if node_list then
            for _, instance_id in ipairs(node_list) do
                local node_key = "node:" .. instance_id
                local node_str = nodes_dict:get(node_key)
                
                if node_str then
                    local node_data = safe_json_decode(node_str)
                    if node_data then
                        -- 获取节点统计信息
                        local stats_key = "stats:" .. instance_id
                        local stats_str = stats_dict:get(stats_key)
                        local stats_data = nil
                        
                        if stats_str then
                            stats_data = safe_json_decode(stats_str)
                        end
                        
                        -- 获取空闲状态
                        local idle_key = "idle_start:" .. instance_id
                        local idle_start = stats_dict:get(idle_key)
                        local idle_duration = 0
                        
                        if idle_start then
                            idle_duration = ngx.time() - idle_start
                        end
                        
                        -- 获取关闭状态
                        local shutdown_key = "shutdown:" .. instance_id
                        local shutdown_time = stats_dict:get(shutdown_key)
                        
                        local node_status = {
                            instance_id = node_data.instance_id,
                            private_ip = node_data.private_ip,
                            daemon_uuid = node_data.daemon_uuid,
                            has_daemon_key = not not node_data.daemon_key,
                            last_check = stats_data and stats_data.last_check or 0,
                            total_players = stats_data and stats_data.total_players or 0,
                            active_instances = stats_data and stats_data.active_instances or 0,
                            idle_duration = idle_duration,
                            is_idle = idle_start ~= nil,
                            shutdown_scheduled = shutdown_time ~= nil,
                            shutdown_time = shutdown_time or 0
                        }
                        
                        table.insert(nodes, node_status)
                    end
                end
            end
        end
    end
    
    -- 计算总计
    local total_players = 0
    local total_active_instances = 0
    local idle_nodes = 0
    local active_nodes = 0
    
    for _, node in ipairs(nodes) do
        total_players = total_players + node.total_players
        total_active_instances = total_active_instances + node.active_instances
        
        if node.is_idle then
            idle_nodes = idle_nodes + 1
        else
            active_nodes = active_nodes + 1
        end
    end
    
    status.summary = {
        total_nodes = #nodes,
        active_nodes = active_nodes,
        idle_nodes = idle_nodes,
        total_players = total_players,
        total_active_instances = total_active_instances
    }
    
    status.nodes = nodes
    status.message = "系统运行正常"
    
    return status
end

-- 获取详细状态
local function get_detailed_status()
    local status = get_system_status()
    
    -- 添加共享字典统计
    local mc_nodes = ngx.shared.mc_nodes
    local mc_config = ngx.shared.mc_config
    local mc_stats = ngx.shared.mc_stats
    
    status.shared_dict_stats = {
        mc_nodes = {
            capacity = mc_nodes and mc_nodes:capacity() or 0,
            free_space = mc_nodes and mc_nodes:free_space() or 0
        },
        mc_config = {
            capacity = mc_config and mc_config:capacity() or 0,
            free_space = mc_config and mc_config:free_space() or 0
        },
        mc_stats = {
            capacity = mc_stats and mc_stats:capacity() or 0,
            free_space = mc_stats and mc_stats:free_space() or 0
        }
    }
    
    -- 添加配置信息
    status.config = {
        shared_storage = _G.MC_CONFIG.shared_storage,
        node_info_file = _G.MC_CONFIG.node_info_file,
        check_interval = _G.MC_CONFIG.check_interval,
        idle_threshold = _G.MC_CONFIG.idle_threshold,
        aws_region = _G.MC_CONFIG.aws_region
    }
    
    return status
end

-- 处理查询参数
local args = ngx.req.get_uri_args()
local detailed = args.detailed == "true" or args.detail == "true"

local status
if detailed then
    status = get_detailed_status()
else
    status = get_system_status()
end

ngx.say(safe_json_encode(status))
ngx.exit(200)