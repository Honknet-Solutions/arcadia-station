/** A one-time server-generated action option exposed to the cognition gateway. */
/datum/npc_capability_offer
	/// Opaque identifier valid only inside its owning request.
	var/capability_id
	/// Server-owned capability type; never accepted from gateway text.
	var/datum/npc_capability/capability_type
	/// Provider-neutral action kind copied from the capability type.
	var/capability_kind
	/// Weak target reference retained only on the game server.
	var/datum/weakref/target_ref
	/// Optional second server-owned target used by targeted datum/actions.
	var/datum/weakref/secondary_target_ref
	/// Human-readable constrained action description.
	var/description
	/// Request-local perception ID, when the action refers to an observed entity.
	var/target_label
	/// Opaque server-authored execution data which is never serialized to the gateway.
	var/list/action_data = list()

/datum/npc_capability_offer/New(
	capability_id,
	datum/npc_capability/capability_type,
	datum/target,
	description,
	target_label,
	list/action_data,
	datum/secondary_target,
)
	src.capability_id = capability_id
	src.capability_type = capability_type
	capability_kind = initial(capability_type.capability_kind)
	if(!isnull(target))
		target_ref = WEAKREF(target)
	if(!isnull(secondary_target))
		secondary_target_ref = WEAKREF(secondary_target)
	src.description = description
	src.target_label = target_label
	if(!isnull(action_data))
		src.action_data = action_data.Copy()

/datum/npc_capability_offer/Destroy(force)
	target_ref = null
	secondary_target_ref = null
	action_data = null
	return ..()

/** Returns the public action description without a BYOND ref or type path. */
/datum/npc_capability_offer/proc/serialize()
	return list(
		"capability_id" = capability_id,
		"action" = capability_kind,
		"description" = description,
		"target" = target_label,
	)

/**
 * Accepted, immutable action derived from one server-generated capability offer.
 *
 * It retains weak context references and revalidates the control session on every behavior tick.
 */
/datum/npc_action_intent
	/// Actor that owned the request.
	var/datum/weakref/actor_ref
	/// Controller that was active when the response was accepted.
	var/datum/weakref/controller_ref
	/// Body that was active when the response was accepted.
	var/datum/weakref/pawn_ref
	/// Optional weak action target.
	var/datum/weakref/target_ref
	/// Optional second server-selected target.
	var/datum/weakref/secondary_target_ref
	/// Owned executable capability instance.
	var/datum/npc_capability/capability
	/// Server-authored execution parameters copied from the accepted offer.
	var/list/action_data = list()
	/// Server-authored description retained for factual result memory.
	var/action_description
	/// Sanitized local speech used only by the say capability.
	var/speech
	/// Actor state version accepted from the request.
	var/state_version
	/// Control epoch that must remain unchanged until execution ends.
	var/session_epoch
	/// Hard world-time deadline preventing an action from running forever.
	var/expires_at
	/// Actual execution summary recorded after the behavior ends.
	var/result_summary
	/// TRUE after capability begin succeeds.
	var/started = FALSE

/datum/npc_action_intent/New(
	datum/component/npc_actor/actor,
	datum/ai_controller/sapient_npc/controller,
	datum/npc_capability_offer/offer,
	speech,
)
	actor_ref = WEAKREF(actor)
	controller_ref = WEAKREF(controller)
	pawn_ref = WEAKREF(controller.pawn)
	target_ref = offer.target_ref
	secondary_target_ref = offer.secondary_target_ref
	capability = new offer.capability_type()
	action_data = offer.action_data.Copy()
	action_description = offer.description
	src.speech = speech
	state_version = actor.state_version
	session_epoch = actor.session_epoch
	expires_at = world.time + NPC_COGNITION_ACTION_TTL

/datum/npc_action_intent/Destroy(force)
	QDEL_NULL(capability)
	actor_ref = null
	controller_ref = null
	pawn_ref = null
	target_ref = null
	secondary_target_ref = null
	action_data = null
	return ..()

/** Validates identity, body and controller ownership after the asynchronous boundary. */
/datum/npc_action_intent/proc/context_is_valid()
	var/datum/component/npc_actor/actor = actor_ref?.resolve()
	var/datum/ai_controller/sapient_npc/controller = controller_ref?.resolve()
	var/mob/living/body = pawn_ref?.resolve()
	if(QDELETED(actor) || QDELETED(controller) || QDELETED(body))
		return FALSE
	if(actor.parent != body || body.ai_controller != controller)
		return FALSE
	if(actor.session_epoch != session_epoch || world.time > expires_at)
		return FALSE
	if(body.client || !actor.cognition_enabled)
		return FALSE
	return TRUE

/** Starts the physical action only after current-world revalidation. */
/datum/npc_action_intent/proc/begin()
	if(!context_is_valid())
		return FALSE
	var/datum/ai_controller/sapient_npc/controller = controller_ref.resolve()
	started = capability.begin(controller, src)
	return started

/** Returns whether the selected player path may sleep and must run in the BT async lane. */
/datum/npc_action_intent/proc/requires_async()
	return capability.async_execution

/** Advances a non-sleeping capability from the behavior tree. */
/datum/npc_action_intent/proc/perform(seconds_per_tick)
	if(!started || !context_is_valid())
		return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_FAILED
	var/datum/ai_controller/sapient_npc/controller = controller_ref.resolve()
	return capability.perform(seconds_per_tick, controller, src)

/** Symmetrically stops movement/signals owned by the capability. */
/datum/npc_action_intent/proc/finish(succeeded)
	var/datum/ai_controller/sapient_npc/controller = controller_ref?.resolve()
	capability.finish(controller, src, succeeded)
	started = FALSE

/** Base server-authoritative physical capability. */
/datum/npc_capability
	/// Provider-neutral action kind.
	var/capability_kind = "invalid"
	/// TRUE when begin() may sleep through player interaction code or do_after.
	var/async_execution = FALSE

/** Revalidates and starts the action. Sleeping implementations are dispatched by the BT async lane. */
/datum/npc_capability/proc/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return FALSE

/** Performs one non-sleeping behavior-tree tick. */
/datum/npc_capability/proc/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	SHOULD_NOT_SLEEP(TRUE)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_FAILED

/** Releases capability-owned movement or signal state. */
/datum/npc_capability/proc/finish(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent, succeeded)
	return

/** Deterministic short pause used both as an offered action and an outage fallback. */
/datum/npc_capability/wait
	capability_kind = NPC_CAPABILITY_WAIT
	/// World time at which the pause succeeds.
	var/end_time

/datum/npc_capability/wait/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	end_time = world.time + NPC_COGNITION_FALLBACK_WAIT
	intent.result_summary = "waited briefly"
	return TRUE

/datum/npc_capability/wait/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	if(world.time < end_time)
		return AI_BEHAVIOR_INSTANT
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/** Local speech that cannot select a radio channel or emote through message prefixes. */
/datum/npc_capability/say
	capability_kind = NPC_CAPABILITY_SAY

/datum/npc_capability/say/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	if(!body.can_speak() || !istext(intent.speech))
		return FALSE
	var/message = htmlrendertext(html_decode(strip_html_full(html_decode(intent.speech), NPC_COGNITION_MAX_SPEECH_TEXT)))
	var/static/list/forbidden_prefixes = list(";", ":", ".", "*")
	while(length(message) && copytext_char(message, 1, 2) in forbidden_prefixes)
		message = trim_left(copytext_char(message, 2))
	if(!length(message))
		return FALSE
	body.say(message, forced = "NPC cognition", message_range = NPC_COGNITION_VIEW_RANGE)
	var/datum/component/npc_actor/actor = intent.actor_ref?.resolve()
	if(!QDELETED(actor))
		var/datum/language/selected_language = GLOB.language_datum_instances[body.get_selected_language()]
		actor.record_conversation_turn(message, actor.profile.identity_name, selected_language?.name)
	intent.result_summary = "said: [message]"
	return TRUE

/datum/npc_capability/say/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/** JPS movement to a server-selected nearby turf. */
/datum/npc_capability/move
	capability_kind = NPC_CAPABILITY_MOVE
	/// Set when the movement loop reports an unrecoverable path failure.
	var/movement_failed = FALSE

/datum/npc_capability/move/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/atom/destination = intent.target_ref?.resolve()
	if(QDELETED(destination) || get_dist(body, destination) > NPC_COGNITION_VIEW_RANGE)
		return FALSE
	var/turf/destination_turf = destination
	if(istype(destination_turf) && destination_turf.density)
		return FALSE
	if(!(body.mobility_flags & MOBILITY_MOVE))
		return FALSE
	var/minimum_distance = max(0, intent.action_data["minimum_distance"] || 0)
	if(get_dist(body, destination) <= minimum_distance)
		intent.result_summary = "already reached [intent.action_description]"
		return TRUE
	RegisterSignal(body, COMSIG_MOB_AI_MOVEMENT_FAILED, PROC_REF(on_movement_failed))
	controller.ai_movement.start_moving_towards(controller, destination, minimum_distance)
	intent.result_summary = intent.action_description
	return TRUE

/datum/npc_capability/move/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/atom/destination = intent.target_ref?.resolve()
	if(movement_failed || QDELETED(destination))
		return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_FAILED
	var/minimum_distance = max(0, intent.action_data["minimum_distance"] || 0)
	if(get_dist(body, destination) <= minimum_distance)
		return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED
	if(!controller.ai_movement.moving_controllers[controller])
		controller.ai_movement.start_moving_towards(controller, destination, minimum_distance)
	return AI_BEHAVIOR_INSTANT

/datum/npc_capability/move/finish(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent, succeeded)
	var/mob/living/body = intent.pawn_ref?.resolve()
	if(!QDELETED(body))
		UnregisterSignal(body, COMSIG_MOB_AI_MOVEMENT_FAILED)
	if(!QDELETED(controller) && controller.ai_movement.moving_controllers[controller])
		controller.ai_movement.stop_moving_towards(controller)
	movement_failed = FALSE

/datum/npc_capability/move/proc/on_movement_failed(datum/source)
	SIGNAL_HANDLER
	movement_failed = TRUE

/** Records the current examine result without displaying client UI or inventing hidden knowledge. */
/datum/npc_capability/inspect
	capability_kind = NPC_CAPABILITY_INSPECT

/datum/npc_capability/inspect/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/atom/target = intent.target_ref?.resolve()
	if(QDELETED(target) || !CAN_SEE_RANGED(target, body, NPC_COGNITION_VIEW_RANGE))
		return FALSE
	var/list/examine_result = target.examine(body)
	var/summary = islist(examine_result) ? jointext(examine_result, " ") : "[target]"
	intent.result_summary = htmlrendertext(html_decode(strip_html_full(html_decode(summary), NPC_COGNITION_MAX_MEMORY_TEXT)))
	return TRUE

/datum/npc_capability/inspect/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/** Empty-hand, non-combat adjacent interaction with a server-selected non-mob target. */
/datum/npc_capability/interact
	capability_kind = NPC_CAPABILITY_INTERACT

/datum/npc_capability/interact/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/atom/target = intent.target_ref?.resolve()
	if(QDELETED(target) || ismob(target) || !body.Adjacent(target))
		return FALSE
	if(!isnull(body.get_active_held_item()))
		return FALSE
	if(!controller.ai_interact(target, combat_mode = FALSE, modifiers = list()))
		return FALSE
	intent.result_summary = "attempted a non-combat interaction with [target]"
	return TRUE

/datum/npc_capability/interact/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/** Executes a server-authored click through the same ClickOn path used by a player. */
/datum/npc_capability/world_click
	capability_kind = NPC_CAPABILITY_WORLD_CLICK
	async_execution = TRUE

/datum/npc_capability/world_click/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/atom/target = intent.target_ref?.resolve()
	if(QDELETED(target) || world.time <= body.next_click)
		return FALSE
	if(!(target in body.DirectAccess()) && !CAN_SEE_RANGED(target, body, NPC_COGNITION_VIEW_RANGE))
		return FALSE
	var/combat_mode = !!intent.action_data["combat_mode"]
	if(!combat_mode && !(target in body.DirectAccess()) && !body.Adjacent(target))
		if(!(body.mobility_flags & MOBILITY_MOVE))
			return FALSE
		var/approach_deadline = world.time + NPC_COGNITION_INTERACTION_APPROACH_TIMEOUT
		controller.ai_movement.start_moving_towards(controller, target, 1)
		while(!body.Adjacent(target) && world.time < approach_deadline && intent.context_is_valid())
			if(!controller.ai_movement.moving_controllers[controller])
				break
			stoplag(0.1 SECONDS)
		if(controller.ai_movement.moving_controllers[controller])
			controller.ai_movement.stop_moving_towards(controller)
		if(!intent.context_is_valid() || !body.Adjacent(target))
			return FALSE
	var/list/modifiers = intent.action_data["modifiers"]
	if(!islist(modifiers))
		modifiers = list()
	if(!controller.ai_interact(target, combat_mode, modifiers.Copy()))
		return FALSE
	intent.result_summary = "attempted: [intent.action_description]"
	return TRUE

/datum/npc_capability/world_click/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/world_click/finish(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent, succeeded)
	if(!QDELETED(controller) && controller.ai_movement.moving_controllers[controller])
		controller.ai_movement.stop_moving_towards(controller)

/** Triggers an action currently owned and available to the NPC body. */
/datum/npc_capability/action
	capability_kind = NPC_CAPABILITY_ACTION
	async_execution = TRUE

/datum/npc_capability/action/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/datum/action/action = intent.target_ref?.resolve()
	if(QDELETED(action) || action.owner != body || !(action in body.actions) || !action.owner_has_control || !action.IsAvailable())
		return FALSE
	var/datum/action/cooldown/cooldown_action = action
	var/result
	if(istype(cooldown_action) && cooldown_action.click_to_activate)
		var/atom/action_target = intent.secondary_target_ref?.resolve()
		if(QDELETED(action_target) || !CAN_SEE_RANGED(action_target, body, NPC_COGNITION_VIEW_RANGE))
			return FALSE
		result = cooldown_action.Trigger(body, NONE, action_target)
	else
		result = action.Trigger(body, NONE)
	if(!result)
		return FALSE
	intent.result_summary = intent.action_description
	return TRUE

/datum/npc_capability/action/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/swap_hand
	capability_kind = NPC_CAPABILITY_SWAP_HAND

/datum/npc_capability/swap_hand/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	if(length(body.held_items) < 2 || !body.swap_hand(body.get_inactive_hand_index(), silent = TRUE))
		return FALSE
	intent.result_summary = "switched active hand"
	return TRUE

/datum/npc_capability/swap_hand/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/drop_item
	capability_kind = NPC_CAPABILITY_DROP_ITEM

/datum/npc_capability/drop_item/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/obj/item/item = intent.target_ref?.resolve()
	if(QDELETED(item) || body.get_active_held_item() != item || !body.dropItemToGround(item))
		return FALSE
	intent.result_summary = "dropped [item]"
	return TRUE

/datum/npc_capability/drop_item/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/equip_item
	capability_kind = NPC_CAPABILITY_EQUIP_ITEM

/datum/npc_capability/equip_item/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/obj/item/item = intent.target_ref?.resolve()
	if(QDELETED(item) || body.get_active_held_item() != item || !item.slot_flags)
		return FALSE
	if(!body.equip_to_appropriate_slot(item, indirect_action = TRUE))
		return FALSE
	intent.result_summary = "equipped [item]"
	return TRUE

/datum/npc_capability/equip_item/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/pull
	capability_kind = NPC_CAPABILITY_PULL

/datum/npc_capability/pull/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/atom/movable/target = intent.target_ref?.resolve()
	if(QDELETED(target) || target == body || !body.Adjacent(target))
		return FALSE
	body.start_pulling(target)
	if(body.pulling != target)
		return FALSE
	intent.result_summary = "started pulling [target]"
	return TRUE

/datum/npc_capability/pull/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/stop_pulling
	capability_kind = NPC_CAPABILITY_STOP_PULLING

/datum/npc_capability/stop_pulling/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	var/atom/movable/expected_target = intent.target_ref?.resolve()
	if(QDELETED(expected_target) || body.pulling != expected_target)
		return FALSE
	body.stop_pulling()
	if(!isnull(body.pulling))
		return FALSE
	intent.result_summary = "stopped pulling [expected_target]"
	return TRUE

/datum/npc_capability/stop_pulling/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/rest
	capability_kind = NPC_CAPABILITY_REST

/datum/npc_capability/rest/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	if(!(body.mobility_flags & MOBILITY_REST))
		return FALSE
	body.toggle_resting()
	intent.result_summary = body.resting ? "lay down to rest" : "stood up"
	return TRUE

/datum/npc_capability/rest/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED

/datum/npc_capability/resist
	capability_kind = NPC_CAPABILITY_RESIST
	async_execution = TRUE

/datum/npc_capability/resist/begin(datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	var/mob/living/body = controller.pawn
	if(!body.can_resist())
		return FALSE
	body.execute_resist()
	intent.result_summary = "attempted to resist the current restraint or hazard"
	return TRUE

/datum/npc_capability/resist/perform(seconds_per_tick, datum/ai_controller/sapient_npc/controller, datum/npc_action_intent/intent)
	return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_SUCCEEDED
