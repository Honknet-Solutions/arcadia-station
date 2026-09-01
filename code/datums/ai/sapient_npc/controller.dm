/**
 * Universal controller for a sapient [/mob/living].
 *
 * Personality and memory remain in [/datum/component/npc_actor]; this controller owns only the
 * current body plan and stops automatically while a client controls the body.
 */
/datum/ai_controller/sapient_npc
	ai_movement = /datum/ai_movement/jps
	behavior_tree_json = "code/datums/ai/sapient_npc/sapient_npc.bt.json"
	movement_delay = 0.4 SECONDS
	max_target_distance = NPC_COGNITION_VIEW_RANGE

/datum/ai_controller/sapient_npc/TryPossessPawn(atom/new_pawn)
	if(!isliving(new_pawn))
		return AI_CONTROLLER_INCOMPATIBLE
	var/mob/living/living_pawn = new_pawn
	var/datum/component/npc_actor/actor = living_pawn.GetComponent(/datum/component/npc_actor)
	if(isnull(actor))
		actor = living_pawn.AddComponent(/datum/component/npc_actor)
	if(QDELETED(actor) || !actor.body_driver.supports_body(living_pawn))
		return AI_CONTROLLER_INCOMPATIBLE

	movement_delay = living_pawn.cached_multiplicative_slowdown
	RegisterSignal(living_pawn, COMSIG_MOB_MOVESPEED_UPDATED, PROC_REF(update_movespeed))
	actor.invalidate_session("controller_possessed")
	return ..()

/datum/ai_controller/sapient_npc/UnpossessPawn(destroy)
	if(!isnull(pawn))
		var/mob/living/living_pawn = pawn
		var/datum/component/npc_actor/actor = living_pawn.GetComponent(/datum/component/npc_actor)
		if(!QDELETED(actor))
			actor.invalidate_session("controller_unpossessed")
		UnregisterSignal(living_pawn, COMSIG_MOB_MOVESPEED_UPDATED)
	return ..()

/datum/ai_controller/sapient_npc/on_stat_changed(mob/living/source, new_stat)
	. = ..()
	update_able_to_run()

/datum/ai_controller/sapient_npc/setup_able_to_run()
	. = ..()
	RegisterSignal(pawn, COMSIG_MOB_INCAPACITATE_CHANGED, PROC_REF(update_able_to_run))
	if(ai_traits & PAUSE_DURING_DO_AFTER)
		RegisterSignals(pawn, list(COMSIG_DO_AFTER_BEGAN, COMSIG_DO_AFTER_ENDED), PROC_REF(update_able_to_run))

/datum/ai_controller/sapient_npc/clear_able_to_run()
	UnregisterSignal(pawn, list(COMSIG_MOB_INCAPACITATE_CHANGED, COMSIG_MOB_STATCHANGE, COMSIG_DO_AFTER_BEGAN, COMSIG_DO_AFTER_ENDED))
	return ..()

/datum/ai_controller/sapient_npc/get_able_to_run()
	. = ..()
	if(. & AI_UNABLE_TO_RUN)
		return .
	var/mob/living/living_pawn = pawn
	if(IS_UNCONSCIOUS_OR_CRIT(living_pawn) && !(ai_traits & CAN_ACT_WHILE_DEAD))
		return AI_UNABLE_TO_RUN

	var/ignored_incapacitation = NONE
	if(ai_traits & CAN_ACT_IN_STASIS)
		ignored_incapacitation |= INCAPABLE_STASIS
	if(ai_traits & CAN_ACT_WHILE_GRABBED)
		ignored_incapacitation |= INCAPABLE_GRAB
	if(INCAPACITATED_IGNORING(living_pawn, ignored_incapacitation))
		return AI_UNABLE_TO_RUN
	if(ai_traits & PAUSE_DURING_DO_AFTER && LAZYLEN(living_pawn.do_afters))
		return AI_UNABLE_TO_RUN | AI_PREVENT_CANCEL_ACTIONS
	return NONE

/datum/ai_controller/sapient_npc/proc/update_movespeed(mob/living/living_pawn)
	SIGNAL_HANDLER
	movement_delay = living_pawn.cached_multiplicative_slowdown

/** Requests cognition only when no action/request is active and the actor cooldown has elapsed. */
/datum/ai_controller/sapient_npc/proc/request_cognition()
	if(QDELETED(pawn) || blackboard[BB_NPC_ACTION_INTENT])
		return FALSE
	var/datum/component/npc_actor/actor = pawn.GetComponent(/datum/component/npc_actor)
	if(QDELETED(actor) || !actor.cognition_enabled || actor.pending_request_id)
		return FALSE
	if(world.time < actor.next_cognition_time)
		return FALSE
	if(isnull(SSnpc_cognition))
		return apply_cognition_fallback("subsystem_unavailable")
	return SSnpc_cognition.queue_actor(actor, src, actor.requested_priority)

/** Installs a validated intent and wakes the behavior tree without accepting a second concurrent action. */
/datum/ai_controller/sapient_npc/proc/accept_cognition_intent(datum/npc_action_intent/intent)
	if(QDELETED(intent) || blackboard[BB_NPC_ACTION_INTENT] || !intent.context_is_valid())
		return FALSE
	cancel_current_plan()
	set_blackboard_key(BB_NPC_ACTION_INTENT, intent)
	return TRUE

/** Creates a local wait intent so gateway failure never freezes the NPC controller. */
/datum/ai_controller/sapient_npc/proc/apply_cognition_fallback(reason)
	if(QDELETED(pawn) || blackboard[BB_NPC_ACTION_INTENT])
		return FALSE
	var/mob/living/living_pawn = pawn
	var/datum/component/npc_actor/actor = living_pawn.GetComponent(/datum/component/npc_actor)
	if(QDELETED(actor) || living_pawn.client)
		return FALSE
	var/datum/npc_capability_offer/fallback_offer = new(
		"fallback_wait",
		/datum/npc_capability/wait,
		null,
		"deterministic fallback wait",
		null,
	)
	var/datum/npc_action_intent/intent = new(actor, src, fallback_offer, null)
	qdel(fallback_offer)
	if(!accept_cognition_intent(intent))
		qdel(intent)
		return FALSE
	actor.next_cognition_time = world.time + NPC_COGNITION_FALLBACK_WAIT
	return TRUE

/** Records the actual action outcome, clears blackboard tracking, and releases the owned intent. */
/datum/ai_controller/sapient_npc/proc/complete_cognition_intent(datum/npc_action_intent/intent, succeeded)
	if(blackboard[BB_NPC_ACTION_INTENT] != intent)
		return
	intent.finish(succeeded)
	clear_blackboard_key(BB_NPC_ACTION_INTENT)
	var/datum/component/npc_actor/actor = pawn?.GetComponent(/datum/component/npc_actor)
	if(!QDELETED(actor))
		var/outcome = succeeded ? "succeeded" : "failed"
		actor.record_memory(NPC_MEMORY_ACTION_RESULT, "[outcome]: [intent.result_summary || intent.capability.capability_kind]", actor.actor_id, 1)
		actor.state_version++
		if(!succeeded)
			actor.next_cognition_time = world.time
	qdel(intent)

/** True while this controller already owns an accepted physical action. */
/datum/ai_controller/sapient_npc/proc/has_cognition_intent()
	return !isnull(blackboard[BB_NPC_ACTION_INTENT])

/** Admin test template for assigning authored sapient cognition to any living body. */
/datum/admin_ai_template/sapient_npc
	name = "Sapient NPC (Arcadia AI Gateway)"
	controller_type = /datum/ai_controller/sapient_npc
	/// Values gathered before mutating the target.
	var/profile_name
	var/profile_role
	var/profile_biography
	var/profile_culture
	var/profile_speech_style
	var/list/profile_goals = list()
	var/profile_tier = NPC_COGNITION_TIER_L2

/datum/admin_ai_template/sapient_npc/gather_information(mob/living/target, client/user)
	profile_name = tgui_input_text(user, "Authored character name", "Sapient NPC", target.real_name || target.name, max_length = MAX_NAME_LEN)
	if(isnull(profile_name))
		return FALSE
	profile_role = tgui_input_text(user, "Social or professional role", "Sapient NPC", "resident", max_length = 128)
	if(isnull(profile_role))
		return FALSE
	profile_biography = tgui_input_text(user, "Canonical biography", "Sapient NPC", max_length = NPC_COGNITION_MAX_MEMORY_TEXT)
	if(isnull(profile_biography))
		return FALSE
	profile_culture = tgui_input_text(user, "Culture or background; do not infer it from species", "Sapient NPC", max_length = 128)
	if(isnull(profile_culture))
		return FALSE
	profile_speech_style = tgui_input_text(user, "Concise voice and dialogue style", "Sapient NPC", max_length = 256)
	if(isnull(profile_speech_style))
		return FALSE
	var/goals_text = tgui_input_text(user, "Current goals separated by semicolons", "Sapient NPC", max_length = NPC_COGNITION_MAX_MEMORY_TEXT)
	if(isnull(goals_text))
		return FALSE
	profile_goals = length(trim(goals_text)) ? splittext(goals_text, ";") : list()
	var/static/list/tier_choices = list(
		"L1 - lightweight resident" = NPC_COGNITION_TIER_L1,
		"L2 - normal resident" = NPC_COGNITION_TIER_L2,
		"L3 - important character" = NPC_COGNITION_TIER_L3,
	)
	var/tier_choice = tgui_input_list(user, "Cognition detail tier", "Sapient NPC", tier_choices, "L2 - normal resident")
	if(isnull(tier_choice))
		return FALSE
	profile_tier = tier_choices[tier_choice]
	return TRUE

/datum/admin_ai_template/sapient_npc/apply_controller(mob/living/target, client/user)
	if(QDELETED(target))
		to_chat(user, span_warning("Target stopped existing while the NPC profile was being authored."))
		return
	var/datum/component/npc_actor/actor = target.GetComponent(/datum/component/npc_actor)
	if(QDELETED(actor))
		var/datum/npc_actor_profile/new_profile = new(
			profile_name,
			profile_biography,
			profile_role,
			goals = profile_goals,
			culture = profile_culture,
			speech_style = profile_speech_style,
		)
		actor = target.AddComponent(/datum/component/npc_actor, new_profile, profile_tier)
		if(QDELETED(actor))
			qdel(new_profile)
			to_chat(user, span_warning("The selected body rejected the sapient NPC component."))
			return
	else
		actor.profile.identity_name = profile_name
		actor.profile.biography = profile_biography
		actor.profile.role = profile_role
		actor.profile.culture = profile_culture
		actor.profile.speech_style = profile_speech_style
		actor.profile.goals = profile_goals.Copy()
		actor.cognition_tier = profile_tier
		actor.invalidate_session("admin_profile_updated")

	QDEL_NULL(target.ai_controller)
	target.ai_controller = new /datum/ai_controller/sapient_npc(target)
	to_chat(user, span_notice("[target] now uses the sapient NPC controller. It remains paused while a client controls the body."))
