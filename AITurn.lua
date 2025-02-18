--[[
This file is part of Courseplay (https://github.com/Courseplay/courseplay)
Copyright (C) 2019 Peter Vaiko

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

--[[
Turn maneuvers for the AI driver
]]

---@class AITurn
AITurn = CpObject()
AITurn.debugChannel = 12

function AITurn:init(vehicle, driver, turnContext)
	self:addState('FINISHING_ROW')
	self:addState('TURNING')
	self:addState('ENDING_TURN')
	self:addState('STARTING_ROW')
	self.vehicle = vehicle
	---@type AIDriver
	self.driver = driver
	---@type TurnContext
	self.turnContext = turnContext
	self.state = self.states.FINISHING_ROW
end

function AITurn:addState(state)
	if not self.states then self.states = {} end
	self.states[state] = {name = state}
end

function AITurn:debug(...)
	courseplay.debugVehicle(self.debugChannel, self.vehicle, ...)
end

--- Start the actual turn maneuver after the row is finished
function AITurn:startTurn()

end

function AITurn:turn()

end

function AITurn.canMakeKTurn(vehicle, turnContext)
	if turnContext:isHeadlandCorner() then
		courseplay.debugVehicle(AITurn.debugChannel, vehicle, 'Headland turn, let turn.lua drive for now.')
		return false
	end
	if vehicle.cp.turnDiameter <= math.abs(turnContext.dx) then
		courseplay.debugVehicle(AITurn.debugChannel, vehicle, 'wide turn with no reversing (turn diameter = %.1f, dx = %.1f, let turn.lua do that for now.',
			vehicle.cp.turnDiameter, math.abs(turnContext.dx))
		return false
	end
	if not AIVehicleUtil.getAttachedImplementsAllowTurnBackward(vehicle) then
		courseplay.debugVehicle(AITurn.debugChannel, vehicle, 'Not all attached implements allow for reversing, let turn.lua handle this for now')
		return false
	end
	return true
end

function AITurn:drive(dt)
	local iAmDriving = true
	self.driver:setSpeed(self.vehicle.cp.speeds.turn)
	-- Finishing the current row
	if self.state == self.states.FINISHING_ROW then
		iAmDriving = self:finishRow(dt)
	elseif self.state == self.states.ENDING_TURN then
		-- Ending the turn (starting next row)
		iAmDriving = self:endTurn(dt)
	elseif self.state == self.states.STARTING_ROW then
		-- implements lowered, PPC is driving the temporary course ending the turn, onNextCourse will return to work
		-- nothing to do here
		iAmDriving = false
	else
		-- Performing the actual turn
		iAmDriving = self:turn(dt)
	end
	return iAmDriving
end

function AITurn:finishRow(dt)
	-- keep driving straight until we need to raise our implements
	self.driver:driveVehicleInDirection(dt, true, true, 0, 1, self.driver:getSpeed())
	if self.driver:shouldRaiseImplements(self.turnContext.turnStartForwardWpNode.node) then
		self.driver:raiseImplements()
		self:debug('Row finished, starting turn.')
		self:startTurn()
	end
	return true
end

function AITurn:endTurn(dt)
	-- keep driving on the turn ending temporary course until we need to lower our implements
	-- check implements only if we are more or less in the right direction (next row's direction)
	if self.turnContext:isDirectionCloseToEndDirection(self.driver:getDirectionNode()) and
		self.driver:shouldLowerImplements(self.turnContext.turnEndWpNode.node, false) then
		self.driver:lowerImplements()
		self:debug('Turn ended, continue on row')
		self.state = self.states.STARTING_ROW
	end
	return false
end

--[[
A K (3 point) turn to make a 180 to continue on the next row.addState
]]

---@class KTurn
KTurn = CpObject(AITurn)

function KTurn:init(vehicle, driver, turnContext)
	AITurn.init(self, vehicle, driver, turnContext)
	self:addState('FORWARD')
	self:addState('REVERSE')
end

function KTurn:startTurn()
	self.state = self.states.FORWARD
end

function KTurn:turn(dt)
	-- we end the K turn with a temporary course leading straight into the next row. During this turn the
	-- AI driver's state remains TURNING and thus calls AITurn:drive() which wil take care of raising the implements
	local endTurn = function()
		self.state = self.states.ENDING_TURN
		local endingTurnCourse = self.turnContext:createEndingTurnCourse(self.vehicle)
		self.driver:startFieldworkCourseWithTemporaryCourse(endingTurnCourse, self.turnContext.turnEndWpIx)
	end

	local dx, _, dz = self.turnContext:getLocalPositionFromTurnEnd(self.driver:getDirectionNode())
	local turnRadius = self.vehicle.cp.turnDiameter / 2
	if self.state == self.states.FORWARD then
		if dz > 0 then
			-- drive straight until we are beyond the turn end
			self.driver:driveVehicleBySteeringAngle(dt, true, 0, self.turnContext:isLeftTurn(), self.driver:getSpeed())
		elseif not self.turnContext:isDirectionPerpendicularToTurnEndDirection(self.driver:getDirectionNode()) then
			-- full turn towards the turn end waypoint
			self.driver:driveVehicleBySteeringAngle(dt, true, 1, self.turnContext:isLeftTurn(), self.driver:getSpeed())
		else
			-- drive straight ahead until we cross turn end line
			self.driver:driveVehicleBySteeringAngle(dt, true, 0, self.turnContext:isLeftTurn(), self.driver:getSpeed())
			if self.turnContext:isLateralDistanceGreater(dx, turnRadius * 1.05) then
				-- no need to reverse from here, we can make the turn
				self:debug('K Turn: dx = %.1f, r = %.1f, no need to reverse.', dx, turnRadius)
				endTurn()
			else
				-- reverse until we can make turn to the turn end point
				self:debug('K Turn: dx = %.1f, r = %.1f, reversing now.', dx, turnRadius)
				self.state = self.states.REVERSE
			end
		end
	elseif self.state == self.states.REVERSE then
		self.driver:driveVehicleBySteeringAngle(dt, false, 0, self.turnContext:isLeftTurn(), self.driver:getSpeed())
		if math.abs(dx) > turnRadius * 1.05 then
			self:debug('K Turn forwarding again')
			endTurn()
		end
	end
	return true
end
