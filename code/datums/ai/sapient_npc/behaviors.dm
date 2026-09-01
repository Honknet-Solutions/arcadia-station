/** Executes exactly one accepted NPC action intent through the normal behavior-tree lifecycle. */
/datum/bt_node/ai_behavior/execute_npc_intent
	/// Intent currently owned by this behavior activation.
	var/datum/npc_action_intent/active_intent

/datum/bt_node/ai_behavior/execute_npc_intent/setup(datum/ai_controller/controller)
	var/datum/ai_controller/sapient_npc/sapient_controller = controller
	active_intent = sapient_controller.blackboard[BB_NPC_ACTION_INTENT]
	if(QDELETED(active_intent))
		active_intent = null
		return FALSE
	if(active_intent.requires_async())
		return active_intent.context_is_valid()
	if(!active_intent.begin())
		sapient_controller.complete_cognition_intent(active_intent, FALSE)
		active_intent = null
		return FALSE
	return TRUE

/datum/bt_node/ai_behavior/execute_npc_intent/perform(seconds_per_tick, datum/ai_controller/controller)
	if(QDELETED(active_intent))
		return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_FAILED
	if(active_intent.requires_async())
		var/async_flags = handle_async()
		if(async_flags)
			return async_flags
		if(!active_intent.context_is_valid())
			return AI_BEHAVIOR_INSTANT | AI_BEHAVIOR_FAILED
		return start_async()
	return active_intent.perform(seconds_per_tick)

/** Runs player interaction paths outside the non-sleeping AI subsystem tick. */
/datum/bt_node/ai_behavior/execute_npc_intent/perform_async(datum/ai_controller/controller)
	var/datum/npc_action_intent/intent = active_intent
	var/succeeded = !QDELETED(intent) && intent.begin()
	if(succeeded && !QDELETED(intent))
		var/result_flags = intent.perform(0)
		succeeded = !!(result_flags & AI_BEHAVIOR_SUCCEEDED)
	if(!async_still_valid() || QDELETED(intent) || active_intent != intent)
		return
	finish_async(succeeded ? AI_BEHAVIOR_SUCCEEDED : AI_BEHAVIOR_FAILED)

/datum/bt_node/ai_behavior/execute_npc_intent/finish_action(datum/ai_controller/controller, succeeded)
	var/datum/ai_controller/sapient_npc/sapient_controller = controller
	if(!QDELETED(active_intent) && sapient_controller.blackboard[BB_NPC_ACTION_INTENT] == active_intent)
		sapient_controller.complete_cognition_intent(active_intent, succeeded)
	active_intent = null
	return ..()

/** Low-cost leaf that submits at most one coalesced cognition request for an idle actor. */
/datum/bt_node/ai_behavior/request_npc_cognition
	time_between_perform = 0.5 SECONDS

/datum/bt_node/ai_behavior/request_npc_cognition/perform(seconds_per_tick, datum/ai_controller/controller)
	var/datum/ai_controller/sapient_npc/sapient_controller = controller
	sapient_controller.request_cognition()
	return AI_BEHAVIOR_DELAY | AI_BEHAVIOR_SUCCEEDED
