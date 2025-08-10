-- 代理配置管理API
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

-- 设置响应头
ngx.header.content_type = "application/json"
ngx.header["Access-Control-Allow-Origin"] = "*"

-- 处理OPTIONS预检请求
if ngx.var.request_method == "OPTIONS" then
    ngx.status = 200
    ngx.say("")
    ngx.exit(200)
end

-- 获取当前代理配置
if ngx.var.request_method == "GET" then
    local nodes_dict = ngx.shared.mc_nodes
    if not nodes_dict then
        ngx.status = 500
        ngx.say(safe_json_encode({
            error = "无法访问节点共享字典"
        }))
        ngx.exit(500)
    end
    
    -- 获取节点列表
    local node_list_str = nodes_dict:get("node_list")
    local proxy_config = {}
    
    if node_list_str then
        local node_list = safe_json_decode(node_list_str)
        if node_list then
            -- 生成代理配置映射
            local base_port = 25565
            for i, instance_id in ipairs(node_list) do
                local node_key = "node:" .. instance_id
                local node_str = nodes_dict:get(node_key)
                
                if node_str then
                    local node = safe_json_decode(node_str)
                    if node then
                        table.insert(proxy_config, {
                            proxy_port = base_port + i - 1,
                            instance_id = instance_id,
                            server_name = node.server_name or instance_id,
                            private_ip = node.private_ip,
                            target_port = 25565,
                            status = "configured"
                        })
                    end
                end
            end
        end
    end
    
    local response = {
        proxy_config = proxy_config,
        total_proxies = #proxy_config,
        base_port = 25565,
        max_ports = 4,
        timestamp = ngx.time()
    }
    
    ngx.say(safe_json_encode(response))
    ngx.exit(200)
end

-- 动态更新代理配置（预留功能）
if ngx.var.request_method == "POST" then
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
    
    -- 这里可以实现动态配置更新逻辑
    -- 目前OpenResty的stream配置无法完全动态修改
    -- 但可以通过共享字典存储配置信息供代理脚本使用
    
    local config_dict = ngx.shared.mc_config
    if config_dict then
        local config_key = "proxy_rules"
        local success = config_dict:set(config_key, safe_json_encode(data), 0)
        
        if success then
            ngx.say(safe_json_encode({
                success = true,
                message = "代理配置已更新",
                note = "配置将在下次连接时生效"
            }))
        else
            ngx.status = 500
            ngx.say(safe_json_encode({
                success = false,
                message = "保存配置失败"
            }))
        end
    else
        ngx.status = 500
        ngx.say(safe_json_encode({
            success = false,
            message = "无法访问配置共享字典"
        }))
    end
    
    ngx.exit(ngx.status)
end

-- 不支持的方法
ngx.status = 405
ngx.say(safe_json_encode({
    success = false,
    message = "不支持的HTTP方法"
}))
ngx.exit(405)