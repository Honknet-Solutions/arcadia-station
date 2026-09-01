/** Minimal owner-controlled action used to verify the normal datum/action path. */
/datum/action/npc_cognition_unit_test
	name = "NPC cognition unit-test action"
	var/triggered = FALSE

/datum/action/npc_cognition_unit_test/Trigger(mob/clicker, trigger_flags)
	. = ..()
	if(!.)
		return FALSE
	triggered = TRUE
	return TRUE

/datum/action/cooldown/npc_cognition_unit_test_targeted
	name = "NPC cognition targeted action"
	click_to_activate = TRUE
	var/atom/received_target

/datum/action/cooldown/npc_cognition_unit_test_targeted/Trigger(mob/clicker, trigger_flags, atom/target)
	received_target = target
	return TRUE

/** Verifies that authored identity survives a humanoid species change. */
/datum/unit_test/npc_actor_species_independent

/datum/unit_test/npc_actor_species_independent/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/npc_actor_profile/profile = new("Rin", "Keeps the district generators alive.", "technician")
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor, profile)
	var/original_actor_id = actor.actor_id
	var/original_state_version = actor.state_version

	npc.set_species(/datum/species/lizard)
	var/list/body_data = actor.body_driver.serialize_body(npc)

	TEST_ASSERT_EQUAL(actor.actor_id, original_actor_id, "Changing species replaced the NPC identity.")
	TEST_ASSERT_EQUAL(actor.profile.identity_name, "Rin", "Changing species rewrote the authored identity.")
	TEST_ASSERT(istype(actor.body_driver, /datum/npc_body_driver/humanoid), "A humanoid species did not retain the humanoid body driver.")
	TEST_ASSERT_EQUAL(body_data["species"], npc.dna.species.name, "The body driver did not read the current datum/species.")
	TEST_ASSERT(length(body_data["physical_attributes"]), "The body snapshot omitted datum/species physical attributes.")
	TEST_ASSERT(length(body_data["understood_languages"]), "The body snapshot omitted understood languages.")
	TEST_ASSERT(actor.state_version > original_state_version, "Changing species did not invalidate the previous body snapshot.")

/** Verifies that the actor component is not restricted to carbon humans. */
/datum/unit_test/npc_actor_generic_living_body

/datum/unit_test/npc_actor_generic_living_body/Run()
	var/mob/living/npc = allocate(/mob/living)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)

	TEST_ASSERT(!QDELETED(actor), "A generic living mob rejected the NPC actor component.")
	TEST_ASSERT(istype(actor.body_driver, /datum/npc_body_driver), "A generic living mob did not receive a body driver.")
	TEST_ASSERT(!istype(actor.body_driver, /datum/npc_body_driver/humanoid), "A non-human body received the humanoid driver.")

/** Verifies that understandable PRE_HEAR speech reaches bounded actor memory without a client. */
/datum/unit_test/npc_actor_hearing_memory

/datum/unit_test/npc_actor_hearing_memory/Run()
	var/mob/living/carbon/human/consistent/listener = allocate(/mob/living/carbon/human/consistent)
	var/mob/living/carbon/human/consistent/speaker = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = listener.AddComponent(/datum/component/npc_actor)
	var/original_state_version = actor.state_version

	SEND_SIGNAL(listener, COMSIG_MOVABLE_PRE_HEAR, list(speaker, /datum/language/common, "The grid is failing."))

	TEST_ASSERT_EQUAL(length(actor.recent_memory), 1, "Heard speech was not recorded in NPC memory.")
	var/datum/npc_memory_entry/memory = actor.recent_memory[1]
	TEST_ASSERT_EQUAL(memory.memory_type, NPC_MEMORY_STATEMENT, "Heard speech received the wrong epistemic classification.")
	TEST_ASSERT_EQUAL(memory.content, "The grid is failing.", "Heard speech content was not preserved.")
	TEST_ASSERT_EQUAL(memory.language, "Galactic Common", "Heard speech omitted its understood language.")
	TEST_ASSERT(actor.state_version > original_state_version, "Heard speech did not invalidate the current decision snapshot.")

/** Verifies O(1) actor coalescing while one cognition request is queued. */
/datum/unit_test/npc_cognition_queue_coalesces

/datum/unit_test/npc_cognition_queue_coalesces/Run()
	TEST_ASSERT(!isnull(SSnpc_cognition), "SSnpc_cognition was unavailable to unit tests.")
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/old_enabled = SSnpc_cognition.enabled
	var/old_l2_enabled = SSnpc_cognition.l2_enabled
	var/old_max_queue_size = SSnpc_cognition.max_queue_size
	var/starting_queue_length = length(SSnpc_cognition.queued_requests)

	SSnpc_cognition.enabled = TRUE
	SSnpc_cognition.l2_enabled = TRUE
	SSnpc_cognition.max_queue_size = max(old_max_queue_size, starting_queue_length + 1)
	var/first_result = SSnpc_cognition.queue_actor(actor, controller, NPC_COGNITION_PRIORITY_BACKGROUND)
	var/first_request_id = actor.pending_request_id
	var/second_result = SSnpc_cognition.queue_actor(actor, controller, NPC_COGNITION_PRIORITY_PLAYER)
	var/second_request_id = actor.pending_request_id
	var/ending_queue_length = length(SSnpc_cognition.queued_requests)
	var/replan_requested = actor.replan_requested

	SSnpc_cognition.invalidate_actor(actor, "unit_test_cleanup")
	SSnpc_cognition.enabled = old_enabled
	SSnpc_cognition.l2_enabled = old_l2_enabled
	SSnpc_cognition.max_queue_size = old_max_queue_size
	qdel(controller)

	TEST_ASSERT(first_result, "The first actor request was not admitted to the queue.")
	TEST_ASSERT(second_result, "A coalesced actor request was reported as rejected.")
	TEST_ASSERT_EQUAL(first_request_id, second_request_id, "Coalescing replaced the actor's pending request.")
	TEST_ASSERT_EQUAL(ending_queue_length, starting_queue_length + 1, "Coalescing created more than one queued request for an actor.")
	TEST_ASSERT(replan_requested, "A coalesced higher-priority event did not request replanning.")

/** Verifies that only an opaque capability ID offered by the server can become an intent. */
/datum/unit_test/npc_cognition_capability_allowlist

/datum/unit_test/npc_cognition_capability_allowlist/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	actor.set_pending_request(request.request_id)
	TEST_ASSERT(request.prepare_for_dispatch(), "A valid request could not build perception and capabilities.")

	var/list/unknown_payload = list(
		"schema_version" = NPC_COGNITION_SCHEMA_VERSION,
		"request_id" = request.request_id,
		"state_version" = request.state_version,
		"capability_id" = "not_server_offered",
	)
	TEST_ASSERT(!request.accept_gateway_payload(unknown_payload), "An unknown capability ID bypassed the server allowlist.")
	TEST_ASSERT_EQUAL(request.resolution_reason, "unknown_capability_id", "The unknown capability rejection reason was incorrect.")

	var/wait_capability_id
	for(var/capability_id in request.capability_offers)
		var/datum/npc_capability_offer/offer = request.capability_offers[capability_id]
		if(offer.capability_kind == NPC_CAPABILITY_WAIT)
			wait_capability_id = capability_id
			break
	TEST_ASSERT(!isnull(wait_capability_id), "The body driver did not offer a safe wait capability.")
	var/list/valid_payload = list(
		"schema_version" = NPC_COGNITION_SCHEMA_VERSION,
		"request_id" = request.request_id,
		"state_version" = request.state_version,
		"capability_id" = wait_capability_id,
	)
	TEST_ASSERT(request.accept_gateway_payload(valid_payload), "A valid server-offered capability was rejected.")
	var/datum/npc_action_intent/accepted_intent = controller.blackboard[BB_NPC_ACTION_INTENT]
	TEST_ASSERT(!QDELETED(accepted_intent), "The accepted capability did not reach the controller blackboard.")

	actor.clear_pending_request(request.request_id, 0)
	controller.complete_cognition_intent(accepted_intent, TRUE)
	qdel(request)
	qdel(controller)

/** Verifies timeout resolution, request cleanup and deterministic fallback. */
/datum/unit_test/npc_cognition_timeout_fallback

/datum/unit_test/npc_cognition_timeout_fallback/Run()
	TEST_ASSERT(!isnull(SSnpc_cognition), "SSnpc_cognition was unavailable to unit tests.")
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	actor.set_pending_request(request.request_id)
	TEST_ASSERT(request.prepare_for_dispatch(), "The timeout test request could not be prepared.")

	SSnpc_cognition.resolve_gameplay_failure(request, "http_timeout", timed_out = TRUE, use_fallback = TRUE)
	var/request_status = request.status
	var/request_resolved = request.gameplay_resolved
	var/pending_request_id = actor.pending_request_id
	var/datum/npc_action_intent/fallback_intent = controller.blackboard[BB_NPC_ACTION_INTENT]
	var/fallback_installed = istype(fallback_intent?.capability, /datum/npc_capability/wait)

	if(!QDELETED(fallback_intent))
		controller.complete_cognition_intent(fallback_intent, TRUE)
	qdel(request)
	qdel(controller)

	TEST_ASSERT(request_resolved, "A timed-out request was not marked gameplay-resolved.")
	TEST_ASSERT_EQUAL(request_status, NPC_COGNITION_REQUEST_TIMED_OUT, "A timed-out request received the wrong lifecycle status.")
	TEST_ASSERT_NULL(pending_request_id, "A timed-out request retained actor queue ownership.")
	TEST_ASSERT(fallback_installed, "A timed-out request did not install the deterministic wait fallback.")

/** Verifies that a response cannot cross an action-relevant actor state change. */
/datum/unit_test/npc_cognition_rejects_stale_state

/datum/unit_test/npc_cognition_rejects_stale_state/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	actor.set_pending_request(request.request_id)
	TEST_ASSERT(request.prepare_for_dispatch(), "The stale-state test request could not be prepared.")
	var/selected_capability_id
	for(var/capability_id in request.capability_offers)
		selected_capability_id = capability_id
		break

	actor.mark_state_changed(NPC_COGNITION_PRIORITY_CRITICAL)
	var/list/response_payload = list(
		"schema_version" = NPC_COGNITION_SCHEMA_VERSION,
		"request_id" = request.request_id,
		"state_version" = request.state_version,
		"capability_id" = selected_capability_id,
	)
	TEST_ASSERT(!request.accept_gateway_payload(response_payload), "A response crossed an actor state-version change.")
	TEST_ASSERT_EQUAL(request.resolution_reason, "stale_context", "A stale actor state produced the wrong rejection reason.")

	actor.clear_pending_request(request.request_id, 0)
	qdel(request)
	qdel(controller)

/** Verifies that a login/control boundary invalidates the previous AI session. */
/datum/unit_test/npc_cognition_rejects_player_takeover

/datum/unit_test/npc_cognition_rejects_player_takeover/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	actor.set_pending_request(request.request_id)
	TEST_ASSERT(request.prepare_for_dispatch(), "The player-takeover test request could not be prepared.")
	var/request_session_epoch = request.session_epoch

	SEND_SIGNAL(npc, COMSIG_MOB_LOGIN)

	TEST_ASSERT(actor.session_epoch > request_session_epoch, "Player login did not advance the NPC control session.")
	TEST_ASSERT(!request.context_is_valid(), "A request remained valid across player body takeover.")
	actor.clear_pending_request(request.request_id, 0)
	qdel(request)
	qdel(controller)

/** Verifies that weak request context rejects a body deleted during async work. */
/datum/unit_test/npc_cognition_rejects_deleted_body

/datum/unit_test/npc_cognition_rejects_deleted_body/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	actor.set_pending_request(request.request_id)
	TEST_ASSERT(request.prepare_for_dispatch(), "The deleted-body test request could not be prepared.")

	qdel(npc)

	TEST_ASSERT(!request.context_is_valid(), "A request retained valid context after its body was deleted.")
	qdel(request)
	qdel(controller)

/** Verifies that richer character context and multidimensional relationships reach cognition unchanged. */
/datum/unit_test/npc_actor_profile_dialogue_context

/datum/unit_test/npc_actor_profile_dialogue_context/Run()
	var/datum/npc_actor_profile/profile = new(
		"Rin",
		"Maintains unreliable district power systems.",
		"technician",
		culture = "Lower-deck mutual aid community",
		education = "Apprenticeship",
		speech_style = "Brief, practical, dry humor",
	)
	profile.public_face = "Calm professional"
	profile.private_self = "Afraid of failing the neighborhood"
	profile.emotions += "worried"
	profile.competencies += "electrical repair"
	profile.knowledge_boundaries += "Does not know command security plans"
	profile.secrets += "The backup transformer is jury-rigged"
	var/datum/npc_relationship/relationship = profile.get_relationship("actor-2", create = TRUE)
	relationship.trust = 0.7
	relationship.fear = 0.2
	var/list/serialized = profile.serialize()

	TEST_ASSERT_EQUAL(serialized["culture"], profile.culture, "Culture was omitted from dialogue context.")
	TEST_ASSERT_EQUAL(serialized["speech_style"], profile.speech_style, "Speech style was omitted from dialogue context.")
	TEST_ASSERT_EQUAL(serialized["emotions"][1], "worried", "Current emotion was omitted from dialogue context.")
	TEST_ASSERT_EQUAL(serialized["relationships"][1]["trust"], 0.7, "Relationship trust was flattened or omitted.")
	TEST_ASSERT_EQUAL(serialized["relationships"][1]["fear"], 0.2, "Relationship fear was flattened or omitted.")
	qdel(profile)

/** Verifies hard capability bounds and that opaque execution data never crosses the gateway boundary. */
/datum/unit_test/npc_cognition_capability_offer_security

/datum/unit_test/npc_cognition_capability_offer_security/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/obj/item/target = allocate(/obj/item)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	for(var/index in 1 to NPC_COGNITION_MAX_CAPABILITIES + 5)
		request.add_capability_offer(
			/datum/npc_capability/world_click,
			target,
			"test capability [index]",
			action_data = list("combat_mode" = TRUE, "secret_server_value" = "must not serialize"),
		)

	TEST_ASSERT_EQUAL(length(request.capability_offers), NPC_COGNITION_MAX_CAPABILITIES, "Capability offer hard limit was exceeded.")
	var/datum/npc_capability_offer/offer = request.capability_offers["cap_1"]
	var/list/serialized = offer.serialize()
	TEST_ASSERT_NULL(serialized["action_data"], "Server execution data leaked into the gateway payload.")
	TEST_ASSERT_NULL(serialized["target_ref"], "A BYOND weakref leaked into the gateway payload.")
	TEST_ASSERT_EQUAL(offer.action_data["secret_server_value"], "must not serialize", "The server lost its opaque execution data.")
	qdel(request)
	qdel(controller)

/** Verifies that accepted action capabilities use ownership and IsAvailable through datum/action.Trigger. */
/datum/unit_test/npc_cognition_owned_action_path

/datum/unit_test/npc_cognition_owned_action_path/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/action/npc_cognition_unit_test/action = new(npc)
	action.Grant(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	actor.set_pending_request(request.request_id)
	request.state_version = actor.state_version
	var/capability_id = request.add_capability_offer(/datum/npc_capability/action, action, "use unit-test action")
	var/list/response_payload = list(
		"schema_version" = NPC_COGNITION_SCHEMA_VERSION,
		"request_id" = request.request_id,
		"state_version" = request.state_version,
		"capability_id" = capability_id,
	)
	TEST_ASSERT(request.accept_gateway_payload(response_payload), "A valid owned action capability was rejected.")
	var/datum/npc_action_intent/intent = controller.blackboard[BB_NPC_ACTION_INTENT]
	TEST_ASSERT(intent.requires_async(), "Player datum/action execution was not assigned to the async lane.")
	TEST_ASSERT(intent.begin(), "The accepted datum/action capability failed current-world revalidation.")
	TEST_ASSERT(action.triggered, "The capability bypassed or failed to reach datum/action.Trigger.")

	actor.clear_pending_request(request.request_id, 0)
	controller.complete_cognition_intent(intent, TRUE)
	qdel(request)
	qdel(action)
	qdel(controller)

/** Verifies that a visible attempted attack becomes urgent subjective memory, not a claimed outcome. */
/datum/unit_test/npc_actor_reacts_to_visible_world_action

/datum/unit_test/npc_actor_reacts_to_visible_world_action/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/observer = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/mob/living/carbon/human/consistent/source = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/obj/item/target = allocate(/obj/item, test_turf)
	var/datum/component/npc_actor/actor = observer.AddComponent(/datum/component/npc_actor)
	source.set_combat_mode(TRUE)
	actor.on_observed_world_click(source, target, list())

	TEST_ASSERT_EQUAL(length(actor.recent_memory), 1, "A visible world action did not reach subjective NPC memory.")
	var/datum/npc_memory_entry/memory = actor.recent_memory[1]
	TEST_ASSERT(findtext(memory.content, "attempted to attack"), "An attempted attack was incorrectly described as a successful outcome.")
	TEST_ASSERT_EQUAL(actor.requested_priority, NPC_COGNITION_PRIORITY_DECISION, "A visible attack did not request timely replanning.")

/** Verifies that damage to the owned body creates a critical cognition event. */
/datum/unit_test/npc_actor_reacts_to_damage

/datum/unit_test/npc_actor_reacts_to_damage/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	SEND_SIGNAL(npc, COMSIG_MOB_AFTER_APPLY_DAMAGE, 10, BRUTE, BODY_ZONE_CHEST, 0, 0, 0, NONE, NORTH, null)

	TEST_ASSERT_EQUAL(length(actor.recent_memory), 1, "Body damage did not create subjective memory.")
	TEST_ASSERT_EQUAL(actor.requested_priority, NPC_COGNITION_PRIORITY_CRITICAL, "Body damage did not request critical cognition.")

/** Verifies authoritative do_after completion is distinct from an attempted action. */
/datum/unit_test/npc_actor_records_do_after_result

/datum/unit_test/npc_actor_records_do_after_result/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)

	SEND_SIGNAL(npc, COMSIG_DO_AFTER_ENDED, TRUE)

	TEST_ASSERT_EQUAL(length(actor.recent_memory), 1, "A completed do_after did not create result memory.")
	var/datum/npc_memory_entry/memory = actor.recent_memory[1]
	TEST_ASSERT_EQUAL(memory.memory_type, NPC_MEMORY_ACTION_RESULT, "A do_after result used the wrong memory type.")
	TEST_ASSERT(findtext(memory.content, "succeeded"), "A successful do_after was not recorded as successful.")

/** Verifies urgent body hazards become subjective memory and trigger replanning. */
/datum/unit_test/npc_actor_reacts_to_fire

/datum/unit_test/npc_actor_reacts_to_fire/Run()
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)

	SEND_SIGNAL(npc, COMSIG_LIVING_IGNITED, npc)

	TEST_ASSERT_EQUAL(length(actor.recent_memory), 1, "Ignition did not create subjective memory.")
	TEST_ASSERT_EQUAL(actor.requested_priority, NPC_COGNITION_PRIORITY_CRITICAL, "Ignition did not request critical cognition.")

/** Verifies a visible sustained action records both its attempt and authoritative outcome. */
/datum/unit_test/npc_actor_reacts_to_visible_do_after

/datum/unit_test/npc_actor_reacts_to_visible_do_after/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/observer = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/mob/living/carbon/human/consistent/source = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/datum/component/npc_actor/actor = observer.AddComponent(/datum/component/npc_actor)
	var/datum/npc_perceived_entity/perceived = new("entity_1", observer, source)
	actor.refresh_observed_world_sources(list(perceived))

	SEND_SIGNAL(source, COMSIG_DO_AFTER_BEGAN)
	SEND_SIGNAL(source, COMSIG_DO_AFTER_ENDED, TRUE)

	TEST_ASSERT_EQUAL(length(actor.recent_memory), 2, "Visible do_after attempt and result were not both recorded.")
	var/datum/npc_memory_entry/result_memory = actor.recent_memory[2]
	TEST_ASSERT(findtext(result_memory.content, "complete"), "Visible successful do_after was not recorded as complete.")
	qdel(perceived)

/** Verifies a real APC provider emits opaque controls and revalidates through its domain adapter. */
/datum/unit_test/npc_cognition_apc_provider

/datum/unit_test/npc_cognition_apc_provider/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, test_turf)
	apc.locked = FALSE
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_cognition_request/request = new(actor, controller, NPC_COGNITION_PRIORITY_DECISION)
	actor.set_pending_request(request.request_id)

	TEST_ASSERT(request.prepare_for_dispatch(), "APC provider request could not be prepared.")
	var/selected_capability_id
	var/expected_state
	for(var/capability_id in request.capability_offers)
		var/datum/npc_capability_offer/offer = request.capability_offers[capability_id]
		if(offer.capability_kind != NPC_CAPABILITY_MACHINE_CONTROL)
			continue
		if(offer.action_data["operation"] != "equipment")
			continue
		selected_capability_id = capability_id
		expected_state = offer.action_data["value"]
		break
	TEST_ASSERT_NOTNULL(selected_capability_id, "The APC did not provide an equipment channel capability.")
	var/expected_effective_state = apc.setsubsystem(expected_state)
	var/list/response_payload = list(
		"schema_version" = NPC_COGNITION_SCHEMA_VERSION,
		"request_id" = request.request_id,
		"state_version" = request.state_version,
		"capability_id" = selected_capability_id,
	)
	TEST_ASSERT(request.accept_gateway_payload(response_payload), "The APC capability was rejected.")
	var/datum/npc_action_intent/intent = controller.blackboard[BB_NPC_ACTION_INTENT]
	TEST_ASSERT(intent.begin(), "The APC capability failed domain revalidation.")
	TEST_ASSERT_EQUAL(apc.equipment, expected_effective_state, "The APC provider bypassed or failed its channel control.")

	actor.clear_pending_request(request.request_id, 0)
	controller.complete_cognition_intent(intent, TRUE)
	qdel(request)
	qdel(controller)

/** Verifies item pickup traverses the real mob ClickOn pipeline. */
/datum/unit_test/npc_cognition_world_click_item

/datum/unit_test/npc_cognition_world_click_item/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/obj/item/stack/sheet/iron/item = allocate(/obj/item/stack/sheet/iron, test_turf)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_capability_offer/offer = new(
		"cap_1",
		/datum/npc_capability/world_click,
		item,
		"pick up iron",
		action_data = list("combat_mode" = FALSE, "modifiers" = list()),
	)
	var/datum/npc_action_intent/intent = new(actor, controller, offer, null)

	TEST_ASSERT(intent.requires_async(), "Player ClickOn was not assigned to the async lane.")
	TEST_ASSERT(intent.begin(), "The item ClickOn capability failed current-world validation.")
	TEST_ASSERT_EQUAL(item.loc, npc, "The NPC ClickOn path did not pick up the real item.")

	qdel(intent)
	qdel(offer)
	qdel(controller)

/** Verifies targeted cooldown actions preserve the server-owned target. */
/datum/unit_test/npc_cognition_targeted_action

/datum/unit_test/npc_cognition_targeted_action/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/obj/item/target = allocate(/obj/item, test_turf)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/action/cooldown/npc_cognition_unit_test_targeted/action = new(npc)
	action.Grant(npc)
	var/datum/npc_capability_offer/offer = new(
		"cap_1",
		/datum/npc_capability/action,
		action,
		"use targeted action",
		secondary_target = target,
	)
	var/datum/npc_action_intent/intent = new(actor, controller, offer, null)

	TEST_ASSERT(intent.begin(), "The targeted action failed current-world validation.")
	TEST_ASSERT_EQUAL(action.received_target, target, "The targeted action did not receive its server-owned target.")

	qdel(intent)
	qdel(offer)
	qdel(action)
	qdel(controller)

/** Verifies a world change invalidates a previously offered inventory action. */
/datum/unit_test/npc_cognition_revalidates_inventory_change

/datum/unit_test/npc_cognition_revalidates_inventory_change/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/obj/item/stack/sheet/iron/item = allocate(/obj/item/stack/sheet/iron, test_turf)
	npc.put_in_hands(item)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_capability_offer/offer = new(
		"cap_1",
		/datum/npc_capability/drop_item,
		item,
		"drop iron",
	)
	var/datum/npc_action_intent/intent = new(actor, controller, offer, null)
	npc.dropItemToGround(item)

	TEST_ASSERT(!intent.begin(), "A stale drop capability ignored the changed active hand.")

	qdel(intent)
	qdel(offer)
	qdel(controller)

/** Verifies generic pulling and stop-pulling use the real living mob API. */
/datum/unit_test/npc_cognition_pull_path

/datum/unit_test/npc_cognition_pull_path/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/obj/item/stack/sheet/iron/item = allocate(/obj/item/stack/sheet/iron, test_turf)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_capability_offer/pull_offer = new("cap_1", /datum/npc_capability/pull, item, "pull iron")
	var/datum/npc_action_intent/pull_intent = new(actor, controller, pull_offer, null)

	TEST_ASSERT(pull_intent.begin(), "The pull capability failed the real living mob path.")
	TEST_ASSERT_EQUAL(npc.pulling, item, "The NPC did not start pulling the server-owned target.")

	var/datum/npc_capability_offer/stop_offer = new("cap_2", /datum/npc_capability/stop_pulling, item, "stop pulling iron")
	var/datum/npc_action_intent/stop_intent = new(actor, controller, stop_offer, null)
	TEST_ASSERT(stop_intent.begin(), "The stop-pulling capability failed the real living mob path.")
	TEST_ASSERT_NULL(npc.pulling, "The NPC retained its pulling target after stop-pulling.")

	qdel(stop_intent)
	qdel(stop_offer)
	qdel(pull_intent)
	qdel(pull_offer)
	qdel(controller)

/** Verifies auto-equip uses the normal inventory slot selection path. */
/datum/unit_test/npc_cognition_equip_path

/datum/unit_test/npc_cognition_equip_path/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	var/mob/living/carbon/human/consistent/npc = allocate(/mob/living/carbon/human/consistent, test_turf)
	var/obj/item/clothing/glasses/glasses = allocate(/obj/item/clothing/glasses, test_turf)
	npc.put_in_hands(glasses)
	var/datum/component/npc_actor/actor = npc.AddComponent(/datum/component/npc_actor)
	var/datum/ai_controller/sapient_npc/controller = new(npc)
	var/datum/npc_capability_offer/offer = new("cap_1", /datum/npc_capability/equip_item, glasses, "equip glasses")
	var/datum/npc_action_intent/intent = new(actor, controller, offer, null)

	TEST_ASSERT(intent.begin(), "The auto-equip capability rejected a wearable held item.")
	TEST_ASSERT_EQUAL(npc.glasses, glasses, "The NPC did not equip the item through the normal slot path.")

	qdel(intent)
	qdel(offer)
	qdel(controller)

// These scenarios require a real initialized map and are part of normal map-test CI.
#define NPC_COGNITION_MAP_TEST(test_path) ##test_path { test_flags = UNIT_TEST_MAP_TEST; }
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_species_independent)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_generic_living_body)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_hearing_memory)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_queue_coalesces)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_capability_allowlist)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_timeout_fallback)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_rejects_stale_state)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_rejects_player_takeover)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_rejects_deleted_body)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_profile_dialogue_context)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_capability_offer_security)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_owned_action_path)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_reacts_to_visible_world_action)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_reacts_to_damage)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_records_do_after_result)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_reacts_to_fire)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_actor_reacts_to_visible_do_after)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_apc_provider)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_world_click_item)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_targeted_action)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_revalidates_inventory_change)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_pull_path)
NPC_COGNITION_MAP_TEST(/datum/unit_test/npc_cognition_equip_path)
#undef NPC_COGNITION_MAP_TEST
