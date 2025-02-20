local clusterio_serialize = require("modules/clusterio/serialize")
local character_inventories = require("modules/inventory_sync/define_player_inventories")
local character_stat_keys = require("modules/inventory_sync/define_player_stat_keys")
local serialize = {}

function serialize.serialize_inventories(source, inventories)
	local serialized = {}

	for name, index in pairs(inventories) do
		local inventory = source.get_inventory(index)
		if inventory ~= nil then
			serialized[name] = clusterio_serialize.serialize_inventory(inventory)
		end
	end

	return serialized
end

function serialize.deserialize_inventories(destination, serialized, inventories)
	for name, index in pairs(inventories) do
		local inventory = destination.get_inventory(index)
		if inventory ~= nil and serialized[name] ~= nil then
			inventory.clear()
			clusterio_serialize.deserialize_inventory(inventory, serialized[name])
		end
	end
end

-- Characters are serialized into a table with the following fields:
--   character_crafting_speed_modifier
--   character_mining_speed_modifier
--   character_additional_mining_categories
--   character_running_speed_modifier
--   character_build_distance_bonus
--   character_item_drop_distance_bonus
--   character_reach_distance_bonus
--   character_resource_reach_distance_bonus
--   character_item_pickup_distance_bonus
--   character_loot_pickup_distance_bonus
--   character_inventory_slots_bonus
--   character_trash_slot_count_bonus
--   character_maximum_following_robot_count_bonus
--   character_health_bonus
--   character_personal_logistic_requests_enabled
--   inventories: table of character inventory name to inventory content
function serialize.serialize_character(character)
	local serialized = { }

	-- Serialize character stats
	for _, key in pairs(character_stat_keys) do
		serialized[key] = character[key]
	end

	-- Serialize character inventories
	serialized.inventories = serialize.serialize_inventories(character, character_inventories)

	return serialized
end

function serialize.deserialize_character(character, serialized)
	-- Deserialize character stats
	for _, key in pairs(character_stat_keys) do
		character[key] = serialized[key]
	end

	-- Deserialize character inventories
	serialize.deserialize_inventories(character, serialized.inventories, character_inventories)
end

-- Personal logistic slots is a table mapping string indexes to a table with the following fields:
--   name
--   min
--   max
function serialize.serialize_personal_logistic_slots(player)
	local serialized = nil

	-- Serialize personal logistic slots
	for i = 1, 200 do -- Nobody will have more than 200 logistic slots, right?
		local slot = player.get_personal_logistic_slot(i)
		if slot.name ~= nil then
			if not serialized then
				serialized = {}
			end
			serialized[tostring(i)] = {
				name = slot.name,
				min = slot.min,
				max = slot.max,
			}
		end
	end

	return serialized
end

function serialize.deserialize_personal_logistic_slots(player, serialized)
	if not serialized then
		return
	end

	-- Load personal logistic slots
	for i = 1, 200 do
		local slot = serialized[tostring(i)] -- 1 is empty to force array to be spare
		if slot ~= nil then
			player.set_personal_logistic_slot(i, slot)
		end
	end
end

local controller_to_name = {}
for name, value in pairs(defines.controllers) do
	controller_to_name[value] = name
end

-- Players are serialized into a table with the following fields:
--   name
--   controller: may not be cutscene or editor
--   color
--   chat_color
--   tag
--   force
--   cheat_mod
--   flashlight
--   ticks_to_respawn (optional)
--   character (optional)
--   inventories: non-character inventories
--   hotbar: table of string indexes to names (optional)
--   personal_logistic_slots (optional)
function serialize.serialize_player(player)
	local serialized = {
		controller = controller_to_name[player.controller_type],
		name = player.name,
		color = player.color,
		chat_color = player.chat_color,
		tag = player.tag,
		force = player.force.name,
		cheat_mode = player.cheat_mode,
		flashlight = player.is_flashlight_enabled(),
		ticks_to_respawn = player.ticks_to_respawn,
	}

	-- For the waiting to respawn state the inventory logistic requests and filters are hidden on the player
	if player.controller_type == defines.controllers.ghost and player.ticks_to_respawn then
		player.ticks_to_respawn = nil -- Respawn now

		serialized.personal_logistic_slots = serialize.serialize_personal_logistic_slots(player)
		serialized.inventories = serialize.serialize_inventories(player, character_inventories)

		-- Go back to waiting for respawn
		local character = player.character
		player.ticks_to_respawn = serialized.ticks_to_respawn
		character.destroy()
	end

	-- Serialize character
	if player.character then
		serialized.character = serialize.serialize_character(player.character)
		serialized.personal_logistic_slots = serialize.serialize_personal_logistic_slots(player)
	end

	-- Serialize non-character inventories
	if player.controller_type == defines.controllers.god then
		serialized.inventories = serialize.serialize_inventories(player, { main = defines.inventory.god_main })
	end

	-- Serialize hotbar
	for i = 1, 100 do
		local slot = player.get_quick_bar_slot(i)
		if slot ~= nil and slot.name ~= nil then
			if not serialized.hotbar then
				serialized.hotbar = {}
			end
			serialized.hotbar[tostring(i)] = slot.name
		end
	end

	return serialized
end

function serialize.deserialize_player(player, serialized)
	if player.controller_type ~= defines.controllers[serialized.controller] or serialized.controller == "ghost" then
		-- If targeting the character or ghost controller then create a character
		if serialized.controller == "character" or serialized.controller == "ghost" then
			if player.controller_type == defines.controllers.ghost or player.controller_type == defines.controllers.spectator then
				player.set_controller({ type = defines.controllers.god })
			end
			if player.controller_type == defines.controllers.god then
				player.create_character()
			end

			-- The ghost state stores hidden logistic and filters which are only accessible in the character controller
			if serialized.controller == "ghost" then
				serialize.deserialize_personal_logistic_slots(player, serialized.personal_logistic_slots)
				serialize.deserialize_inventories(player, serialized.inventories, character_inventories)
				local character = player.character
				if serialized.ticks_to_respawn then
					player.ticks_to_respawn = serialized.ticks_to_respawn
				else
					-- We have to set ticks to respawn to save the hidden state into the player but we
					-- can't unset tick_to_respawn by setting it back to nil as that triggers a respawn.
					player.ticks_to_respawn = 0
					player.set_controller({ type = defines.controller.god })
					player.set_controller({ type = defines.controller.ghost })
				end
				character.destroy()
			end

		else
			-- Targeting the god or spectator controller, if coming from the
			-- character controller then destroy the character
			if player.controller_type == defines.controllers.character then
				player.character.destroy()
			end

			-- Switching to god or spectator is a matter of setting the controller
			if player.controller_type ~= defines.controllers[serialized.controller] then
				player.set_controller({ type = defines.controllers[serialized.controller] })
			end
		end
	end

	player.color = serialized.color
	player.chat_color = serialized.chat_color
	player.tag = serialized.tag
	player.force = serialized.force
	player.cheat_mode = serialized.cheat_mode
	if serialized.flashlight then
		player.enable_flashlight()
	else
		player.disable_flashlight()
	end

	-- Deserialize character
	if player.character then
		serialize.deserialize_character(player.character, serialized.character)
		serialize.deserialize_personal_logistic_slots(player, serialized.personal_logistic_slots)
	end

	-- Deserialize non-character inventories
	if player.controller_type == defines.controllers.god then
		serialize.deserialize_inventories(player, serialized.inventories, { main = defines.inventory.god_main })
	end

	-- Deserialize hotbar
	if serialized.hotbar then
		for i = 1, 100 do
			if serialized.hotbar[tostring(i)] ~= nil then
				player.set_quick_bar_slot(i, serialized.hotbar[tostring(i)])
			end
		end
	end
end

return serialize
