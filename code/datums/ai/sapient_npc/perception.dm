/** A visible entity captured in a bounded cognition snapshot. */
/datum/npc_perceived_entity
	/// Request-local public identifier used in capability descriptions.
	var/perception_id
	/// Weak target reference; the world is revalidated before action execution.
	var/datum/weakref/target_ref
	/// Visible name with markup removed.
	var/visible_name
	/// Coarse category that does not expose server type paths.
	var/category
	/// Tile distance at snapshot time.
	var/distance
	/// Relative cardinal/intercardinal direction at snapshot time.
	var/direction
	/// Coarse visible life state for living targets.
	var/life_state
	/// Current visible humanoid species, kept separate from identity and cultural role.
	var/apparent_species
	/// Stable actor identifier only when the visible mob also owns an NPC actor component.
	var/known_actor_id
	/// Visible item held in the target''s active hand.
	var/apparent_active_item
	/// Visible combat stance for living targets.
	var/combat_mode

/datum/npc_perceived_entity/New(perception_id, mob/living/observer, atom/target)
	src.perception_id = perception_id
	target_ref = WEAKREF(target)
	visible_name = htmlrendertext(html_decode(strip_html_full("[target]", MAX_NAME_LEN)))
	distance = get_dist(observer, target)
	direction = dir2text(get_dir(observer, target))
	if(isliving(target))
		category = "living"
		var/mob/living/living_target = target
		var/datum/component/npc_actor/target_actor = living_target.GetComponent(/datum/component/npc_actor)
		if(!QDELETED(target_actor))
			known_actor_id = target_actor.actor_id
		combat_mode = !!living_target.combat_mode
		var/obj/item/visible_held_item = living_target.get_active_held_item()
		if(!isnull(visible_held_item))
			apparent_active_item = htmlrendertext(html_decode(strip_html_full("[visible_held_item]", MAX_NAME_LEN)))
		if(living_target.stat == DEAD)
			life_state = "dead"
		else if(IS_UNCONSCIOUS_OR_CRIT(living_target))
			life_state = "incapacitated"
		else
			life_state = "conscious"
		if(ishuman(living_target))
			var/mob/living/carbon/human/humanoid_target = living_target
			apparent_species = humanoid_target.dna?.species?.name
	else if(isitem(target))
		category = "item"
	else if(isobj(target))
		category = "object"
	else
		category = "environment"

/** Returns visible-only data. The weak target reference is intentionally omitted. */
/datum/npc_perceived_entity/proc/serialize()
	return list(
		"id" = perception_id,
		"name" = visible_name,
		"category" = category,
		"distance" = distance,
		"direction" = direction,
		"life_state" = life_state,
		"apparent_species" = apparent_species,
		"known_actor_id" = known_actor_id,
		"active_item" = apparent_active_item,
		"combat_mode" = combat_mode,
	)

/**
 * Immutable, bounded perception captured immediately before HTTP dispatch.
 *
 * Building at dispatch avoids wasting view work on requests that expire in the queue and minimizes
 * the time between observing the world and assigning its state_version.
 */
/datum/npc_perception_snapshot
	/// World time at which the snapshot was captured.
	var/captured_at
	/// Actor state version paired with this perception.
	var/state_version
	/// Provider-neutral self description.
	var/list/self_data
	/// Owned bounded list of [/datum/npc_perceived_entity] values.
	var/list/perceived_entities = list()
	/// Serialized copy of recent memory at capture time.
	var/list/recent_memory = list()
	/// Serialized active dialogue turns at capture time.
	var/list/conversation_history = list()

/datum/npc_perception_snapshot/New(datum/component/npc_actor/actor)
	var/mob/living/body = actor?.parent
	if(QDELETED(body))
		return
	captured_at = world.time
	state_version = actor.state_version
	self_data = actor.body_driver.serialize_body(body)
	recent_memory = actor.serialize_recent_memory()
	conversation_history = actor.serialize_conversation_history()
	var/entity_index = 0
	for(var/atom/visible_atom as anything in view(NPC_COGNITION_VIEW_RANGE, body))
		if(visible_atom == body || isturf(visible_atom))
			continue
		if(!CAN_SEE_RANGED(visible_atom, body, NPC_COGNITION_VIEW_RANGE))
			continue
		entity_index++
		perceived_entities += new /datum/npc_perceived_entity("entity_[entity_index]", body, visible_atom)
		if(entity_index >= NPC_COGNITION_MAX_VISIBLE_ENTITIES)
			break
	actor.refresh_observed_world_sources(perceived_entities)

/datum/npc_perception_snapshot/Destroy(force)
	QDEL_LIST(perceived_entities)
	self_data = null
	recent_memory = null
	conversation_history = null
	return ..()

/** Returns the JSON-compatible perception boundary sent to the private gateway. */
/datum/npc_perception_snapshot/proc/serialize()
	var/list/entities = list()
	for(var/datum/npc_perceived_entity/perceived as anything in perceived_entities)
		entities += list(perceived.serialize())
	return list(
		"captured_at" = captured_at,
		"state_version" = state_version,
		"self" = self_data.Copy(),
		"visible_entities" = entities,
		"recent_memory" = recent_memory.Copy(),
		"conversation_history" = conversation_history.Copy(),
	)
