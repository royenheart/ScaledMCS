-- MC Stream代理Lua脚本
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

-- 获取当前监听端口
local server_port = ngx.var.server_port

-- 获取节点信息
local nodes_dict = ngx.shared.mc_nodes
if not nodes_dict then
    ngx.log(ngx.ERR, "无法访问节点共享字典")
    return
end

-- 获取节点列表
local node_list_str = nodes_dict:get("node_list")
if not node_list_str then
    ngx.log(ngx.WARN, "没有找到可用的MC节点")
    return
end

local node_list = safe_json_decode(node_list_str)
if not node_list then
    ngx.log(ngx.ERR, "解析节点列表失败")
    return
end

-- 端口映射逻辑
local port_map = {
    ["25565"] = 1,  -- 第1个节点
    ["25566"] = 2,  -- 第2个节点
    ["25567"] = 3,  -- 第3个节点
    ["25568"] = 4   -- 第4个节点
}

local node_index = port_map[tostring(server_port)]
if not node_index or node_index > #node_list then
    -- 如果没有对应的节点，使用第一个可用节点
    node_index = 1
    ngx.log(ngx.WARN, "端口 " .. server_port .. " 没有对应的节点，使用默认节点")
end

-- 获取目标节点信息
local target_instance_id = node_list[node_index]
if not target_instance_id then
    ngx.log(ngx.ERR, "没有找到目标节点")
    return
end

local node_key = "node:" .. target_instance_id
local node_str = nodes_dict:get(node_key)
if not node_str then
    ngx.log(ngx.ERR, "找不到节点信息: " .. target_instance_id)
    return
end

local node = safe_json_decode(node_str)
if not node or not node.private_ip then
    ngx.log(ngx.ERR, "节点信息无效: " .. target_instance_id)
    return
end

-- 检查目标节点是否在线
local stats_dict = ngx.shared.mc_stats
local is_server_online = true

if stats_dict then
    local shutdown_key = "shutdown:" .. target_instance_id
    local shutdown_time = stats_dict:get(shutdown_key)
    
    if shutdown_time then
        -- 服务器被标记为关闭，尝试启动它
        ngx.log(ngx.WARN, "检测到服务器 " .. target_instance_id .. " 已关闭，需要启动")
        is_server_online = false
        
        -- 这里可以触发服务器启动逻辑
        -- 目前先记录日志，实际启动逻辑可以通过定时器实现
        stats_dict:set("start_request:" .. target_instance_id, ngx.time(), 300)
    end
end

-- 设置后端服务器
local mc_port = 25565  -- MC默认端口
ngx.var.backend = node.private_ip .. ":" .. mc_port

ngx.log(ngx.INFO, string.format("MC代理: 端口%s -> %s (节点: %s, 在线: %s)", 
    server_port, ngx.var.backend, target_instance_id, is_server_online and "是" or "否"))