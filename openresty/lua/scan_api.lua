-- 手动扫描节点API
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

-- 设置响应头
ngx.header.content_type = "application/json"
ngx.header["Access-Control-Allow-Origin"] = "*"

-- 只支持POST请求
if ngx.var.request_method ~= "POST" then
    ngx.status = 405
    ngx.say(safe_json_encode({
        success = false,
        message = "仅支持POST请求"
    }))
    ngx.exit(405)
end

-- 检查是否已配置API Key
local api_key = get_config("mcsm_api_key", "")
if api_key == "" then
    ngx.status = 400
    ngx.say(safe_json_encode({
        success = false,
        message = "请先配置MCSM API Key"
    }))
    ngx.exit(400)
end

-- 手动扫描节点
local function manual_scan()
    log_info("开始手动扫描节点...")
    
    -- 重新加载节点信息
    local nodes = load_nodes_from_storage()
    if not nodes or #nodes == 0 then
        return false, "没有找到节点信息文件或文件为空"
    end
    
    save_nodes_to_dict(nodes)
    
    -- 验证并注册节点
    local httpc = require "resty.http"
    local client = httpc.new()
    client:set_timeout(10000)
    
    local success_count = 0
    local error_count = 0
    local errors = {}
    
    -- 获取现有的守护进程列表
    local list_url = _G.MC_CONFIG.mcsm_api_base .. "/overview?apikey=" .. api_key
    local list_res, list_err = client:request_uri(list_url, {
        method = "GET",
        headers = {
            ["Content-Type"] = "application/json"
        }
    })
    
    if not list_res or list_res.status ~= 200 then
        return false, "无法获取现有守护进程列表: " .. (list_err or "API调用失败")
    end
    
    local list_data = safe_json_decode(list_res.body)
    if not list_data or list_data.status ~= 200 then
        return false, "API响应格式错误"
    end
    
    local existing_daemons = (list_data.data and list_data.data.remote) or {}
    
    -- 处理每个节点
    for _, node in ipairs(nodes) do
        if not node.daemon_key or not node.private_ip then
            error_count = error_count + 1
            table.insert(errors, "节点 " .. node.instance_id .. " 缺少必要信息")
            goto continue
        end
        
        -- 检查是否已存在
        local daemon_uuid = nil
        for _, daemon in ipairs(existing_daemons) do
            if daemon.ip == node.private_ip then
                daemon_uuid = daemon.uuid
                log_info("节点 " .. node.instance_id .. " 已存在，UUID: " .. daemon_uuid)
                break
            end
        end
        
        if not daemon_uuid then
            -- 创建新的守护进程连接
            local create_url = _G.MC_CONFIG.mcsm_api_base .. "/service/remote_service?apikey=" .. api_key
            local create_data = {
                ip = node.private_ip,
                port = node.daemon_port or 24444,
                prefix = "",
                remarks = "MC服务器-" .. node.instance_id,
                apiKey = node.daemon_key
            }
            
            local create_res, create_err = client:request_uri(create_url, {
                method = "POST",
                headers = {
                    ["Content-Type"] = "application/json"
                },
                body = safe_json_encode(create_data)
            })
            
            if not create_res or create_res.status ~= 200 then
                error_count = error_count + 1
                table.insert(errors, "注册节点 " .. node.instance_id .. " 失败: " .. (create_err or "API调用失败"))
                goto continue
            end
            
            local create_result = safe_json_decode(create_res.body)
            if not create_result or create_result.status ~= 200 then
                error_count = error_count + 1
                table.insert(errors, "注册节点 " .. node.instance_id .. " 失败: API响应错误")
                goto continue
            end
            
            log_info("成功注册新节点: " .. node.instance_id)
            
            -- 等待一下再获取UUID
            ngx.sleep(1)
            
            -- 重新获取守护进程列表以获取UUID
            local updated_res = client:request_uri(list_url, { method = "GET" })
            if updated_res and updated_res.status == 200 then
                local updated_data = safe_json_decode(updated_res.body)
                if updated_data and updated_data.status == 200 then
                    local updated_daemons = (updated_data.data and updated_data.data.remote) or {}
                    for _, daemon in ipairs(updated_daemons) do
                        if daemon.ip == node.private_ip then
                            daemon_uuid = daemon.uuid
                            break
                        end
                    end
                end
            end
        end
        
        if daemon_uuid then
            node.daemon_uuid = daemon_uuid
            success_count = success_count + 1
        else
            error_count = error_count + 1
            table.insert(errors, "无法获取节点 " .. node.instance_id .. " 的UUID")
        end
        
        ::continue::
    end
    
    -- 更新节点信息到共享字典
    save_nodes_to_dict(nodes)
    
    local result = {
        total_nodes = #nodes,
        success_count = success_count,
        error_count = error_count,
        errors = errors
    }
    
    if error_count > 0 then
        return false, "部分节点处理失败", result
    else
        return true, "所有节点处理成功", result
    end
end

-- 执行扫描
local success, message, details = manual_scan()

local response = {
    success = success,
    message = message,
    timestamp = ngx.time(),
    details = details or {}
}

if success then
    ngx.status = 200
    log_info("手动扫描完成: " .. message)
else
    ngx.status = 500
    log_error("手动扫描失败: " .. message)
end

ngx.say(safe_json_encode(response))
ngx.exit(ngx.status)