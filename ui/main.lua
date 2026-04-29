local CoreGui = game:GetService("CoreGui")
local UserInput = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local Interface = import("rbxassetid://11389137937")

if oh.Cache["ui/main"] then
	return Interface
end

import("ui/controls/TabSelector")
local MessageBox, MessageType = import("ui/controls/MessageBox")

local RemoteSpy
local ClosureSpy
local ScriptScanner
local ModuleScanner
local UpvalueScanner
local ConstantScanner

getgenv().touchPoints = {}
getgenv().touching = {}
getgenv().conduct = 0
getgenv().pressHold = false
getgenv().mainBase = Interface.Base
mainBase.Active = true

getgenv().MouseInFrame = function(uiobject)
	local mouse = game:GetService("Players").LocalPlayer:GetMouse()
    local y_cond = uiobject.AbsolutePosition.Y <= mouse.Y and mouse.Y <= uiobject.AbsolutePosition.Y + uiobject.AbsoluteSize.Y
    local x_cond = uiobject.AbsolutePosition.X <= mouse.X and mouse.X <= uiobject.AbsolutePosition.X + uiobject.AbsoluteSize.X

	return (y_cond and x_cond)
end

if signaluis then
	signaluis:Disconnect()
end

getgenv().signaluis = UserInput.InputBegan:Connect(function(input,gp)
	if (input.UserInputType == Enum.UserInputType.Touch) then
		conduct += 1
		local key, Signal = conduct, true
		touchPoints[key] = input.Position
		local startClock = os.clock()
		task.spawn(function()
			local threshold = 0.4
			repeat task.wait() until (os.clock()-startClock) > threshold  or not Signal
			if (os.clock()-startClock) < threshold then return end
			pressHold = true
		end)
		Signal = UserInput.InputEnded:Connect(function()
			for i, v in pairs(touching) do
				if v == true then
					--print(i,v)
				end
				touching[i] = false
			end
			touchPoints[key] = nil
			conduct -= 1
			Signal:Disconnect()
			Signal = nil
			task.wait()
			pressHold = false
		end)
	end
end)

local moduleId = {"RemoteSpy","ClosureSpy","ScriptScanner","ModuleScanner","UpvalueScanner","ConstantScanner","BugFinder"}

function moduleError(err)
	local message
	if err:find("valid member") then
		message = "The UI has updated, please rejoin and restart. If you get this message more than once, screenshot this message and report it in the Hydroxide server.\n\n" .. err
	else
		message = string.format("Report this error in Hydroxide's server:\n\n%s", err)
	end

	MessageBox.Show("An error has occurred", message, MessageType.OK, function()
		--Interface:Destroy()
	end)
end

xpcall(function()
	RemoteSpy = import("ui/modules/RemoteSpy");
	ClosureSpy = import("ui/modules/ClosureSpy");
	ScriptScanner = import("ui/modules/ScriptScanner");
	ModuleScanner = import("ui/modules/ModuleScanner");
	UpvalueScanner = import("ui/modules/UpvalueScanner");
	ConstantScanner = import("ui/modules/ConstantScanner");
	BugFinder = import("ui/modules/BugFinder"); 
end, function(err)
	moduleError(err)
end)

local constants = {
	opened = UDim2.new(0.5, -325, 0.5, -175),
	closed = UDim2.new(0.5, -325, 0, -400),
	reveal = UDim2.new(0.5, -15, 0, 20),
	conceal = UDim2.new(0.5, -15, 0, -75)
}

local Open = Interface.Open
local Base = Interface.Base
local Drag = Base.Drag
local Status = Base.Status
local Collapse = Drag.Collapse

function oh.setStatus(text)
	Status.Text = '• Status: ' .. text
end

function oh.getStatus()
	return Status.Text:gsub('• Status: ', '')
end

local dragging, dragStart, startPos

Drag.InputBegan:Connect(function(input)
	if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch and conduct == 0) then
		local dragEnded 

		dragging = true
		dragStart = input.Position
		startPos = Base.Position

		dragEnded = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				dragEnded:Disconnect()
			end
		end)
	end
end)

oh.Events.Drag = UserInput.InputChanged:Connect(function(input)
	if (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) and dragging then
		local delta = input.Position - dragStart
		Base.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

Open.MouseButton1Click:Connect(function()
	Open:TweenPosition(constants.conceal, "Out", "Quad", 0.15)
	Base:TweenPosition(constants.opened, "Out", "Quad", 0.15)
end)

Collapse.MouseButton1Click:Connect(function()
	Base:TweenPosition(constants.closed, "Out", "Quad", 0.15)
	Open:TweenPosition(constants.reveal, "Out", "Quad", 0.15)
end)

Interface.Name = HttpService:GenerateGUID(false)
if getHui then
	Interface.Parent = CoreGui or getHui()
else
	if syn then
		--syn.protect_gui(Interface)
	end

	Interface.Parent = CoreGui
end

return Interface
