--[[
    NAME:
        xml-onverter.lua
    Description:
        A script which input .xml DanMu file and convert it to subtitles(without overlay).
        (English comments will be complemented when I remember my English XD.)
    Author:
        Muhz (work in 神楽Mea同好会)
    DATE:
        2020/11/04

    * 《简单使用说明》
    * 0. 脚本可用条件：
        * 使用前请先加载视频（空视频即可），防重叠算法需要获取视频的分辨率信息。
        * 将一行字幕（下文称为【启动行】）的 特效 改为 {下方start_effect字符串}，脚本则处于可使用状态。
    * 1. 先在启动行配置好样式，其中【字体大小】将决定最终位置的计算结果（注意：微软雅黑 字体在同等字体大小下显示大小要小于正常字体）。
    * 2. 在启动行中添加/pos代码（可通过拖放字幕生成），则将/pos标签中的坐标作为【弹幕区域的下边界】。
    * 4. 在启动行中，可以通过 &参数名=值& 的方式修改config表中的默认参数（一对&&中指定一个参数，不区分大小写，无视空格）。
        * 你可以指定的参数主要有：
            * duration - 弹幕持续的时间(单位ms)
            * interval - 弹幕的前后上下间距(单位px)
            * max_words - 弹幕内容的最大字符串长度
            * start_time - 只选取xml弹幕文件的片段，并指定片段开始的时间(格式hh:mm:ss.ms)
            * end_time - 只选取xml弹幕文件的片段，并指定片段结束的时间(格式hh:mm:ss.ms)
            * insert_time - 弹幕字幕在当前视频中的开始时间(格式hh:mm:ss.ms)
    * 5. 使用脚本后，会弹出文件选择对话框，选择需要转换的xml弹幕文件（请确保文件格式正确）。
    * 6. 待运行完成后，会自动为你添加弹幕行，添加的弹幕行的特效被命名为 {下方output_effect字符串} ，同时启动行会被自动标记为注释。
]]

local tr = aegisub.gettext

script_name = tr"xml弹幕转字幕"
script_description = tr"将xml格式的弹幕文件转为字幕(无重叠)。"
script_author = "muhz"
script_version = "1.0"

include("karaskel.lua")

local start_effect = "xmlconfig"  -- * 启动行的特效名
local output_effect = "danmu form xml"  -- * 输出的弹幕行的特效名(只用于标记，无作用)

-- * 配置变量
local config = {
    -- * 可指定参数
    duration = 10 * 1000,  -- 弹幕持续时间(单位ms)
    interval = 4,  -- 弹幕间间距(前后左右)
    max_words = nil, -- 弹幕内容的最大字符串长度
    start_time = 0, -- 截取片段的开始时间
    end_time = 0, -- 截取片段的结束时间
    insert_time = 0, -- 弹幕插入的时间

    -- 初始化参数部分(不推荐指定，指定后也不一定会生效)
    res_x = nil,  -- 视频的横向分辨率
    res_y = nil,  -- 视频的纵向分辨率
    bottom = nil,  -- 弹幕区域下底边界y坐标
    fontsize = nil,  -- 弹幕字体大小
}

-- * 工具方法部分
local function split(str, separator)
    --[[
        以指定分隔符separator分割字符串str
        (功能同python中的string.split()函数)
    ]]
    local slices = {}
    local i = 0
    local index = 0
    while i < #str do
        i = i + 1
        if string.find(str, separator, i) then
            index = string.find(str, separator, i)
            local slice = string.sub(str, i, index-1)
            table.insert(slices,slice)
            i = index
        else
            local slice = string.sub(str, i, #str)
            table.insert(slices,slice)
            break
        end
    end
    return slices
end

function bytime(d2, d1)
    -- 比较方法，返回true时交换位置
    return tonumber(d2.time) < tonumber(d1.time)
end


-- * 参数获取方法部分
function get_path()
    --[[
        获取xml文件的地址
    ]]
    -- API提供的文件获取方式
    local path = aegisub.dialog.open("选择xml文件", "", "", "xml Files(.xml)|*.xml|All Files(.)|*.*")
    if not path then
        -- 取消操作
        aegisub.cancel()
    end
    return path
end

function get_position_y(text)
    --[[
        从启动行文本的pos标签中获取y坐标，由于计算弹幕区域下底边坐标
    ]]
    local pos_tag = string.match(text, "\\pos([^)]+)")
    local y = nil
    if pos_tag then
        y = string.sub(pos_tag, string.find(pos_tag, ",")+1, -1)
    end
    return y
end

function get_config_from_text(text)
    --[[
        从启动行文本中获取配置参数：
            1. 通过pos标签获取弹幕区域下边界
            2. 通过 &参数=值& 的方式修改默认参数值（不区分大小写，无视空格，一对&&中只能指定一个参数）
    ]]
    if get_position_y(text) then
        config.bottom = math.floor(tonumber(get_position_y(text)) + 0.5)
    else
        config.bottom = math.floor(config.res_y*0.75 + 0.5)
    end
    for param in string.gmatch(text, "&[^&]+&") do
        local equal_pos = string.find(param, "=")
        local name = string.lower(string.gsub(string.sub(param, 2, equal_pos-1), " ", ""))
        local value = string.lower(string.gsub(string.sub(param, equal_pos+1, -2), " ", ""))
        for key, v in pairs(config) do
            if name == key then
                -- 将格式化时间转为ms
                if name == "start_time" or "end_time" or "inser_time" then
                    local list = split(value, ":")
                    local time = 0
                    for i=#list, 1, -1 do
                        time = time + tonumber(list[i])*60^(#list - i)
                    end
                    value = time*1000
                end
                config[key] = tonumber(value)
                break
            end
        end
    end
end


-- * xml解析方法部分
function get_xml_doc(path)
    --[[
        从以参数为地址的xml文件中获取document
    ]]
    local file = io.open(path, "r")
    local doc = file:read("*a")  -- "*a"参数指读取整个文件
    file:close()
    return doc
end

function get_elements_by_tag(doc, tag)
    --[[
        解析document并获得指定标签的元素集合
    ]]
    local element_list = {}
    local start_tag = "<" .. tag
    local end_tag = "</" .. tag .. ">"
    local i = 0
    while i < #doc do
        i = i + 1
        -- 标签匹配过程
        if string.find(doc, start_tag, i) then
            local start_index = string.find(doc, start_tag, i)
            if string.find(doc, end_tag, i) then
                local end_index = string.find(doc, end_tag, i) + #end_tag - 1
                local element = string.sub(doc, start_index, end_index)
                table.insert(element_list, element)
                i = end_index
            end
        end
    end
    return element_list
end

-- * data数据操作方法部分
function should_drop_data(data)
    --[[
        是否舍去data数据
    ]]
    if tonumber(data.time)*1000 < config.start_time then
        return true
    end
    if config.end_time ~= 0 and tonumber(data.time)*1000 > config.end_time then
        return true
    end
    if config.max_words ~= nil and #data.text > config.max_words then
        return true
    end
    -- todo 待补充...
    return false
end

function get_data_from_elements(element_list)
    --[[
        从元素集合中获取数据组集合，其属性包括xml弹幕文件中定义的全部属性
        注：一条xml弹幕格式为：
                <d p="{time}, {type}, {size}, {color}, {timestamp}, {pool}, {uid_crc32}, {row_id}">text</d>
            属性中的参数分别为：
                视频中的时间, 弹幕类型, 文字大小, 文字颜色, unix时间戳, 弹幕池, 用户id(crc32), 弹幕id
    ]]
    local data_list = {}
    for i, element in pairs(element_list) do
        local attributes = string.match(element, 'p="(.+)"')
        local text = string.match(element, ">(.+)</d>")
        local attribute_list = split(attributes, ",")
        local data = {
            -- 各字段含义见函数头部注释
            time = attribute_list[1],
            dtype = attribute_list[2],
            size = attribute_list[3],
            color = attribute_list[4],
            timestamp = attribute_list[5],
            pool = attribute_list[6],
            uid_crc32 = attribute_list[7],
            row_id = attribute_list[8],
            text = text
        }
        if not should_drop_data(data) then
            table.insert(data_list, data)
        end
    end
    return data_list
end


-- * 弹幕计算方法部分
function init_tracks()
    --[[
        初始化弹幕轨道，返回包含所有可用轨道的列表
    ]]
    -- 通过弹幕区域底边坐标确定轨道数
    local track_num = math.floor(config.bottom / (config.fontsize + config.interval*2))
    local track_list = {}
    for i = 1, track_num do
        local track = {index = i, rear = nil}
        table.insert(track_list, track)
    end
    return track_list
end

function is_track_empty(track)
    -- 轨道是否为空
    return track.rear == nil
end

function is_track_conflicted(track, danmu)
    --[[
        当前轨道是否冲突
        原理：
            轨道中上一条弹幕与当前弹幕的追击问题，
            若相遇时间小于弹幕持续时间（即会在视频区域显示），则判断为冲突
    ]]
    local v1 = (track.rear.length + config.res_x) / config.duration  -- 前一条弹幕
    local v2 = (danmu.length + config.res_x) / config.duration  -- 当前弹幕

    -- 若两条弹幕时间差大于弹幕持续时间，说明上条弹幕已在显示区域外，判定为不冲突
    local dt = danmu.time - track.rear.time
    if dt < config.duration then
        -- 若轨道中前一条弹幕还未完全进入画面（即已经相遇），冲突
        if v1 * dt < track.rear.length then
            return true
        else
            -- 条件1：若 v1 > v2 说明不会相遇。
            -- 条件2：根据公式推导可知，相遇时间 t0 = (dt*v1 - l1) / (v2 - v1)
            if v1 < v2 and (dt*v1-track.rear.length) / (v2-v1) < (config.duration-dt) then
                return true
            end
        end
    end
    return false
end

function push_danmu_into_track(track_list, danmu)
    --[[
        弹幕入轨道操作，从轨道列表中自上而下寻找与当前弹幕无冲突的轨道
    ]]
    for index, track in pairs(track_list) do
        if is_track_empty(track) or not is_track_conflicted(track, danmu) then
            track.rear = danmu  -- 更新轨道队尾弹幕
            danmu.track = track.index  -- 弹幕关联轨道序号
            break
        --else
        -- todo: 无可用轨道时的处理规则待补充...(思路：过滤短时间内同id同内容弹幕)
        end
    end
end


-- * 字幕line写入方法部分
function get_move_tag(danmu)
    --[[
        获取弹幕字符行的move标签
        形式： \move(x1, y1, x2, y2)
        含义： 开始位置坐标(x1,y1), 终点位置坐标(x2,y2)
    ]]
    local x1 = config.res_x
    local y1 = danmu.track * config.fontsize + config.interval  -- 通过轨道编号获取y坐标
    local x2 = - danmu.length  -- 终点位置在左侧画面外，为负数
    local y2 = y1
    local tag = "{\\move(" .. string.format("%d,%d,%d,%d", x1, y1, x2, y2) .. ")}"
    return tag
end

function get_line(danmu, line)
    --[[
        将弹幕数据转换为subtitles的line
        参数中的line为复制得到的模板，这样不需要定义完整的表单
    ]]
    local move_tag = get_move_tag(danmu)
    -- 关于line的字段，具体请查阅API手册
    line.comment = false
    line.effect = output_effect
    line.start_time = danmu.time + config.insert_time - config.start_time
    line.end_time = danmu.time + config.duration + config.insert_time - config.start_time
    line.text = move_tag .. danmu.text
    return line
end

function danmu_to_lines(data_list, line, subs)
    --[[
        将弹幕数据以line数据形式添加到subtitles对象中
        ?无法以 "返回line集合再循环添加" 的方式实现添加操作 `for line in line_list: subs.append(line)`
    ]]
    -- 按显示时间升序对数据表进行排序（投稿视频的弹幕文件中，弹幕顺序并非为显示时间顺序）
    table.sort(data_list, bytime)

    local track_list = init_tracks()
    for index, data in pairs(data_list) do
        local danmu = {
            time = math.floor(tonumber(data.time) * 1000),  -- data中的时间单位为s, line中的时间单位为ms
            text = data.text,
            length = #data.text * config.fontsize + config.interval*2,
            track = 0  -- 未/无法添加入轨道时为0
        }
        push_danmu_into_track(track_list, danmu)
        if danmu.track ~= 0 then
            local newline = get_line(danmu, line)
            subs.append(newline)
        end
        -- 使用API返回插入进度
        aegisub.progress.set(index / #data_list * 100)
    end
end


function convert(subs, sel)
    --[[
        ! 处理函数（主函数）
    ]]

    aegisub.progress.title("xml弹幕文件导入")

    local meta, styles = karaskel.collect_head(subs, true)
    local res_x, res_y, ar, artype = aegisub.video_size()
    config.res_x = res_x
    config.res_y = res_y

    aegisub.progress.task("xml文件读取中...")
    local path = get_path()
    local doc = get_xml_doc(path)
    local element_list = get_elements_by_tag(doc, "d")

    aegisub.progress.task("参数读取中...")
    local newline = nil
    local i = 0
    while i < #subs do
        i = i + 1
        local l = subs[i]
        if l.class == "dialogue" and l.effect == start_effect then
            newline = table.copy(subs[i])
            karaskel.preproc_line(subs, meta, styles, l)
            -- 获取相关参数
            config.fontsize = l.styleref.fontsize
            get_config_from_text(l.text)
            -- 将启动行设置为注释
            l.comment = true
            subs[i] = l
        end
    end

    aegisub.progress.task("字幕写入中...")
    local data_list = get_data_from_elements(element_list)
    danmu_to_lines(data_list, newline, subs)

    aegisub.set_undo_point("Undo Point")  -- 创建恢复点（API要求）
end


function can_convert(subs)
    --[[
        ! 验证函数，检验脚本是否可用
        ]]

    local res_x, res_y, ar, artype = aegisub.video_size()
    if res_x == nil then
        return false
    end

    local num_dia = 0
	for i = 1, #subs do
		local l = subs[i]
		if l.class == "dialogue" then
			num_dia = num_dia + 1
			-- test if the line is a template
			if (string.headtail(l.effect)):lower() == start_effect then
				return true
			end
			-- don't try forever, this has to be fast
			if num_dia > 50 then
				return false
			end
		end
	end
	return false
end


-- * 注册函数，具体说明请参照API手册
aegisub.register_macro(tr"xml弹幕转字幕", tr"将xml格式的弹幕文件转为字幕，且无重叠(可在脚本的开头注释中查看简单的使用说明)。", convert, can_convert)
