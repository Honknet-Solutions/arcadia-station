/**
 * Species-independent adapter between cognition and a concrete [/mob/living] body.
 *
 * Drivers expose only capabilities the current body can attempt. They never hold personality,
 * goals or relationships, so a species change cannot silently rewrite character identity.
 */
/datum/npc_body_driver
	/// Stable provider-neutral body family label.
	var/body_kind = "living"

/** Returns TRUE when this driver can describe and operate the supplied body. */
/datum/npc_body_driver/proc/supports_body(mob/living/body)
	return istype(body)

/** Returns a visible role without assuming the body is a station humanoid. */
/datum/npc_body_driver/proc/describe_role(mob/living/body)
	return "resident"

/** Builds self-knowledge. Unlike perceived entities, this may contain the actor's real species. */
/datum/npc_body_driver/proc/serialize_body(mob/living/body)
	var/status = "conscious"
	if(body.stat == DEAD)
		status = "dead"
	else if(IS_UNCONSCIOUS_OR_CRIT(body))
		status = "incapacitated"
	var/list/understood_languages = list()
	for(var/language_type in body.get_understood_languages())
		var/datum/language/understood_language = GLOB.language_datum_instances[language_type]
		if(!isnull(understood_language))
			understood_languages += understood_language.name
	var/selected_language_type = body.get_selected_language()
	var/datum/language/selected_language = GLOB.language_datum_instances[selected_language_type]
	var/list/held_items = list()
	for(var/obj/item/held_item as anything in body.held_items)
		if(!isnull(held_item))
			held_items += htmlrendertext(html_decode(strip_html_full("[held_item]", MAX_NAME_LEN)))
	return list(
		"body_kind" = body_kind,
		"visible_name" = "[body]",
		"status" = status,
		"area" = "[get_area(body)]",
		"health" = body.health,
		"maximum_health" = body.maxHealth,
		"can_move" = !!(body.mobility_flags & MOBILITY_MOVE),
		"can_speak" = !!body.can_speak(),
		"resting" = !!body.resting,
		"combat_mode" = !!body.combat_mode,
		"restrained" = HAS_TRAIT(body, TRAIT_RESTRAINED),
		"on_fire" = !!body.on_fire,
		"held_items" = held_items,
		"selected_language" = selected_language?.name,
		"understood_languages" = understood_languages,
	)

/**
 * Adds opaque, server-owned actions that are valid for the request snapshot.
 *
 * The gateway receives descriptions and one-time IDs, never BYOND refs or arbitrary type paths.
 */
/datum/npc_body_driver/proc/build_capability_offers(datum/npc_cognition_request/request, datum/npc_perception_snapshot/snapshot)
	var/mob/living/body = request.pawn_ref?.resolve()
	if(QDELETED(body))
		return

	request.add_capability_offer(/datum/npc_capability/wait, null, "pause briefly")
	if(body.can_speak())
		request.add_capability_offer(/datum/npc_capability/say, null, "speak locally")
	if(body.can_resist())
		request.add_capability_offer(/datum/npc_capability/resist, null, "resist restraints, fire, pulling, buckling, or confinement")
	if(!isnull(body.pulling))
		request.add_capability_offer(/datum/npc_capability/stop_pulling, body.pulling, "stop pulling [body.pulling]")
	if(body.mobility_flags & MOBILITY_REST)
		request.add_capability_offer(/datum/npc_capability/rest, null, body.resting ? "stand up" : "lie down and rest")

	if(body.mobility_flags & MOBILITY_MOVE)
		for(var/direction in GLOB.cardinals)
			var/turf/destination = get_step(body, direction)
			if(isnull(destination) || destination.density)
				continue
			request.add_capability_offer(
				/datum/npc_capability/move,
				destination,
				"move [dir2text(direction)] one tile",
				action_data = list("minimum_distance" = 0),
			)

	var/target_count = 0
	for(var/datum/npc_perceived_entity/perceived as anything in snapshot.perceived_entities)
		var/atom/target = perceived.target_ref?.resolve()
		if(QDELETED(target))
			continue
		request.add_capability_offer(/datum/npc_capability/inspect, target, "inspect [perceived.perception_id]", perceived.perception_id)
		if((body.mobility_flags & MOBILITY_MOVE) && get_dist(body, target) > 1)
			request.add_capability_offer(
				/datum/npc_capability/move,
				target,
				"approach [perceived.perception_id]",
				perceived.perception_id,
				list("minimum_distance" = 1),
			)
		build_world_click_offers(request, body, target, perceived.perception_id)
		var/atom/movable/movable_target = target
		if(istype(movable_target) && body.Adjacent(movable_target) && movable_target != body)
			request.add_capability_offer(/datum/npc_capability/pull, movable_target, "start pulling [perceived.perception_id]", perceived.perception_id)
		target_count++
		if(target_count >= NPC_COGNITION_MAX_CAPABILITY_TARGETS)
			break

	var/obj/item/active_item = body.get_active_held_item()
	if(!isnull(active_item))
		request.add_capability_offer(
			/datum/npc_capability/world_click,
			active_item,
			"use [active_item] in hand",
			action_data = list("combat_mode" = FALSE, "modifiers" = list()),
		)
		request.add_capability_offer(
			/datum/npc_capability/world_click,
			active_item,
			"use [active_item]''s secondary in-hand action",
			action_data = list("combat_mode" = FALSE, "modifiers" = list(RIGHT_CLICK = TRUE)),
		)
		request.add_capability_offer(/datum/npc_capability/drop_item, active_item, "drop [active_item]")
		if(active_item.slot_flags)
			request.add_capability_offer(/datum/npc_capability/equip_item, active_item, "equip [active_item] in an appropriate free slot")

	if(length(body.held_items) > 1)
		request.add_capability_offer(/datum/npc_capability/swap_hand, null, "switch active hand")

	build_action_offers(request, body, snapshot)
	SEND_SIGNAL(body, COMSIG_ATOM_NPC_REQUEST_CAPABILITIES, request, snapshot)
	for(var/datum/npc_perceived_entity/perceived as anything in snapshot.perceived_entities)
		var/atom/target = perceived.target_ref?.resolve()
		if(!QDELETED(target))
			SEND_SIGNAL(target, COMSIG_ATOM_NPC_REQUEST_CAPABILITIES, request, snapshot)

/** Reuses contextual screentips and the normal ClickOn pipeline to expose current world affordances. */
/datum/npc_body_driver/proc/build_world_click_offers(
	datum/npc_cognition_request/request,
	mob/living/body,
	atom/target,
	target_label,
)
	var/obj/item/active_item = body.get_active_held_item()
	var/primary_description = active_item ? "use [active_item] on [target_label]" : "interact with [target_label]"
	request.add_capability_offer(
		/datum/npc_capability/world_click,
		target,
		primary_description,
		target_label,
		list("combat_mode" = FALSE, "modifiers" = list()),
	)
	request.add_capability_offer(
		/datum/npc_capability/world_click,
		target,
		"use the secondary interaction on [target_label]",
		target_label,
		list("combat_mode" = FALSE, "modifiers" = list(RIGHT_CLICK = TRUE)),
	)
	request.add_capability_offer(
		/datum/npc_capability/world_click,
		target,
		active_item ? "attack [target_label] with [active_item]" : "attack [target_label]",
		target_label,
		list("combat_mode" = TRUE, "modifiers" = list()),
	)

	if(!(target.flags_1 & HAS_CONTEXTUAL_SCREENTIPS_1) && !(active_item?.item_flags & ITEM_HAS_CONTEXTUAL_SCREENTIPS))
		return
	var/list/context = list()
	var/context_result = SEND_SIGNAL(target, COMSIG_ATOM_REQUESTING_CONTEXT_FROM_ITEM, context, active_item, body) \
		| (active_item && SEND_SIGNAL(active_item, COMSIG_ITEM_REQUESTING_CONTEXT_FOR_TARGET, context, target, body))
	if(!(context_result & CONTEXTUAL_SCREENTIP_SET))
		return

	var/static/list/context_modifiers = list(
		SCREENTIP_CONTEXT_LMB = list(),
		SCREENTIP_CONTEXT_RMB = list(RIGHT_CLICK = TRUE),
		SCREENTIP_CONTEXT_SHIFT_LMB = list(SHIFT_CLICK = TRUE),
		SCREENTIP_CONTEXT_CTRL_LMB = list(CTRL_CLICK = TRUE),
		SCREENTIP_CONTEXT_CTRL_RMB = list(CTRL_CLICK = TRUE, RIGHT_CLICK = TRUE),
		SCREENTIP_CONTEXT_ALT_LMB = list(ALT_CLICK = TRUE),
		SCREENTIP_CONTEXT_ALT_RMB = list(ALT_CLICK = TRUE, RIGHT_CLICK = TRUE),
		SCREENTIP_CONTEXT_CTRL_SHIFT_LMB = list(CTRL_CLICK = TRUE, SHIFT_CLICK = TRUE),
	)
	for(var/context_key in context_modifiers)
		if(!length("[context[context_key]]"))
			continue
		var/context_description = htmlrendertext(html_decode(strip_html_full("[context[context_key]]", NPC_COGNITION_MAX_MEMORY_TEXT)))
		request.add_capability_offer(
			/datum/npc_capability/world_click,
			target,
			"[context_description] [target_label]",
			target_label,
			list("combat_mode" = FALSE, "modifiers" = context_modifiers[context_key]),
		)

/** Exposes player-owned datum/actions, including targeted cooldown actions, without forcing availability. */
/datum/npc_body_driver/proc/build_action_offers(
	datum/npc_cognition_request/request,
	mob/living/body,
	datum/npc_perception_snapshot/snapshot,
)
	var/action_count = 0
	for(var/datum/action/action as anything in body.actions)
		if(action_count >= NPC_COGNITION_MAX_ACTIONS || request.capability_limit_reached())
			break
		if(QDELETED(action) || action.owner != body || !action.owner_has_control || !action.IsAvailable())
			continue
		var/action_name = htmlrendertext(html_decode(strip_html_full(action.name || "unnamed action", MAX_NAME_LEN)))
		var/datum/action/cooldown/cooldown_action = action
		if(istype(cooldown_action) && cooldown_action.click_to_activate)
			var/target_count = 0
			for(var/datum/npc_perceived_entity/perceived as anything in snapshot.perceived_entities)
				var/atom/action_target = perceived.target_ref?.resolve()
				if(QDELETED(action_target))
					continue
				request.add_capability_offer(
					/datum/npc_capability/action,
					action,
					"use [action_name] on [perceived.perception_id]",
					perceived.perception_id,
					secondary_target = action_target,
				)
				target_count++
				if(target_count >= NPC_COGNITION_MAX_CAPABILITY_TARGETS || request.capability_limit_reached())
					break
		else
			request.add_capability_offer(/datum/npc_capability/action, action, "use action: [action_name]")
		action_count++

/** Adapter for every humanoid species represented by [/mob/living/carbon/human] and [/datum/species]. */
/datum/npc_body_driver/humanoid
	body_kind = "humanoid"

/datum/npc_body_driver/humanoid/supports_body(mob/living/body)
	return ishuman(body)

/datum/npc_body_driver/humanoid/describe_role(mob/living/body)
	var/mob/living/carbon/human/humanoid = body
	return humanoid.get_assignment(if_no_id = "resident", if_no_job = "resident")

/datum/npc_body_driver/humanoid/serialize_body(mob/living/body)
	. = ..()
	var/mob/living/carbon/human/humanoid = body
	var/datum/species/species = humanoid.dna?.species
	.["species"] = species?.name || "Unknown"
	.["physical_attributes"] = htmlrendertext(html_decode(strip_html_full(species?.get_physical_attributes() || "", NPC_COGNITION_MAX_MEMORY_TEXT)))

/** Selects the narrowest current body adapter without coupling identity to species. */
/proc/create_npc_body_driver(mob/living/body)
	if(ishuman(body))
		return new /datum/npc_body_driver/humanoid()
	if(isliving(body))
		return new /datum/npc_body_driver()
	return null
