#define NPC_COGNITION_AGING_INTERVAL (5 SECONDS)

/**
 * Global scheduler and rust-g HTTP owner for sapient NPC cognition.
 *
 * AI controller ticks never sleep or perform HTTP. This subsystem coalesces one request per actor,
 * enforces concurrency/budget bounds, polls native jobs, and discards stale responses before they
 * become physical intents.
 */
SUBSYSTEM_DEF(npc_cognition)
	name = "NPC Cognition"
	wait = 0.5 SECONDS
	priority = FIRE_PRIORITY_NPC_LOW
	runlevels = RUNLEVEL_GAME | RUNLEVEL_POSTGAME

	/// Whether outbound cognition is configured and enabled.
	var/enabled = FALSE
	/// Full private gateway decision URL.
	var/gateway_url
	/// Optional private bearer token. Never included in logs.
	var/gateway_token
	/// rust-g timeout in seconds.
	var/http_timeout_seconds = 15
	/// Maximum number of native HTTP jobs in flight.
	var/max_concurrent_requests = 4
	/// Maximum queued requests.
	var/max_queue_size = 128
	/// Maximum native jobs started in one minute.
	var/max_requests_per_minute = 120
	/// Queue TTL in deciseconds.
	var/queue_timeout = 10 SECONDS
	/// Per-actor cooldown in deciseconds.
	var/request_cooldown = 5 SECONDS
	/// Whether L1 actors may use the gateway.
	var/l1_enabled = TRUE
	/// Whether L2 actors may use the gateway.
	var/l2_enabled = TRUE
	/// Whether L3 actors may use the gateway.
	var/l3_enabled = TRUE
	/// Metadata-only lifecycle tracing toggle.
	var/trace_logging = FALSE

	/// Owned requests waiting for dispatch.
	var/list/queued_requests = list()
	/// Owned requests with a live rust-g job.
	var/list/in_flight_requests = list()
	/// Resumable copy used while polling in fire().
	var/list/currentrun = list()
	/// Actor ID to queued/in-flight request, used for O(1) coalescing.
	var/list/requests_by_actor_id = list()
	/// Start of the current request budget window.
	var/budget_window_started
	/// Native requests started in the current budget window.
	var/requests_started_in_window = 0

/datum/controller/subsystem/npc_cognition/Initialize()
	enabled = CONFIG_GET(flag/npc_ai_enabled)
	gateway_url = CONFIG_GET(string/npc_ai_gateway_url)
	gateway_token = CONFIG_GET(string/npc_ai_gateway_token)
	http_timeout_seconds = CONFIG_GET(number/npc_ai_http_timeout_seconds)
	max_concurrent_requests = CONFIG_GET(number/npc_ai_max_concurrent_requests)
	max_queue_size = CONFIG_GET(number/npc_ai_max_queue_size)
	max_requests_per_minute = CONFIG_GET(number/npc_ai_max_requests_per_minute)
	queue_timeout = CONFIG_GET(number/npc_ai_queue_timeout_seconds) SECONDS
	request_cooldown = CONFIG_GET(number/npc_ai_request_cooldown_seconds) SECONDS
	l1_enabled = CONFIG_GET(flag/npc_ai_l1_enabled)
	l2_enabled = CONFIG_GET(flag/npc_ai_l2_enabled)
	l3_enabled = CONFIG_GET(flag/npc_ai_l3_enabled)
	trace_logging = CONFIG_GET(flag/npc_ai_trace_logging)
	budget_window_started = world.time
	if(!enabled)
		return SS_INIT_NO_NEED
	if(!length(gateway_url))
		enabled = FALSE
		log_config("NPC cognition was enabled without npc_ai_gateway_url; deterministic fallback will be used.")
		return SS_INIT_NO_NEED
	return SS_INIT_SUCCESS

/datum/controller/subsystem/npc_cognition/Recover()
	if(islist(SSnpc_cognition.queued_requests))
		queued_requests = SSnpc_cognition.queued_requests
	if(islist(SSnpc_cognition.in_flight_requests))
		in_flight_requests = SSnpc_cognition.in_flight_requests
	if(islist(SSnpc_cognition.requests_by_actor_id))
		requests_by_actor_id = SSnpc_cognition.requests_by_actor_id
	requests_started_in_window = SSnpc_cognition.requests_started_in_window
	budget_window_started = SSnpc_cognition.budget_window_started

/datum/controller/subsystem/npc_cognition/stat_entry(msg)
	msg = "\n  Enabled:[enabled]|Queued:[length(queued_requests)]|Active:[length(in_flight_requests)]|Budget:[requests_started_in_window]/[max_requests_per_minute]"
	return ..()

/** TTS documents a rust-g crash on restart with active HTTP jobs, so cognition drains them too. */
/datum/controller/subsystem/npc_cognition/Shutdown()
	enabled = FALSE
	for(var/datum/npc_cognition_request/request as anything in in_flight_requests)
		if(!isnull(request.http_request))
			UNTIL(request.http_is_complete())

/** Returns whether the actor tier is allowed to leave Dream Maker. */
/datum/controller/subsystem/npc_cognition/proc/tier_uses_gateway(tier)
	switch(tier)
		if(NPC_COGNITION_TIER_L1)
			return l1_enabled
		if(NPC_COGNITION_TIER_L2)
			return l2_enabled
		if(NPC_COGNITION_TIER_L3)
			return l3_enabled
	return FALSE

/**
 * Coalesces and queues one actor request, or immediately installs deterministic fallback.
 *
 * Queue admission may evict a less urgent queued request, but never a live native HTTP job.
 */
/datum/controller/subsystem/npc_cognition/proc/queue_actor(
	datum/component/npc_actor/actor,
	datum/ai_controller/sapient_npc/controller,
	priority = NPC_COGNITION_PRIORITY_BACKGROUND,
)
	if(QDELETED(actor) || QDELETED(controller) || actor.parent != controller.pawn)
		return FALSE
	if(!enabled || !tier_uses_gateway(actor.cognition_tier))
		controller.apply_cognition_fallback(enabled ? "tier_local" : "gateway_disabled")
		return FALSE
	if(actor.pending_request_id || requests_by_actor_id[actor.actor_id])
		actor.replan_requested = TRUE
		actor.requested_priority = min(actor.requested_priority, priority)
		return TRUE

	if(length(queued_requests) >= max_queue_size)
		var/datum/npc_cognition_request/worst_request = find_worst_queued_request()
		if(isnull(worst_request) || priority >= worst_request.priority)
			controller.apply_cognition_fallback("queue_full")
			return FALSE
		queued_requests -= worst_request
		resolve_gameplay_failure(worst_request, "evicted_by_priority", use_fallback = TRUE)
		qdel(worst_request)

	var/datum/npc_cognition_request/request = new(actor, controller, priority)
	actor.set_pending_request(request.request_id)
	queued_requests += request
	requests_by_actor_id[actor.actor_id] = request
	trace_request(request, "queued")
	return TRUE

/** Invalidates queued gameplay and marks native jobs for late-response discard. */
/datum/controller/subsystem/npc_cognition/proc/invalidate_actor(datum/component/npc_actor/actor, reason)
	if(QDELETED(actor) || !actor.actor_id)
		return
	var/datum/npc_cognition_request/request = requests_by_actor_id[actor.actor_id]
	if(QDELETED(request))
		requests_by_actor_id -= actor.actor_id
		return
	if(request in queued_requests)
		queued_requests -= request
		requests_by_actor_id -= actor.actor_id
		actor.clear_pending_request(request.request_id, 0)
		request.mark_gameplay_resolved(reason)
		trace_request(request, reason)
		qdel(request)
		return
	if(request in in_flight_requests)
		actor.clear_pending_request(request.request_id, 0)
		requests_by_actor_id -= actor.actor_id
		request.mark_gameplay_resolved(reason)
		trace_request(request, reason)

/** Returns the lowest-value admission candidate: least urgent, newest request. */
/datum/controller/subsystem/npc_cognition/proc/find_worst_queued_request()
	var/datum/npc_cognition_request/worst_request
	for(var/datum/npc_cognition_request/request as anything in queued_requests)
		if(isnull(worst_request) || request.priority > worst_request.priority || (request.priority == worst_request.priority && request.enqueued_at > worst_request.enqueued_at))
			worst_request = request
	return worst_request

/** Selects the most urgent request while aging background work to prevent starvation. */
/datum/controller/subsystem/npc_cognition/proc/select_next_request()
	var/datum/npc_cognition_request/best_request
	var/best_score = INFINITY
	for(var/datum/npc_cognition_request/request as anything in queued_requests)
		var/age_bonus = floor((world.time - request.enqueued_at) / NPC_COGNITION_AGING_INTERVAL)
		var/score = request.priority * 10 - age_bonus
		if(score < best_score)
			best_score = score
			best_request = request
	return best_request

/** Resets and checks the global per-minute dispatch budget. */
/datum/controller/subsystem/npc_cognition/proc/budget_available()
	if(world.time >= budget_window_started + 1 MINUTES)
		budget_window_started = world.time
		requests_started_in_window = 0
	return requests_started_in_window < max_requests_per_minute

/** Removes queued requests whose snapshots would be too delayed to be useful. */
/datum/controller/subsystem/npc_cognition/proc/expire_queued_requests()
	for(var/datum/npc_cognition_request/request as anything in queued_requests.Copy())
		if(world.time < request.enqueued_at + queue_timeout)
			continue
		queued_requests -= request
		resolve_gameplay_failure(request, "queue_timeout", use_fallback = TRUE)
		qdel(request)

/** Starts one request after constructing fresh perception and capabilities. */
/datum/controller/subsystem/npc_cognition/proc/dispatch_request(datum/npc_cognition_request/request)
	queued_requests -= request
	if(!request.prepare_for_dispatch())
		resolve_gameplay_failure(request, request.resolution_reason || "dispatch_validation_failed", use_fallback = TRUE)
		qdel(request)
		return FALSE
	if(!request.start_http(gateway_url, gateway_token, http_timeout_seconds))
		resolve_gameplay_failure(request, request.resolution_reason || "http_start_failed", use_fallback = TRUE)
		qdel(request)
		return FALSE
	in_flight_requests += request
	requests_started_in_window++
	trace_request(request, "dispatched")
	return TRUE

/** Resolves a completed native response, with all failures degrading to a local wait. */
/datum/controller/subsystem/npc_cognition/proc/process_completed_request(datum/npc_cognition_request/request)
	if(request.gameplay_resolved)
		trace_request(request, "late_response_discarded")
		return
	var/datum/http_response/response = request.consume_http_response()
	if(QDELETED(response) || response.errored || response.status_code < 200 || response.status_code >= 300)
		resolve_gameplay_failure(request, "http_failure", use_fallback = TRUE)
		qdel(response)
		return
	var/list/response_payload
	try
		response_payload = json_decode(response.body)
	catch(var/exception/error)
		if(isnull(error))
			return
		resolve_gameplay_failure(request, "invalid_json", use_fallback = TRUE)
		qdel(response)
		return
	qdel(response)
	if(!request.accept_gateway_payload(response_payload))
		var/stale_response = request.resolution_reason == "stale_context" || request.resolution_reason == "state_version_mismatch"
		resolve_gameplay_failure(request, request.resolution_reason || "response_rejected", use_fallback = !stale_response)
		return
	var/datum/component/npc_actor/actor = request.actor_ref?.resolve()
	if(!QDELETED(actor))
		actor.clear_pending_request(request.request_id, request_cooldown)
	requests_by_actor_id -= request.actor_id
	trace_request(request, "intent_accepted")

/** Selects fallback once, clears coalescing ownership, and leaves a native job tracked if necessary. */
/datum/controller/subsystem/npc_cognition/proc/resolve_gameplay_failure(
	datum/npc_cognition_request/request,
	reason,
	timed_out = FALSE,
	use_fallback = FALSE,
)
	if(QDELETED(request) || request.gameplay_resolved)
		return
	request.mark_gameplay_resolved(reason, timed_out)
	var/datum/component/npc_actor/actor = request.actor_ref?.resolve()
	if(!QDELETED(actor))
		actor.clear_pending_request(request.request_id, request_cooldown)
	requests_by_actor_id -= request.actor_id
	if(use_fallback && request.context_is_valid())
		var/datum/ai_controller/sapient_npc/controller = request.controller_ref?.resolve()
		controller?.apply_cognition_fallback(reason)
	trace_request(request, reason)

/** Metadata-only trace helper; payloads, player speech and credentials are deliberately excluded. */
/datum/controller/subsystem/npc_cognition/proc/trace_request(datum/npc_cognition_request/request, event)
	if(!trace_logging)
		return
	log_game("NPC cognition [event]: actor=[request.actor_id] request=[request.request_id] priority=[request.priority] status=[request.status]")

/datum/controller/subsystem/npc_cognition/fire(resumed)
	if(!enabled)
		return
	if(!resumed)
		expire_queued_requests()
		while(length(in_flight_requests) < max_concurrent_requests && length(queued_requests) && budget_available())
			var/datum/npc_cognition_request/request = select_next_request()
			if(isnull(request))
				break
			dispatch_request(request)
			if(MC_TICK_CHECK)
				break
		currentrun = in_flight_requests.Copy()

	while(length(currentrun))
		var/datum/npc_cognition_request/request = currentrun[length(currentrun)]
		currentrun.len--
		if(request.http_is_complete())
			in_flight_requests -= request
			process_completed_request(request)
			qdel(request)
		else if(!request.gameplay_resolved && world.time >= request.response_deadline)
			resolve_gameplay_failure(request, "http_timeout", timed_out = TRUE, use_fallback = TRUE)
		if(MC_TICK_CHECK)
			return

#undef NPC_COGNITION_AGING_INTERVAL
