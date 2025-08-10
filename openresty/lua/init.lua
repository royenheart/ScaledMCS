-- MC监控系统初始化脚本
local cjson = require "cjson"

-- 全局配置
_G.MC_CONFIG = {
    shared_storage = "/mnt/mc-shared",
    nodes_dir = "/mnt/mc-shared/nodes",
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

-- 从共享存储目录扫描所有节点信息文件
_G.load_nodes_from_storage = function()
    local nodes = {}
    
    -- 使用系统命令扫描节点目录
    local handle = io.popen("find " .. _G.MC_CONFIG.nodes_dir .. " -name '*.json' -type f 2>/dev/null")
    if not handle then
        log_warn("无法扫描节点目录: " .. _G.MC_CONFIG.nodes_dir)
        return {}
    end
    
    local node_files = handle:read("*all")
    handle:close()
    
    if not node_files or node_files == "" then
        log_warn("节点目录中没有找到节点文件")
        return {}
    end
    
    -- 逐个读取节点文件
    for file_path in node_files:gmatch("[^\r\n]+") do
        local file = io.open(file_path, "r")
        if file then
            local content = file:read("*all")
            file:close()
            
            local node, err = safe_json_decode(content)
            if node and node.instance_id then
                table.insert(nodes, node)
                log_info("加载节点: " .. node.instance_id .. " from " .. file_path)
            else
                log_error("解析节点文件失败: " .. file_path .. " - " .. (err or "invalid format"))
            end
        else
            log_error("无法读取节点文件: " .. file_path)
        end
    end
    
    log_info("从共享存储加载了 " .. #nodes .. " 个节点")
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