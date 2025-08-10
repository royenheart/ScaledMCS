-- 调试API - 用于检查系统状态
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

-- 设置响应头
ngx.header.content_type = "application/json"
ngx.header["Access-Control-Allow-Origin"] = "*"

-- 只支持GET请求
if ngx.var.request_method ~= "GET" then
    ngx.status = 405
    ngx.say(safe_json_encode({
        success = false,
        message = "仅支持GET请求"
    }))
    ngx.exit(405)
end

-- 获取调试信息
local debug_info = {
    -- 基本信息
    timestamp = ngx.time(),
    server_time = os.date("%Y-%m-%d %H:%M:%S"),
    
    -- 公网IP相关
    public_ip_status = {},
    
    -- 数据库连接状态
    database_status = {},
    
    -- 节点信息
    nodes_status = {},
    
    -- 配置信息
    config_status = {}
}

-- 测试公网IP获取
local function test_public_ip()
    local status = {
        cached_ip = _G.MC_CONFIG.public_ip,
        methods = {}
    }
    
    local httpc = require "resty.http"
    local client = httpc.new()
    client:set_timeout(3000)
    
    -- 测试AWS元数据
    local res, err = client:request_uri("http://169.254.169.254/latest/meta-data/public-ipv4", {
        method = "GET",
        headers = { ["User-Agent"] = "MC-Monitor/1.0" }
    })
    
    status.methods.aws_metadata = {
        success = res and res.status == 200,
        response = res and res.body or err,
        ip = res and res.body and string.match(res.body, "([%d%.]+)") or nil
    }
    
    -- 测试外部服务
    local res2, err2 = client:request_uri("http://checkip.amazonaws.com", {
        method = "GET",
        headers = { ["User-Agent"] = "MC-Monitor/1.0" }
    })
    
    status.methods.external_service = {
        success = res2 and res2.status == 200,
        response = res2 and res2.body or err2,
        ip = res2 and res2.body and string.match(res2.body, "([%d%.]+)") or nil
    }
    
    -- 测试文件读取
    local ip_file_handle = io.open("/etc/proxy_public_ip.txt", "r")
    if ip_file_handle then
        local saved_ip = ip_file_handle:read("*line")
        ip_file_handle:close()
        status.methods.file_cache = {
            success = true,
            response = saved_ip,
            ip = saved_ip and string.match(saved_ip, "([%d%.]+)") or nil
        }
    else
        status.methods.file_cache = {
            success = false,
            response = "文件不存在",
            ip = nil
        }
    end
    
    -- 当前获取结果
    status.current_result = get_public_ip()
    
    return status
end

-- 测试数据库连接
local function test_database()
    return {
        connection_test = test_db_connection(),
        config = {
            host = _G.MC_CONFIG.db_host,
            port = _G.MC_CONFIG.db_port,
            database = _G.MC_CONFIG.db_name,
            user = _G.MC_CONFIG.db_user
        }
    }
end

-- 获取节点状态
local function get_nodes_status()
    local nodes_dict = ngx.shared.mc_nodes
    if not nodes_dict then
        return { error = "无法访问节点共享字典" }
    end
    
    local node_list_str = nodes_dict:get("node_list")
    local status = {
        node_list_exists = node_list_str ~= nil,
        node_count = 0,
        nodes = {}
    }
    
    if node_list_str then
        local node_list = safe_json_decode(node_list_str)
        if node_list then
            status.node_count = #node_list
            for i, instance_id in ipairs(node_list) do
                local node_key = "node:" .. instance_id
                local node_str = nodes_dict:get(node_key)
                if node_str then
                    local node = safe_json_decode(node_str)
                    table.insert(status.nodes, {
                        instance_id = instance_id,
                        private_ip = node and node.private_ip or "N/A",
                        daemon_port = node and node.daemon_port or "N/A",
                        daemon_uuid = node and node.daemon_uuid or "N/A"
                    })
                end
            end
        end
    end
    
    return status
end

-- 获取配置状态
local function get_config_status()
    return {
        mcsm_api_key_configured = get_config("mcsm_api_key", "") ~= "",
        mcsm_api_base = _G.MC_CONFIG.mcsm_api_base,
        daemon_proxy_base = _G.MC_CONFIG.daemon_proxy_base,
        max_proxy_ports = _G.MC_CONFIG.max_proxy_ports
    }
end

-- 执行所有测试
debug_info.public_ip_status = test_public_ip()
debug_info.database_status = test_database()
debug_info.nodes_status = get_nodes_status()
debug_info.config_status = get_config_status()

ngx.say(safe_json_encode(debug_info))
ngx.exit(200)