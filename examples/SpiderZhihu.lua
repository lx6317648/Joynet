package.path = "./?.lua;./src/?.lua;./libs/?.lua;"

local ZhihuConfig = require "examples.ZhihuConfig"
local TcpService = require "TcpService"
local HttpClient = require "HttpClient"

local picTypes = {"png", "jpg", "jpeg"}

local requestedPicNum = 0
local requestdPic = {}  --当前已经发出请求的图片集合
local totalPicNum = 0   --当前已经完成请求的图片数量

local zhihuAddres = GetIPOfHost("www.zhihu.com")
local picAddres = {}    --pic http 服务器ip地址集合,key 为域名
UtilsCreateDir(ZhihuConfig.saveDir)

local function singleCo(f)
    -- 不开启协程,因为经过测试发现，同时开多个链接到zhihu时，速度反而下降，通过访问百度进行对比，发现可能是zhihu服务器(故意)设置锁导致的
    if false then
        coroutine_start(function ()
            f()
        end)
    else
        f()
    end
end

-- 访问图片地址,下载成功则保存到文件
local function requestPic(clientService, pic_url, dirname, qoffset)
    local s,e = string.find(pic_url, "https:%/%/")
    local _,hostEnd = string.find(pic_url, "%.com")
    local host = string.sub(pic_url, e+1, hostEnd)
    local url = string.sub(pic_url, hostEnd+1, string.len(pic_url))

    print(os.date().." start request :"..pic_url)

    if picAddres[host] == nil then
        picAddres[host] = GetIPOfHost(host)
    end

    local response = HttpClient.Request(clientService, picAddres[host], 443, true, "GET", url,  host) 
    if response ~= nil then
        local f = io.open(ZhihuConfig.saveDir.."\\"..dirname.."\\"..qoffset.."\\"..string.sub(url, 2, string.len(url)), "w+b")
        f:write(response)
        f:flush()
        f:close()
        f=nil
        print(os.date().." recv pic :"..pic_url.." success")
        totalPicNum = totalPicNum + 1
    else
        print(os.date().." recv pic :"..pic_url.." failed")
    end
end

local function urlEnCode(w)
    local pattern="[^%w%d%._%-%* ]"  
    s=string.gsub(w,pattern,function(c)  
        local c=string.format("%%%02X",string.byte(c))  
        return c  
    end)  
    s=string.gsub(s," ","+")  
    return s  
end  

-- 访问问题页面
local function requestQuestion(clientService, question_url, dirname, qoffset)
    UtilsCreateDir(ZhihuConfig.saveDir.."\\"..dirname)
    UtilsCreateDir(ZhihuConfig.saveDir.."\\"..dirname.."\\"..qoffset)


    local fname = ZhihuConfig.saveDir.."\\"..dirname.."\\".."questions_address.txt"
    print(fname)
    local f = io.open(fname, "a+")
    f:write(question_url.."\r\n")
    f:flush()
    f:close()
    f=nil

    local response = HttpClient.Request(clientService, zhihuAddres, 443, true, "GET", question_url, "www.zhihu.com")
    if response ~= nil then
        --问题页面的response只包含最多10个回答的内容
        for _,picType in ipairs(picTypes) do
            local pos = 1

            while true do
                --TODO (优化匹配代码以及图片后缀)
                --查找此问题页面中的图片地址
                local s, e = string.find(response, "https:%/%/pic%d.zhimg.com%/%w*%_r%."..picType, pos)

                if s ~= nil then
                    local pic_url = string.sub(response, s, e)
                    if not requestdPic[pic_url] then
                        requestdPic[pic_url] = true
                        requestedPicNum = requestedPicNum + 1
                        singleCo(function ()
                                --访问图片
                                requestPic(clientService, pic_url, dirname, qoffset)
                            end)
                        end

                    pos = e
                else
                    break
                end
            end
        end

        --拉去此问题的后续所有回答
        local s,e = string.find(question_url, "question/")
        if s ~= nil then
            local question_id = string.sub(question_url, e+1)
            local offset = 10
            while true do
                local paramsUrlCode = urlEnCode("{\"url_token\":"..question_id..",\"pagesize\":10,\"offset\":"..offset.."}")

                local response = HttpClient.Request(clientService, zhihuAddres, 443, true, "POST", "/node/QuestionAnswerListV2", "www.zhihu.com", {method="next", params=paramsUrlCode},
                    {["Content-Type"]= "application/x-www-form-urlencoded; charset=UTF-8"})
                if response ~= nil then
                    if string.find(response, "Bad Request") ~= nil then
                        break
                    end

                    if string.len(response) <= 50 then
                        break
                    else
                        for _,picType in ipairs(picTypes) do
                            local pos = 1
                            while true do
                                --TODO (优化匹配代码以及图片后缀)
                                --查找此问题页面中的图片地址
                                --https:\/\/pic4.zhimg.com\/5c2b9c18ca49a03995a62975393e0c87_200x112.png

                                local s, e = string.find(response, "https:\\%/\\%/pic%d.zhimg.com\\%/%w*%_r%."..picType, pos)

                                if s ~= nil then
                                    local pic_url = string.sub(response, s, e)
                                    local _a , _b = string.find(pic_url, "pic")
                                    local _c, _d = string.find(pic_url, "com")

                                    pic_url = "https://"..string.sub(pic_url, _a, _d)..string.sub(pic_url, _d+2, string.len(pic_url))

                                    if not requestdPic[pic_url] then
                                        requestdPic[pic_url] = true
                                        requestedPicNum = requestedPicNum + 1
                                        singleCo(function ()
                                                --访问图片
                                                requestPic(clientService, pic_url, dirname, qoffset)
                                            end)
                                    end

                                    pos = e
                                else
                                    break
                                end
                            end
                        end
                    end
                else
                    break
                end

                offset = offset + 10
            end
        end
    end
end

local isAllCompleted = false

function userMain()
    local clientService = TcpService:New()
    clientService:createService()

    coroutine_start(function()
        -- 访问知乎搜索页面,搜索配置的关键字的相关问题
        for k,v in pairs(ZhihuConfig.querys) do
            for i=1,v.count do
                local response = HttpClient.Request(clientService, zhihuAddres, 80, false, "GET", "/search", "www.zhihu.com", {type="content",q=urlEnCode(v.q), offset=v.startOffset+10*(i-1)})
                local pos = 1
                if response ~= nil then
                    while true do
                        --查找问题页面地址
                        local s, e = string.find(response, "\"%/question%/%d*\"", pos)
                        if s ~= nil then
                            pos = e
                            local question_url = string.sub(response, s+1 , e-1)

                            print("request question_url :"..question_url)
                            singleCo(function ()
                                --访问问题页面
                                requestQuestion(clientService, question_url, v.dirname, v.startOffset+10*(i-1))
                            end)
                        else
                            print("no more question, will break")
                            break
                        end
                    end
                end
            end
        end

        isAllCompleted = true
    end)

    coroutine_start(function ()
        while true do
            coroutine_sleep(coroutine_running(), 1000)
            print("Current Completed Pic Num : "..totalPicNum)
            print("Current requested pic num: "..requestedPicNum)
            if isAllCompleted then
                print("all pic completed, you can close process")
                break
            end
        end
    end)
end

coroutine_start(function ()
    userMain()
end)

while true
do
    CoreDD:loop()
    while coroutine_pengdingnum() > 0
    do
        coroutine_schedule()
    end
end