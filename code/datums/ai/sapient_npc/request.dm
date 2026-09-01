/**
 * One asynchronous cognition request owned by SSnpc_cognition.
 *
 * The request captures weak game references, a state version, a control epoch and a one-time
 * capability allowlist. It may outlive gameplay timeout only to drain its native rust-g job safely.
 */
/datum/npc_cognition_request
	/// Globally unique correlation ID echoed by the gateway.
	var/request_id
	/// Stable actor ID used for queue coalescing and metadata-only traces.
	var/actor_id
	/// Weak actor component reference.
	var/datum/weakref/actor_ref
	/// Weak controller reference captured at enqueue.
	var/datum/weakref/controller_ref
	/// Weak body reference captured at enqueue.
	var/datum/weakref/pawn_ref
	/// Scheduling priority; lower values are more urgent.
	var/priority
	/// World time when the request entered the queue.
	var/enqueued_at
	/// World time when HTTP dispatch began.
	var/dispatched_at
	/// World time after which gameplay selects fallback even if rust-g is still draining.
	var/response_deadline
	/// State version paired with the dispatch-time perception snapshot.
	var/state_version
	/// Control epoch paired with the request.
	var/session_epoch
	/// One of NPC_COGNITION_REQUEST_*.
	var/status = NPC_COGNITION_REQUEST_QUEUED
	/// TRUE after intent or fallback has been selected; late native responses are discarded.
	var/gameplay_resolved = FALSE
	/// Metadata-only reason used for diagnostics and tests.
	var/resolution_reason
	/// Owned dispatch-time perception.
	var/datum/npc_perception_snapshot/perception
	/// Owned associative list capability ID to [/datum/npc_capability_offer].
	var/list/capability_offers = list()
	/// Owned rust-g request while in flight.
	var/datum/http_request/http_request

/datum/npc_cognition_request/New(datum/component/npc_actor/actor, datum/ai_controller/sapient_npc/controller, priority)
	request_id = GUID()
	actor_id = actor.actor_id
	actor_ref = WEAKREF(actor)
	controller_ref = WEAKREF(controller)
	pawn_ref = WEAKREF(controller.pawn)
	src.priority = clamp(priority, NPC_COGNITION_PRIORITY_CRITICAL, NPC_COGNITION_PRIORITY_BACKGROUND)
	enqueued_at = world.time
	session_epoch = actor.session_epoch

/datum/npc_cognition_request/Destroy(force)
	QDEL_NULL(perception)
	QDEL_LIST_ASSOC_VAL(capability_offers)
	if(http_request?.in_progress)
		stack_trace("NPC cognition request [request_id] was deleted before its rust-g HTTP job drained.")
		http_request = null
	else
		QDEL_NULL(http_request)
	actor_ref = null
	controller_ref = null
	pawn_ref = null
	return ..()

/** Validates weak ownership and optionally the state/pending request versions. */
/datum/npc_cognition_request/proc/context_is_valid(require_state_version = FALSE, require_pending_request = FALSE)
	var/datum/component/npc_actor/actor = actor_ref?.resolve()
	var/datum/ai_controller/sapient_npc/controller = controller_ref?.resolve()
	var/mob/living/body = pawn_ref?.resolve()
	if(QDELETED(actor) || QDELETED(controller) || QDELETED(body))
		return FALSE
	if(actor.actor_id != actor_id || actor.parent != body)
		return FALSE
	if(controller.pawn != body || body.ai_controller != controller || body.client)
		return FALSE
	if(!actor.cognition_enabled || actor.session_epoch != session_epoch)
		return FALSE
	if(require_state_version && actor.state_version != state_version)
		return FALSE
	if(require_pending_request && actor.pending_request_id != request_id)
		return FALSE
	return TRUE

/** Captures fresh perception and the capability allowlist immediately before dispatch. */
/datum/npc_cognition_request/proc/prepare_for_dispatch()
	if(!context_is_valid(require_pending_request = TRUE))
		resolution_reason = "invalid_context_before_dispatch"
		return FALSE
	var/datum/component/npc_actor/actor = actor_ref.resolve()
	state_version = actor.state_version
	session_epoch = actor.session_epoch
	perception = new(actor)
	actor.body_driver.build_capability_offers(src, perception)
	if(!length(capability_offers))
		resolution_reason = "no_capabilities"
		return FALSE
	return TRUE

/** Returns TRUE once no more actions may be added to this bounded request. */
/datum/npc_cognition_request/proc/capability_limit_reached()
	return length(capability_offers) >= NPC_COGNITION_MAX_CAPABILITIES

/** Adds one server-selected capability with an opaque request-local ID. */
/datum/npc_cognition_request/proc/add_capability_offer(
	datum/npc_capability/capability_type,
	datum/target,
	description,
	target_label,
	list/action_data,
	datum/secondary_target,
)
	if(capability_limit_reached() || !ispath(capability_type, /datum/npc_capability))
		return
	var/clean_description = htmlrendertext(html_decode(strip_html_full("[description]", NPC_COGNITION_MAX_MEMORY_TEXT)))
	if(!length(clean_description))
		return
	var/capability_id = "cap_[length(capability_offers) + 1]"
	capability_offers[capability_id] = new /datum/npc_capability_offer(
		capability_id,
		capability_type,
		target,
		clean_description,
		target_label,
		action_data,
		secondary_target,
	)
	return capability_id

/** Returns the provider-neutral JSON payload. */
/datum/npc_cognition_request/proc/build_payload()
	var/datum/component/npc_actor/actor = actor_ref?.resolve()
	if(QDELETED(actor) || isnull(perception))
		return null
	var/list/serialized_capabilities = list()
	for(var/capability_id in capability_offers)
		var/datum/npc_capability_offer/offer = capability_offers[capability_id]
		serialized_capabilities += list(offer.serialize())
	return list(
		"schema_version" = NPC_COGNITION_SCHEMA_VERSION,
		"request_id" = request_id,
		"actor_id" = actor_id,
		"state_version" = state_version,
		"session_epoch" = session_epoch,
		"tier" = actor.cognition_tier,
		"identity" = actor.profile.serialize(),
		"perception" = perception.serialize(),
		"capabilities" = serialized_capabilities,
	)

/** Starts the only native HTTP job owned by this request. */
/datum/npc_cognition_request/proc/start_http(gateway_url, gateway_token, timeout_seconds)
	var/list/payload = build_payload()
	if(isnull(payload))
		resolution_reason = "payload_build_failed"
		return FALSE
	var/list/headers = list("Content-Type" = "application/json")
	if(length(gateway_token))
		headers["Authorization"] = "Bearer [gateway_token]"
	http_request = new()
	http_request.prepare(
		RUSTG_HTTP_METHOD_POST,
		gateway_url,
		json_encode(payload),
		headers,
		timeout_seconds = timeout_seconds,
	)
	http_request.begin_async()
	dispatched_at = world.time
	response_deadline = world.time + timeout_seconds SECONDS
	status = NPC_COGNITION_REQUEST_IN_FLIGHT
	return TRUE

/** Polls rust-g without sleeping. */
/datum/npc_cognition_request/proc/http_is_complete()
	return isnull(http_request) || http_request.is_complete()

/** Consumes the completed rust-g response exactly once. */
/datum/npc_cognition_request/proc/consume_http_response()
	if(isnull(http_request) || http_request.in_progress)
		return null
	return http_request.into_response()

/**
 * Validates a decoded gateway response and queues its server-owned action intent.
 *
 * No target, type path or arbitrary action argument is read from the response. The selected ID
 * must resolve inside this request's allowlist and the current world is checked again by capability execution.
 */
/datum/npc_cognition_request/proc/accept_gateway_payload(list/response_payload)
	if(gameplay_resolved || !islist(response_payload))
		resolution_reason = "invalid_response_shape"
		return FALSE
	if(!context_is_valid(require_state_version = TRUE, require_pending_request = TRUE))
		resolution_reason = "stale_context"
		return FALSE
	if(response_payload["schema_version"] != NPC_COGNITION_SCHEMA_VERSION)
		resolution_reason = "schema_version_mismatch"
		return FALSE
	if(response_payload["request_id"] != request_id)
		resolution_reason = "request_id_mismatch"
		return FALSE
	if(response_payload["state_version"] != state_version)
		resolution_reason = "state_version_mismatch"
		return FALSE
	var/capability_id = response_payload["capability_id"]
	if(!istext(capability_id))
		resolution_reason = "missing_capability_id"
		return FALSE
	var/datum/npc_capability_offer/offer = capability_offers[capability_id]
	if(isnull(offer))
		resolution_reason = "unknown_capability_id"
		return FALSE

	var/speech = response_payload["speech"]
	if(offer.capability_kind == NPC_CAPABILITY_SAY)
		if(!istext(speech) || !length(trim(speech)) || length_char(speech) > NPC_COGNITION_MAX_SPEECH_TEXT)
			resolution_reason = "invalid_speech"
			return FALSE
	else if(!isnull(speech) && length("[speech]"))
		resolution_reason = "unexpected_speech"
		return FALSE

	var/datum/component/npc_actor/actor = actor_ref.resolve()
	var/datum/ai_controller/sapient_npc/controller = controller_ref.resolve()
	var/datum/npc_action_intent/intent = new(actor, controller, offer, speech)
	if(!controller.accept_cognition_intent(intent))
		qdel(intent)
		resolution_reason = "controller_rejected_intent"
		return FALSE
	gameplay_resolved = TRUE
	status = NPC_COGNITION_REQUEST_RESOLVED
	resolution_reason = "intent_accepted"
	return TRUE

/** Marks gameplay resolved while preserving a live rust-g job for safe draining. */
/datum/npc_cognition_request/proc/mark_gameplay_resolved(reason, timed_out = FALSE)
	gameplay_resolved = TRUE
	resolution_reason = reason
	status = timed_out ? NPC_COGNITION_REQUEST_TIMED_OUT : NPC_COGNITION_REQUEST_INVALIDATED
