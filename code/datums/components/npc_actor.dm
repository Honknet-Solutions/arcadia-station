/**
 * Body-independent identity, memory and cognition versioning for a sapient NPC.
 *
 * The component survives AI controller replacement while its body exists. Outbound requests keep
 * only weak references to it, so deleting a body cannot strand a hard-reference cycle.
 */
/datum/component/npc_actor
	dupe_mode = COMPONENT_DUPE_HIGHLANDER

	/// Stable identifier used for memory relationships and request coalescing.
	var/actor_id
	/// Owned authored identity and narrative state.
	var/datum/npc_actor_profile/profile
	/// Owned adapter that describes and operates the current body without defining personality.
	var/datum/npc_body_driver/body_driver
	/// Cognition detail tier; L0 is entirely deterministic and local.
	var/cognition_tier = NPC_COGNITION_TIER_L2
	/// Monotonic version of action-relevant state included in each gateway request.
	var/state_version = 1
	/// Monotonic control session version used to reject replies after takeover or controller replacement.
	var/session_epoch = 1
	/// Bounded owned list of [/datum/npc_memory_entry] values.
	var/list/recent_memory = list()
	/// Bounded active-scene dialogue history kept distinct from general episodic memory.
	var/list/conversation_history = list()
	/// Request ID currently queued or in flight for this actor.
	var/pending_request_id
	/// Earliest world time at which background cognition may be queued.
	var/next_cognition_time = 0
	/// Highest urgency accumulated while an older request or action was active.
	var/requested_priority = NPC_COGNITION_PRIORITY_BACKGROUND
	/// TRUE when new information arrived after a request snapshot was captured.
	var/replan_requested = FALSE
	/// Allows authored content to pause cognition without removing identity or memory.
	var/cognition_enabled = TRUE
	/// Source REF to weak source reference for nearby mobs whose visible clicks are being observed.
	var/list/observed_world_sources = list()

/datum/component/npc_actor/Initialize(datum/npc_actor_profile/profile, cognition_tier = NPC_COGNITION_TIER_L2)
	. = ..()
	if(!isliving(parent))
		return COMPONENT_INCOMPATIBLE

	var/mob/living/living_parent = parent
	actor_id = GUID()
	src.profile = profile || new /datum/npc_actor_profile()
	src.cognition_tier = clamp(cognition_tier, NPC_COGNITION_TIER_L0, NPC_COGNITION_TIER_L3)
	body_driver = create_npc_body_driver(living_parent)
	if(isnull(body_driver))
		return COMPONENT_INCOMPATIBLE
	if(!src.profile.identity_name)
		src.profile.identity_name = living_parent.real_name || living_parent.name
	if(!src.profile.role)
		src.profile.role = body_driver.describe_role(living_parent)

/datum/component/npc_actor/RegisterWithParent()
	RegisterSignal(parent, COMSIG_MOVABLE_PRE_HEAR, PROC_REF(on_hear))
	RegisterSignals(parent, list(COMSIG_MOB_LOGIN, COMSIG_MOB_LOGOUT), PROC_REF(on_control_changed))
	RegisterSignal(parent, COMSIG_SPECIES_GAIN, PROC_REF(on_species_changed))
	RegisterSignal(parent, COMSIG_MOB_AFTER_APPLY_DAMAGE, PROC_REF(on_body_damaged))
	RegisterSignal(parent, COMSIG_LIVING_DEATH, PROC_REF(on_body_died))
	RegisterSignals(parent, list(COMSIG_MOB_EQUIPPED_ITEM, COMSIG_MOB_UNEQUIPPED_ITEM, COMSIG_LIVING_RESTING), PROC_REF(on_body_state_changed))
	RegisterSignal(parent, COMSIG_MOB_STATCHANGE, PROC_REF(on_body_stat_changed))
	RegisterSignal(parent, COMSIG_LIVING_IGNITED, PROC_REF(on_body_ignited))
	RegisterSignal(parent, COMSIG_LIVING_EXTINGUISHED, PROC_REF(on_body_extinguished))
	RegisterSignal(parent, COMSIG_LIVING_SET_BUCKLED, PROC_REF(on_body_buckled))
	RegisterSignals(parent, list(SIGNAL_ADDTRAIT(TRAIT_RESTRAINED), SIGNAL_REMOVETRAIT(TRAIT_RESTRAINED)), PROC_REF(on_body_restrained_changed))
	RegisterSignal(parent, COMSIG_LIVING_GET_PULLED, PROC_REF(on_body_pulled))
	RegisterSignal(parent, COMSIG_DO_AFTER_ENDED, PROC_REF(on_body_do_after_ended))

/datum/component/npc_actor/UnregisterFromParent()
	stop_observing_world_sources()
	UnregisterSignal(parent, list(
		COMSIG_MOVABLE_PRE_HEAR,
		COMSIG_MOB_LOGIN,
		COMSIG_MOB_LOGOUT,
		COMSIG_SPECIES_GAIN,
		COMSIG_MOB_AFTER_APPLY_DAMAGE,
		COMSIG_LIVING_DEATH,
		COMSIG_MOB_EQUIPPED_ITEM,
		COMSIG_MOB_UNEQUIPPED_ITEM,
		COMSIG_LIVING_RESTING,
		COMSIG_MOB_STATCHANGE,
		COMSIG_LIVING_IGNITED,
		COMSIG_LIVING_EXTINGUISHED,
		COMSIG_LIVING_SET_BUCKLED,
		SIGNAL_ADDTRAIT(TRAIT_RESTRAINED),
		SIGNAL_REMOVETRAIT(TRAIT_RESTRAINED),
		COMSIG_LIVING_GET_PULLED,
		COMSIG_DO_AFTER_ENDED,
	))

/datum/component/npc_actor/Destroy(force)
	if(!isnull(SSnpc_cognition))
		SSnpc_cognition.invalidate_actor(src, "actor_deleted")
	QDEL_NULL(profile)
	QDEL_NULL(body_driver)
	QDEL_LIST(recent_memory)
	QDEL_LIST(conversation_history)
	. = ..()
	observed_world_sources = null
	return .

/** Increments state and requests a fresh decision without directly interrupting a running physical action. */
/datum/component/npc_actor/proc/mark_state_changed(priority = NPC_COGNITION_PRIORITY_DECISION)
	state_version++
	replan_requested = TRUE
	requested_priority = min(requested_priority, clamp(priority, NPC_COGNITION_PRIORITY_CRITICAL, NPC_COGNITION_PRIORITY_BACKGROUND))
	next_cognition_time = min(next_cognition_time, world.time)

/** Invalidates every response from the previous controller or player-control session. */
/datum/component/npc_actor/proc/invalidate_session(reason)
	session_epoch++
	state_version++
	replan_requested = TRUE
	next_cognition_time = world.time
	if(!isnull(SSnpc_cognition))
		SSnpc_cognition.invalidate_actor(src, reason)

/** Records a bounded, sanitized memory while preserving its epistemic classification. */
/datum/component/npc_actor/proc/record_memory(memory_type, content, source_identity, confidence = 1, language)
	if(!istext(content))
		return
	var/clean_content = htmlrendertext(html_decode(strip_html_full(html_decode(content), NPC_COGNITION_MAX_MEMORY_TEXT)))
	if(!length(clean_content))
		return
	var/clean_source = istext(source_identity) ? htmlrendertext(html_decode(strip_html_full(html_decode(source_identity), MAX_NAME_LEN))) : null
	var/clean_language = istext(language) ? htmlrendertext(html_decode(strip_html_full(html_decode(language), MAX_NAME_LEN))) : null
	recent_memory += new /datum/npc_memory_entry(memory_type, clean_content, clean_source, confidence, clean_language)
	while(length(recent_memory) > NPC_COGNITION_MAX_RECENT_MEMORY)
		var/datum/npc_memory_entry/expired_memory = popleft(recent_memory)
		qdel(expired_memory)

/** Returns only the newest bounded memory entries for gateway context. */
/datum/component/npc_actor/proc/serialize_recent_memory(limit = NPC_COGNITION_MAX_CONTEXT_MEMORY)
	var/list/serialized = list()
	if(!length(recent_memory))
		return serialized
	var/start_index = max(1, length(recent_memory) - limit + 1)
	for(var/index in start_index to length(recent_memory))
		var/datum/npc_memory_entry/memory = recent_memory[index]
		serialized += list(memory.serialize())
	return serialized

/** Records one active-scene dialogue turn without promoting it to canonical knowledge. */
/datum/component/npc_actor/proc/record_conversation_turn(content, source_identity, language)
	if(!istext(content))
		return
	var/clean_content = htmlrendertext(html_decode(strip_html_full(html_decode(content), NPC_COGNITION_MAX_MEMORY_TEXT)))
	if(!length(clean_content))
		return
	conversation_history += new /datum/npc_memory_entry(
		NPC_MEMORY_EPISODIC,
		clean_content,
		source_identity,
		1,
		language,
	)
	while(length(conversation_history) > NPC_COGNITION_MAX_CONVERSATION_TURNS)
		var/datum/npc_memory_entry/expired_turn = popleft(conversation_history)
		qdel(expired_turn)

/** Returns a provider-safe copy of the bounded active dialogue. */
/datum/component/npc_actor/proc/serialize_conversation_history()
	var/list/serialized = list()
	for(var/datum/npc_memory_entry/turn as anything in conversation_history)
		serialized += list(turn.serialize())
	return serialized

/** Marks the component as owning a queued or in-flight request. */
/datum/component/npc_actor/proc/set_pending_request(request_id)
	pending_request_id = request_id
	replan_requested = FALSE
	requested_priority = NPC_COGNITION_PRIORITY_BACKGROUND

/** Clears request ownership only when the completing request is still current. */
/datum/component/npc_actor/proc/clear_pending_request(request_id, request_cooldown)
	if(pending_request_id != request_id)
		return FALSE
	pending_request_id = null
	if(replan_requested)
		next_cognition_time = world.time
	else
		next_cognition_time = world.time + request_cooldown
	return TRUE

/** Captures understandable speech before the client-only Hear() path exits for an NPC. */
/datum/component/npc_actor/proc/on_hear(datum/source, list/hearing_args)
	SIGNAL_HANDLER
	var/mob/living/listener = parent
	var/atom/movable/speaker = hearing_args[HEARING_SPEAKER]
	if(speaker == listener || HAS_TRAIT(listener, TRAIT_DEAF))
		return
	var/datum/language/message_language = hearing_args[HEARING_LANGUAGE]
	if(message_language && !listener.has_language(message_language, UNDERSTOOD_LANGUAGE))
		return
	var/raw_message = hearing_args[HEARING_RAW_MESSAGE]
	if(!istext(raw_message) || !length(raw_message))
		return
	var/datum/language/language_datum = GLOB.language_datum_instances[message_language]
	record_memory(NPC_MEMORY_STATEMENT, raw_message, "[speaker]", 1, language_datum?.name)
	record_conversation_turn(raw_message, "[speaker]", language_datum?.name)
	var/mob/speaker_mob = speaker
	var/priority = istype(speaker_mob) && GET_CLIENT(speaker_mob) ? NPC_COGNITION_PRIORITY_PLAYER : NPC_COGNITION_PRIORITY_DECISION
	mark_state_changed(priority)

/** Rejects responses across player login/logout boundaries without removing the actor's identity. */
/datum/component/npc_actor/proc/on_control_changed(datum/source)
	SIGNAL_HANDLER
	invalidate_session("control_changed")

/** Invalidates a decision captured before a humanoid body gained a different species. */
/datum/component/npc_actor/proc/on_species_changed(datum/source)
	SIGNAL_HANDLER
	mark_state_changed(NPC_COGNITION_PRIORITY_DECISION)

/** Keeps event subscriptions bounded to living sources present in the latest perception snapshot. */
/datum/component/npc_actor/proc/refresh_observed_world_sources(list/perceived_entities)
	stop_observing_world_sources()
	for(var/datum/npc_perceived_entity/perceived as anything in perceived_entities)
		var/mob/living/source = perceived.target_ref?.resolve()
		if(QDELETED(source) || source == parent)
			continue
		RegisterSignal(source, COMSIG_MOB_CLICKON, PROC_REF(on_observed_world_click))
		RegisterSignals(source, list(
			COMSIG_MOB_EQUIPPED_ITEM,
			COMSIG_MOB_UNEQUIPPED_ITEM,
			COMSIG_MOB_DROPPED_ITEM,
			COMSIG_LIVING_PICKED_UP_ITEM,
		), PROC_REF(on_observed_inventory_changed))
		RegisterSignal(source, COMSIG_LIVING_IGNITED, PROC_REF(on_observed_ignited))
		RegisterSignal(source, COMSIG_LIVING_EXTINGUISHED, PROC_REF(on_observed_extinguished))
		RegisterSignal(source, COMSIG_LIVING_SET_BUCKLED, PROC_REF(on_observed_buckled))
		RegisterSignal(source, COMSIG_MOB_STATCHANGE, PROC_REF(on_observed_stat_changed))
		RegisterSignal(source, COMSIG_LIVING_START_PULL, PROC_REF(on_observed_started_pulling))
		RegisterSignal(source, COMSIG_DO_AFTER_BEGAN, PROC_REF(on_observed_do_after_began))
		RegisterSignal(source, COMSIG_DO_AFTER_ENDED, PROC_REF(on_observed_do_after_ended))
		observed_world_sources[REF(source)] = WEAKREF(source)

/** Releases cross-mob signal registrations without retaining hard references to observed bodies. */
/datum/component/npc_actor/proc/stop_observing_world_sources()
	if(!length(observed_world_sources))
		return
	for(var/source_ref in observed_world_sources)
		var/datum/weakref/source_weakref = observed_world_sources[source_ref]
		var/mob/living/source = source_weakref?.resolve()
		if(!QDELETED(source))
			UnregisterSignal(source, list(
				COMSIG_MOB_CLICKON,
				COMSIG_MOB_EQUIPPED_ITEM,
				COMSIG_MOB_UNEQUIPPED_ITEM,
				COMSIG_MOB_DROPPED_ITEM,
				COMSIG_LIVING_PICKED_UP_ITEM,
				COMSIG_LIVING_IGNITED,
				COMSIG_LIVING_EXTINGUISHED,
				COMSIG_LIVING_SET_BUCKLED,
				COMSIG_MOB_STATCHANGE,
				COMSIG_LIVING_START_PULL,
				COMSIG_DO_AFTER_BEGAN,
				COMSIG_DO_AFTER_ENDED,
			))
	observed_world_sources.Cut()

/** Records one currently visible source event and updates a known actor relationship. */
/datum/component/npc_actor/proc/record_observed_event(mob/living/source, description, priority = NPC_COGNITION_PRIORITY_DECISION)
	var/mob/living/observer = parent
	if(QDELETED(observer) || QDELETED(source) || get_dist(observer, source) > NPC_COGNITION_VIEW_RANGE)
		return FALSE
	if(!CAN_SEE_RANGED(source, observer, NPC_COGNITION_VIEW_RANGE))
		return FALSE
	var/source_name = htmlrendertext(html_decode(strip_html_full("[source]", MAX_NAME_LEN)))
	record_memory(NPC_MEMORY_EPISODIC, description, source_name, 1)
	var/datum/component/npc_actor/source_actor = source.GetComponent(/datum/component/npc_actor)
	if(!QDELETED(source_actor))
		var/datum/npc_relationship/relationship = profile.get_relationship(source_actor.actor_id, create = TRUE)
		relationship.familiarity = min(1, relationship.familiarity + 0.01)
		relationship.last_interaction_time = world.time
	mark_state_changed(source.client ? NPC_COGNITION_PRIORITY_PLAYER : priority)
	return TRUE

/** Records a visible attempted player-style interaction so the next decision may react to it. */
/datum/component/npc_actor/proc/on_observed_world_click(mob/living/source, atom/target, list/modifiers)
	SIGNAL_HANDLER
	if(QDELETED(target))
		return

	var/action_description = "interacted with"
	if(LAZYACCESS(modifiers, SHIFT_CLICK))
		action_description = "examined"
	else if(source.combat_mode)
		action_description = "attempted to attack"
	else
		var/obj/item/active_item = source.get_active_held_item()
		if(!isnull(active_item))
			action_description = "used [active_item] on"

	var/source_name = htmlrendertext(html_decode(strip_html_full("[source]", MAX_NAME_LEN)))
	var/target_name = htmlrendertext(html_decode(strip_html_full("[target]", MAX_NAME_LEN)))
	record_observed_event(source, "Saw [source_name] [action_description] [target_name].")

/datum/component/npc_actor/proc/on_observed_inventory_changed(mob/living/source, obj/item/item)
	SIGNAL_HANDLER
	var/item_name = QDELETED(item) ? "an item" : "[item]"
	record_observed_event(source, "Saw [source] change carried equipment involving [item_name].")

/datum/component/npc_actor/proc/on_observed_ignited(mob/living/source)
	SIGNAL_HANDLER
	record_observed_event(source, "Saw [source] catch fire.", NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_observed_extinguished(mob/living/source)
	SIGNAL_HANDLER
	record_observed_event(source, "Saw the fire on [source] go out.")

/datum/component/npc_actor/proc/on_observed_buckled(mob/living/source, atom/movable/new_buckled)
	SIGNAL_HANDLER
	var/description = new_buckled ? "Saw [source] become buckled to [new_buckled]." : "Saw [source] become unbuckled."
	record_observed_event(source, description)

/datum/component/npc_actor/proc/on_observed_stat_changed(mob/living/source, new_stat, old_stat)
	SIGNAL_HANDLER
	if(new_stat == old_stat)
		return
	var/description
	if(new_stat == DEAD)
		description = "Saw [source] die."
	else if(new_stat >= SOFT_CRIT && new_stat < DEAD)
		description = "Saw [source] lose consciousness."
	else if(old_stat >= SOFT_CRIT && new_stat < SOFT_CRIT)
		description = "Saw [source] regain consciousness."
	if(description)
		record_observed_event(source, description, NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_observed_started_pulling(mob/living/source, atom/movable/pulled)
	SIGNAL_HANDLER
	if(!QDELETED(pulled))
		record_observed_event(source, "Saw [source] start pulling [pulled].")

/datum/component/npc_actor/proc/on_observed_do_after_began(mob/living/source)
	SIGNAL_HANDLER
	record_observed_event(source, "Saw [source] begin a sustained action.")

/datum/component/npc_actor/proc/on_observed_do_after_ended(mob/living/source, succeeded)
	SIGNAL_HANDLER
	var/outcome = succeeded ? "complete" : "be interrupted during"
	record_observed_event(source, "Saw [source] [outcome] a sustained action.")

/** Body damage is an urgent subjective event even when its attacker is not directly identifiable. */
/datum/component/npc_actor/proc/on_body_damaged(
	datum/source,
	damage,
	damage_type,
	def_zone,
	blocked,
	wound_bonus,
	exposed_wound_bonus,
	sharpness,
	attack_direction,
	obj/item/attacking_item,
)
	SIGNAL_HANDLER
	if(isnum(damage) && damage > 0)
		var/tool_context = attacking_item ? " from [attacking_item]" : ""
		record_memory(NPC_MEMORY_EPISODIC, "I was hurt[tool_context].", actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_body_died(datum/source)
	SIGNAL_HANDLER
	record_memory(NPC_MEMORY_EPISODIC, "I died.", actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_body_state_changed(datum/source)
	SIGNAL_HANDLER
	mark_state_changed(NPC_COGNITION_PRIORITY_DECISION)

/datum/component/npc_actor/proc/on_body_stat_changed(datum/source, new_stat, old_stat)
	SIGNAL_HANDLER
	if(new_stat == old_stat)
		return
	if(new_stat >= SOFT_CRIT && new_stat < DEAD)
		record_memory(NPC_MEMORY_EPISODIC, "I lost consciousness.", actor_id, 1)
	else if(old_stat >= SOFT_CRIT && new_stat < SOFT_CRIT)
		record_memory(NPC_MEMORY_EPISODIC, "I regained consciousness.", actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_body_ignited(datum/source)
	SIGNAL_HANDLER
	record_memory(NPC_MEMORY_EPISODIC, "I caught fire.", actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_body_extinguished(datum/source)
	SIGNAL_HANDLER
	record_memory(NPC_MEMORY_EPISODIC, "The fire on me went out.", actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_DECISION)

/datum/component/npc_actor/proc/on_body_buckled(datum/source, atom/movable/new_buckled)
	SIGNAL_HANDLER
	var/description = new_buckled ? "I became buckled to [new_buckled]." : "I became unbuckled."
	record_memory(NPC_MEMORY_EPISODIC, description, actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_body_restrained_changed(datum/source)
	SIGNAL_HANDLER
	var/mob/living/body = parent
	var/description = HAS_TRAIT(body, TRAIT_RESTRAINED) ? "I became restrained." : "I was released from restraints."
	record_memory(NPC_MEMORY_EPISODIC, description, actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_body_pulled(datum/source, mob/living/puller)
	SIGNAL_HANDLER
	if(!QDELETED(puller))
		record_memory(NPC_MEMORY_EPISODIC, "[puller] started pulling me.", "[puller]", 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)

/datum/component/npc_actor/proc/on_body_do_after_ended(datum/source, succeeded)
	SIGNAL_HANDLER
	var/outcome = succeeded ? "succeeded" : "was interrupted"
	record_memory(NPC_MEMORY_ACTION_RESULT, "A sustained action [outcome].", actor_id, 1)
	mark_state_changed(NPC_COGNITION_PRIORITY_DECISION)
