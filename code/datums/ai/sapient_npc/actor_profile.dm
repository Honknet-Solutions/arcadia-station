/**
 * Identity and long-lived narrative state for a sapient NPC.
 *
 * This datum is deliberately independent from body type. A component may keep the same profile
 * while its parent changes species, equipment or controller state.
 */
/datum/npc_actor_profile
	/// Stable in-world name used in cognition payloads.
	var/identity_name
	/// Short canonical biography. It is context, not a model-generated memory.
	var/biography
	/// Social or professional role, kept separate from species and body capabilities.
	var/role
	/// Cultural background that shapes interpretation without being inferred from species.
	var/culture
	/// Education and vocabulary baseline.
	var/education
	/// Concise authored voice guidance for dialogue generation.
	var/speech_style
	/// Persona intentionally shown to strangers and acquaintances.
	var/public_face
	/// Private self-concept used only by the cognition service.
	var/private_self
	/// Personality descriptors supplied by authored content.
	var/list/traits = list()
	/// Values used when weighing conflicting goals.
	var/list/values = list()
	/// Current high-level needs.
	var/list/needs = list()
	/// Current authored or accepted goals.
	var/list/goals = list()
	/// Current emotions; these are state, not permanent personality.
	var/list/emotions = list()
	/// Skills and domains the character can plausibly reason about.
	var/list/competencies = list()
	/// Explicit boundaries on what the character knows or may disclose.
	var/list/knowledge_boundaries = list()
	/// Authored secrets. Cognition may protect or lie about them according to character goals.
	var/list/secrets = list()
	/// Topics or behaviors the character strongly avoids.
	var/list/taboos = list()
	/// Actor ID to owned [/datum/npc_relationship] values.
	var/list/relationships = list()

/datum/npc_actor_profile/New(
	identity_name,
	biography,
	role,
	list/traits,
	list/values,
	list/needs,
	list/goals,
	culture,
	education,
	speech_style,
)
	src.identity_name = identity_name
	src.biography = biography
	src.role = role
	src.culture = culture
	src.education = education
	src.speech_style = speech_style
	if(!isnull(traits))
		src.traits = traits.Copy()
	if(!isnull(values))
		src.values = values.Copy()
	if(!isnull(needs))
		src.needs = needs.Copy()
	if(!isnull(goals))
		src.goals = goals.Copy()

/datum/npc_actor_profile/Destroy(force)
	QDEL_LIST_ASSOC_VAL(relationships)
	traits = null
	values = null
	needs = null
	goals = null
	emotions = null
	competencies = null
	knowledge_boundaries = null
	secrets = null
	taboos = null
	return ..()

/** Returns authored identity data suitable for the private cognition gateway. */
/datum/npc_actor_profile/proc/serialize()
	var/list/serialized_relationships = list()
	for(var/target_actor_id in relationships)
		var/datum/npc_relationship/relationship = relationships[target_actor_id]
		if(!QDELETED(relationship))
			serialized_relationships += list(relationship.serialize())
	return list(
		"name" = identity_name,
		"biography" = biography,
		"role" = role,
		"culture" = culture,
		"education" = education,
		"speech_style" = speech_style,
		"public_face" = public_face,
		"private_self" = private_self,
		"traits" = traits.Copy(),
		"values" = values.Copy(),
		"needs" = needs.Copy(),
		"goals" = goals.Copy(),
		"emotions" = emotions.Copy(),
		"competencies" = competencies.Copy(),
		"knowledge_boundaries" = knowledge_boundaries.Copy(),
		"secrets" = secrets.Copy(),
		"taboos" = taboos.Copy(),
		"relationships" = serialized_relationships,
	)

/** Returns the directed relationship to another actor, creating it only when explicitly requested. */
/datum/npc_actor_profile/proc/get_relationship(target_actor_id, create = FALSE)
	if(!istext(target_actor_id) || !length(target_actor_id))
		return
	var/datum/npc_relationship/relationship = relationships[target_actor_id]
	if(isnull(relationship) && create)
		relationship = new(target_actor_id)
		relationships[target_actor_id] = relationship
	return relationship

/**
 * Multidimensional directed relationship from one NPC actor to another.
 *
 * Values are intentionally independent: affection does not imply trust and fear does not imply respect.
 */
/datum/npc_relationship
	/// Target actor identifier.
	var/target_actor_id
	/// How well the source knows the target.
	var/familiarity = 0
	/// Confidence that the target will act as expected.
	var/trust = 0
	/// Regard for the target's competence or standing.
	var/respect = 0
	/// Perceived threat posed by the target.
	var/fear = 0
	/// Positive personal attachment.
	var/affection = 0
	/// Accumulated hostility or grievance.
	var/resentment = 0
	/// Signed social debt; positive means the source believes it owes the target.
	var/debt = 0
	/// World time of the latest relationship-changing interaction.
	var/last_interaction_time = 0

/datum/npc_relationship/New(target_actor_id)
	src.target_actor_id = target_actor_id

/** Returns the directed relationship without collapsing its dimensions. */
/datum/npc_relationship/proc/serialize()
	return list(
		"target_actor_id" = target_actor_id,
		"familiarity" = familiarity,
		"trust" = trust,
		"respect" = respect,
		"fear" = fear,
		"affection" = affection,
		"resentment" = resentment,
		"debt" = debt,
		"last_interaction_time" = last_interaction_time,
	)

/** A bounded memory record with explicit epistemic type and provenance. */
/datum/npc_memory_entry
	/// One of the NPC_MEMORY_* classifications.
	var/memory_type
	/// Sanitized text describing the remembered information.
	var/content
	/// Actor ID or visible speaker label that supplied the information.
	var/source_identity
	/// Public language name for heard speech, kept separate from memory content.
	var/language
	/// Confidence from 0 to 1. This never converts a belief into a fact automatically.
	var/confidence = 1
	/// World time when the memory was recorded.
	var/recorded_at

/datum/npc_memory_entry/New(memory_type, content, source_identity, confidence = 1, language)
	src.memory_type = memory_type
	src.content = content
	src.source_identity = source_identity
	src.confidence = clamp(confidence, 0, 1)
	src.language = language
	recorded_at = world.time

/** Returns a provider-neutral memory object for context assembly. */
/datum/npc_memory_entry/proc/serialize()
	return list(
		"type" = memory_type,
		"content" = content,
		"source" = source_identity,
		"language" = language,
		"confidence" = confidence,
		"recorded_at" = recorded_at,
	)
