local sub = string.sub
local function readData( data )
    function parseargs(s)
        local arg = {}
        string.gsub(s, "([%-%w]+)=([\"'])(.-)%2", function (w, _, a)
            arg[w] = a
        end)
        return arg
    end

    function collect(s)
        local stack = {}
        local top = {}
        table.insert(stack, top)
        local ni,c,label,xarg, empty
        local i, j = 1, 1
        while true do
            ni,j,c,label,xarg, empty = string.find(s, "<(%/?)([%w:]+)(.-)(%/?)>", i)
            if not ni then break end
            local text = string.sub(s, i, ni-1)
            if not string.find(text, "^%s*$") then
                --table.insert(top, text)
                top[ "content" ] = text
            end
            if empty == "/" then  -- empty element tag
                table.insert(top, {label=label, xarg=parseargs(xarg), empty=1})
            elseif c == "" then   -- start tag
                top = {label=label, xarg=parseargs(xarg)}
                table.insert(stack, top)   -- new level
            else  -- end tag
                local toclose = table.remove(stack)  -- remove top
                top = stack[#stack]
                if #stack < 1 then
                    error("nothing to close with "..label)
                end
                if toclose.label ~= label then
                    error("trying to close "..toclose.label.." with "..label)
                end
                --table.insert(top, toclose)
                if #stack > 1 then top.content = toclose; top.hasChildren = true else table.insert(top, toclose) end
            end
            i = j+1
        end
        local text = string.sub(s, i)
        if not string.find(text, "^%s*$") then
            table.insert(stack[#stack], text)
        end
        if #stack > 1 then
            error("unclosed "..stack[#stack].label)
        end
        return stack[1]
    end
    return collect( data )
end

local DCMLMatrix = {}
local Parser = {}

function Parser.registerTag( name, config )
    if type( name ) ~= "string" or type( config ) ~= "table" then return error("Expected string, table") end

    DCMLMatrix[ name ] = config
end

function Parser.removeTag( name )
    DCMLMatrix[ name ] = nil
end

function Parser.setMatrix( tbl )
    if type( tbl ) ~= "table" then
        return error("Expected table")
    end
end

function Parser.loadFile( path )
    if not fs.exists( path ) then
        return error("Cannot load DCML content from path '"..tostring( path ).."' because the file doesn't exist")
    elseif fs.isDir( path ) then
        return error("Cannot load DCML content from path '"..tostring( path ).."' because the path is a directory")
    end
    local h = fs.open( path, "r" )
    local data = h.readAll()
    h.close()

    return readData( data )
end

local function getFunction( instance, f )
    if type( f ) == "function" then
        return f
    elseif type( f ) == "string" and sub( f, 1, 1 ) == "#" then
        if not instance then
            return false
        else
            local fn = instance[ sub( f, 2 ) ]
            if type( fn ) == "function" then
                return fn
            end
        end
    end
end

local function convertToType( value, key, matrix )
    if type( matrix.argumentType ) ~= "table" then matrix.argumentType = {} end
    local toType = matrix.argumentType[ key ]
    local fromType = type( value )

    local rValue

    if fromType == toType or not toType then
        rValue = value
    else
        -- Convert
        if toType == "string" then
            rValue = tostring( value )
        elseif toType == "number" then
            local temp = tonumber( value )
            if not temp then
                return error("Failed to convert '"..tostring( value ).."' from type '"..fromType.."' to number when parsing DCML")
            end
            rValue = temp
        elseif toType == "boolean" then
            rValue = value:lower() == "true"
        elseif toType == "color" or toType == "colour" then
            -- convert to a decimal colour
            local temp = colours[ key ] or colors[ key ]
            if not temp then
                return error("Failed to convert '"..tostring( value ).."' from type '"..fromType.."' to colour when parsing DCML")
            end
            rValue = temp
        else
            -- invalid/un-supported type
            return error("Cannot parse type '"..tostring( toType ).."' using DCML")
        end
    end

    return rValue
end

function Parser.parse( data )
    -- Loop the data, create instances of any tags (default class name is the tag name) OR use the XML handler (function)
    --[[
        Matrix can have:

        childHandler - If the tag has children this will be called with the parent tag and its children
        customHandler - If the tag is found the tag content will be passed here and no further processing will occur
        instanceHandler - When the tag instance is ready to be created this function/class will be called and any DCML arguments will be passed
        contentCanBe - If the content of the tag is present and the node has no children the content will be assigned this key (contentCanBe = "text". The content will be set as text)
        argumentHandler - If the tag has any arguments, this function will be called and passed the tag (args are in tag.xarg).
        argumentType - This table will be used to convert arguments to their correct types. ( X = "number". X will be converted to a number if possible, else error )
        callbacks - This table specifies the key name and controller function
        callbackGenerator - Required function used generate callbacks. Expected to return a function that on call will execute the callback from its controller.

        If the function entry is a normal function/class, then it will be called normally. However if the entry is a string starting with a '#' symbol then the function with a matching name will be called on the instance.

        e.g: #callback (instance.callback)
    ]]
    local parsed = {}
    for i = 1, #data do
        local element = data[i]

        local matrix = DCMLMatrix[ element.label ]
        if type( matrix ) ~= "table" then
            return error("No DCMLMatrix for tag with label '"..tostring(element.label).."'")
        end

        local custom = getFunction( false, matrix.customHandler )
        if custom then
            table.insert( parsed, custom( element ) )
        else
            -- Compile arguments to be passed to the instance constructor.
            local args = {}
            local handler = getFunction( false, matrix.argumentHandler )

            if handler then
                args = handler( element )
            else
                local callbacks = matrix.callbacks or {}
                for key, value in pairs( element.xarg ) do
                    if not callbacks[ key ] then
                        -- convert argument to correct type.
                        args[ key ] = convertToType( value, key, matrix )
                    end
                end

                if element.content and not element.hasChildren and matrix.contentCanBe then
                    args[ matrix.contentCanBe ] = convertToType( element.content, matrix.contentCanBe, matrix )
                end
            end


            -- Create an instance of the tag
            local instanceFn = getFunction( false, matrix.instanceHandler ) or class.getClass(element.label)

            local instance
            if instanceFn then
                instance = instanceFn( args )
            end

            if not instance then
                return error("Failed to generate instance for DCML tag '"..element.label.."'")
            end

            if element.hasChildren and matrix.childHandler then
                local childHandler = getFunction( instance, matrix.childHandler )
                if childHandler then
                    childHandler( element )
                end
            end

            -- Handle callbacks here.
            local generate = getFunction( instance, matrix.callbackGenerator )
            if generate then
                for key, value in pairs( matrix.callbacks ) do
                    if element.xarg[ key ] then
                        instance[ value ] = generate( instance, key, element.xarg[ key ] ) -- name, callback link (#<callback>)
                    end
                end
            elseif matrix.callbacks then
                log("w", "Couldn't generate callbacks for '"..element.label.."' during DCML parse. Callback generator not defined")
            end

            table.insert( parsed, instance )
        end
    end
    return parsed
end
_G.DCML = Parser