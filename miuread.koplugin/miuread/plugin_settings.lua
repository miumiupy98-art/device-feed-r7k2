local M={}

local function append(rows,items)
    for _,row in ipairs(items or {}) do rows[#rows+1]=row end
    return rows
end

function M.sync(plugin)
    return {
        {text="同步状态",callback=function() plugin:show_sync_status(false) end},
        {text="自动同步阅读进度",checked_func=function() return plugin.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() plugin:toggle_progress_sync() end},
        {text="自动同步阅读时间",checked_func=function() return plugin.store:preferences().sync.time_enabled==true end,keep_menu_open=true,callback=function() plugin:toggle_time_sync() end},
        {text="同步成功提醒",checked_func=function() return plugin:_sync_success_notice_enabled() end,keep_menu_open=true,callback=function() plugin:toggle_sync_success_notice() end},
        {text="立即上传当前进度",callback=function() plugin:upload_local_progress(true) end},
        {text="高级同步",sub_item_table_func=function()
            return {
                {text="修复当前书籍同步",callback=function() plugin:repair_current_sync() end},
                {text="重新读取云端进度",callback=function() plugin:manual_sync() end},
                {text="同步诊断",sub_item_table_func=function() return plugin:sync_diagnostics_menu() end},
            }
        end},
    }
end

function M.account_sync(plugin)
    local rows={
        {text="账号状态",post_text=plugin:_account_status_label(),callback=function() plugin:show_account_status() end},
        {text=plugin:logged_in() and "重新扫码登录" or "扫码登录",callback=function() plugin.auth_flow:start() end},
    }
    if plugin:logged_in() then rows[#rows+1]={text="退出登录",callback=function() plugin:confirm_logout() end} end
    append(rows,M.sync(plugin))
    return rows
end

function M.comment_data(plugin)
    return {
        {text="打开书籍时检查旧评论数据",checked_func=function()
            return (plugin.store:preferences().repair or {}).auto_check~=false
        end,keep_menu_open=true,callback=function()
            local p=plugin.store:preferences(); p.repair=p.repair or {}
            p.repair.auto_check=p.repair.auto_check==false
            plugin.store:save_preferences(p)
        end},
        {text="迁移当前书籍评论",callback=function() plugin:migrate_current_book_comments() end},
        {text="扫描所有待迁移书籍",callback=function() plugin:scan_downloaded_books_for_repair() end},
        {text="清理已验证的旧 JSON 备份",callback=function() plugin:clear_invalid_comment_indexes() end},
        {text="迁移记录",callback=function() plugin:show_repair_history() end},
        {text="重置迁移提示状态",callback=function()
            plugin.store:set("book_repair_state",{})
            plugin:toast("已重置评论迁移提示状态")
        end},
    }
end

function M.annotation_sync(plugin)
    if plugin:annotation_sync_diagnostic_only() then
        return {
            {text="批注坐标诊断（beta.11）",post_text="云端写入已暂停",enabled=false},
            {text="诊断方式",post_text="打开书籍后在阅读页“批注”中生成",enabled=false},
            {text="导出内容",post_text="raw.xhtml · coord.xhtml · range-debug.json",enabled=false},
        }
    end
    return {
        {
            text="微信读书批注同步（实验）",
            post_text=plugin:annotation_sync_enabled() and "已开启 · 手动" or "已关闭",
            checked_func=function() return plugin:annotation_sync_enabled() end,
            keep_menu_open=true,
            callback=function() plugin:toggle_annotation_sync() end,
        },
        {text="同步方式",post_text="手动 · 当前书籍在阅读页操作",enabled=false},
        {text="坐标保护",post_text="raw XHTML · 双向校验 · 官方锚点",enabled=false},
        {text="坐标诊断",post_text="打开书籍后在阅读页“批注”中导出",enabled=false},
        {text="新想法可见范围",post_text=plugin:annotation_sync_visibility_label(),sub_item_table_func=function() return plugin:annotation_sync_visibility_menu() end},
    }
end

function M.comments(plugin)
    local rows={}
    append(rows,plugin:thought_font_settings_menu())
    append(rows,M.annotation_sync(plugin))
    rows[#rows+1]={text="评论数据管理",sub_item_table_func=function() return M.comment_data(plugin) end}
    return rows
end

function M.notices(plugin)
    local labels={
        reader_download="阅读时下载提醒",low_battery="低电量下载提醒",low_storage="存储空间提醒",
        repair_while_reading="阅读中修复提醒",mode_switch="运行模式切换说明",mode_environment="进入模式说明",
    }
    local order={"reader_download","low_battery","low_storage","repair_while_reading","mode_switch","mode_environment"}
    local rows={}
    for _,key in ipairs(order) do
        local notice_key=key
        rows[#rows+1]={text=labels[notice_key],checked_func=function() return plugin:_notice_enabled(notice_key) end,keep_menu_open=true,callback=function()
            plugin:_set_notice_enabled(notice_key,not plugin:_notice_enabled(notice_key))
        end}
    end
    rows[#rows+1]={text="恢复全部使用提醒",callback=function()
        for _,key in ipairs(order) do plugin:_set_notice_enabled(key,true) end
        plugin:toast("使用提醒已恢复")
    end}
    return rows
end

function M.performance(plugin)
    local rows={}
    append(rows,plugin:performance_settings_menu())
    rows[#rows+1]={text="使用提醒",sub_item_table_func=function() return M.notices(plugin) end}
    return rows
end

function M.update_about(plugin)
    local rows={}
    append(rows,plugin:update_settings_menu())
    rows[#rows+1]={text="关于觅阅",callback=plugin:safe("about",function() plugin:show_about() end)}
    return rows
end

function M.menu(plugin)
    return {
        {text="账号与同步",post_text=plugin:progress_sync_label(),sub_item_table_func=function() return M.account_sync(plugin) end},
        {text="下载与存储",post_text=plugin:_download_settings_summary(),sub_item_table_func=function() return plugin:download_settings_menu() end},
        {text="评论与批注",post_text=plugin:_thought_display_label(),sub_item_table_func=function() return M.comments(plugin) end},
        {text="公众号阅读",sub_item_table_func=function() return plugin:mp_settings_menu() end},
        {text="性能与兼容性",post_text=plugin:_performance_mode_label(),sub_item_table_func=function() return M.performance(plugin) end},
        {text="更新与关于",sub_item_table_func=function() return M.update_about(plugin) end},
        {text="运行模式",post_text=plugin:_home_mode_label(),sub_item_table_func=function() return plugin:home_mode_menu() end},
    }
end

return M
