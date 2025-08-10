-- MC监控系统初始化脚本
local cjson = require "cjson"

-- 设置cjson将空表编码为数组而不是对象
cjson.encode_empty_table_as_object(false)

-- 全局配置
_G.MC_CONFIG = {
    shared_storage = "/mnt/mc-shared",
    db_host = "127.0.0.1",
    db_port = 5432,
    db_name = "mc_monitor",
    db_user = "mc_user",
    db_password = "mc_monitor_2024!",
    mcsm_api_base = "http://127.0.0.1:23333/api",
    aws_region = "us-east-1",
    check_interval = 30,        -- 检查间隔（秒）
    idle_threshold = 300,       -- 空闲阈值（秒）
    default_mc_port = 25565,
    proxy_port_base = 25565,    -- MC代理端口起始
    max_proxy_ports = 10        -- 最大代理端口数量
}

-- HTTP客户端配置
_G.HTTP_TIMEOUT = 5000  -- 5秒超时

-- 日志函数
_G.log_info = function(msg)
    ngx.log(ngx.INFO, "[MC-Monitor] " .. msg)
end

_G.log_error = function(msg)
    ngx.log(ngx.ERR, "[MC-Monitor] " .. msg)
end

_G.log_warn = function(msg)
    ngx.log(ngx.WARN, "[MC-Monitor] " .. msg)
end

-- 安全的JSON解码
_G.safe_json_decode = function(str)
    if not str or str == "" then
        return nil, "empty string"
    end
    
    local ok, result = pcall(cjson.decode, str)
    if not ok then
        return nil, result
    end
    return result
end

-- 安全的JSON编码
_G.safe_json_encode = function(data)
    if not data then
        return "{}"
    end
    
    local ok, result = pcall(cjson.encode, data)
    if not ok then
        return "{}"
    end
    return result
end

-- 测试数据库连接
_G.test_db_connection = function()
    -- TODO: Use postgres plugin (if it has), prevent directly psql exe using
    local cmd = string.format(
        "PGPASSWORD='%s' /usr/bin/psql -h %s -p %d -U %s -d %s -c '\\q' 2>&1",
        _G.MC_CONFIG.db_password,
        _G.MC_CONFIG.db_host,
        _G.MC_CONFIG.db_port,
        _G.MC_CONFIG.db_user,
        _G.MC_CONFIG.db_name
    )
    
    log_info("测试数据库连接: " .. cmd)
    
    local handle = io.popen(cmd)
    if not handle then
        log_error("无法执行数据库连接测试")
        return false
    end
    
    local result = handle:read("*all")
    local success, reason, exit_code = handle:close()
    
    log_info("连接测试结果 - success: " .. tostring(success) .. ", exit_code: " .. tostring(exit_code))
    log_info("连接测试输出: [" .. (result or "nil") .. "]")
    
    return success and exit_code == 0
end

-- 从PostgreSQL数据库读取所有节点信息
_G.load_nodes_from_storage = function()
    local nodes = {}
    
    -- 先测试数据库连接
    if not test_db_connection() then
        log_error("数据库连接失败")
        return {}
    end
    
    -- 检查表是否存在
    local check_table_cmd = string.format(
        "PGPASSWORD='%s' /usr/bin/psql -h %s -p %d -U %s -d %s -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_name='mc_nodes';\" 2>&1",
        _G.MC_CONFIG.db_password,
        _G.MC_CONFIG.db_host,
        _G.MC_CONFIG.db_port,
        _G.MC_CONFIG.db_user,
        _G.MC_CONFIG.db_name
    )
    
    local table_handle = io.popen(check_table_cmd)
    if table_handle then
        local table_result = table_handle:read("*all")
        table_handle:close()
        log_info("mc_nodes表检查结果: [" .. (table_result or "nil") .. "]")
    end
    
    -- 检查表中的记录数
    local count_cmd = string.format(
        "PGPASSWORD='%s' /usr/bin/psql -h %s -p %d -U %s -d %s -t -c \"SELECT COUNT(*) FROM mc_nodes;\" 2>&1",
        _G.MC_CONFIG.db_password,
        _G.MC_CONFIG.db_host,
        _G.MC_CONFIG.db_port,
        _G.MC_CONFIG.db_user,
        _G.MC_CONFIG.db_name
    )
    
    local count_handle = io.popen(count_cmd)
    if count_handle then
        local count_result = count_handle:read("*all")
        count_handle:close()
        log_info("mc_nodes表记录数: [" .. (count_result or "nil") .. "]")
    end
    
    -- 构建psql命令，使用CSV格式输出更稳定，同时捕获错误输出
    local cmd = string.format(
        "PGPASSWORD='%s' /usr/bin/psql -h %s -p %d -U %s -d %s -t -A -F',' -c \"SELECT instance_id, server_name, private_ip, daemon_port, daemon_key, availability_zone FROM mc_nodes ORDER BY created_at;\" 2>&1",
        _G.MC_CONFIG.db_password,
        _G.MC_CONFIG.db_host,
        _G.MC_CONFIG.db_port,
        _G.MC_CONFIG.db_user,
        _G.MC_CONFIG.db_name
    )
    
    log_info("执行数据库查询命令: " .. cmd)
    
    local handle = io.popen(cmd)
    if not handle then
        log_error("无法执行io.popen命令")
        return {}
    end
    
    local result = handle:read("*all")
    local success, reason, exit_code = handle:close()
    
    log_info("io.popen结果 - success: " .. tostring(success) .. ", reason: " .. tostring(reason) .. ", exit_code: " .. tostring(exit_code))
    log_info("数据库查询原始输出长度: " .. (result and #result or 0))
    log_info("数据库查询原始结果: [" .. (result or "nil") .. "]")
    
    -- 检查是否是错误输出
    if result and (result:match("psql:") or result:match("FATAL:") or result:match("ERROR:") or result:match("could not")) then
        log_error("PostgreSQL错误: " .. result)
        return {}
    end
    
    if not result or result == "" or result:match("^%s*$") then
        log_warn("数据库中没有找到节点记录")
        return {}
    end
    
    -- 解析CSV格式输出
    local line_count = 0
    for line in result:gmatch("[^\r\n]+") do
        line_count = line_count + 1
        line = line:match("^%s*(.-)%s*$")  -- 去除首尾空格
        
        if line and line ~= "" then
            log_info("处理行 " .. line_count .. ": [" .. line .. "]")
            
            local parts = {}
            for part in line:gmatch("([^,]+)") do
                -- 去除空格和引号
                part = part:match("^%s*(.-)%s*$")
                if part:sub(1,1) == '"' and part:sub(-1) == '"' then
                    part = part:sub(2, -2)
                end
                table.insert(parts, part)
            end
            
            log_info("解析到 " .. #parts .. " 个字段")
            
            if #parts >= 6 then
                local node = {
                    instance_id = parts[1],
                    server_name = parts[2],
                    private_ip = parts[3],
                    daemon_port = tonumber(parts[4]),
                    daemon_key = parts[5],
                    availability_zone = parts[6]
                }
                
                if node.instance_id and node.instance_id ~= "" then
                    table.insert(nodes, node)
                    log_info("成功加载节点: " .. node.instance_id .. " IP: " .. node.private_ip)
                else
                    log_warn("节点instance_id为空，跳过")
                end
            else
                log_warn("字段数不足6个，跳过此行")
            end
        end
    end
    
    log_info("从数据库加载了 " .. #nodes .. " 个节点")
    return nodes
end

-- 保存节点信息到共享字典
_G.save_nodes_to_dict = function(nodes)
    local dict = ngx.shared.mc_nodes
    if not dict then
        log_error("无法访问共享字典 mc_nodes")
        return false
    end
    
    -- 清空现有数据
    dict:flush_all()
    
    -- 保存节点数据
    for _, node in ipairs(nodes) do
        local key = "node:" .. node.instance_id
        local value = safe_json_encode(node)
        local ok, err = dict:set(key, value, 3600) -- 1小时过期
        if not ok then
            log_error("保存节点信息失败: " .. node.instance_id .. " - " .. (err or "unknown"))
        else
            log_info("保存节点: " .. node.instance_id .. " IP: " .. (node.private_ip or "unknown"))
        end
    end
    
    -- 保存节点列表
    local node_list = {}
    for _, node in ipairs(nodes) do
        table.insert(node_list, node.instance_id)
    end
    dict:set("node_list", safe_json_encode(node_list), 3600)
    
    log_info("成功保存 " .. #nodes .. " 个节点到共享字典")
    return true
end

-- 获取配置
_G.get_config = function(key, default)
    local dict = ngx.shared.mc_config
    if not dict then
        return default
    end
    
    local value = dict:get(key)
    return value or default
end

-- 设置配置
_G.set_config = function(key, value)
    local dict = ngx.shared.mc_config
    if not dict then
        return false
    end
    
    return dict:set(key, value, 0) -- 永不过期
end

log_info("MC监控系统初始化完成")