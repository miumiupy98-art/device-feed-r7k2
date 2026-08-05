local Result = {}

function Result.annotation_pending(record)
    return type(record) == "table" and record.annotation_pending == true
end

function Result.annotation_fallback(record)
    return type(record) == "table" and record.annotation_fallback == true
end

function Result.variant_label(label, record)
    return tostring(label or "")
end

function Result.aggregate(records)
    local result={annotation_pending=false,annotation_fallback=false}
    for _,record in ipairs(records or {}) do
        if Result.annotation_pending(record) then result.annotation_pending=true end
        if Result.annotation_fallback(record) then result.annotation_fallback=true end
    end
    return result
end

function Result.state(record, pending_install)
    if pending_install == true then return "pending_install" end
    if Result.annotation_pending(record) then return "annotation_pending" end
    return "completed"
end

function Result.shelf_status(record, pending_install)
    if pending_install == true then return "等待关闭后更新" end
    if Result.annotation_pending(record) then return "批注待补全" end
    return "已生成"
end

function Result.notice(title, record, pending_install)
    title = tostring(title or "未命名")
    if pending_install == true then
        return title .. "新版本已下载，关闭当前书籍后更新"
    end
    if Result.annotation_pending(record) then
        return title .. "正文下载完成，划线与想法待补全"
    end
    return title .. "下载完成"
end

function Result.summary_note(record)
    if Result.annotation_pending(record) then
        return "正文已生成；划线与想法暂未完整，可稍后重新生成补全。"
    end
    return nil
end

return Result
