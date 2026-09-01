/// Blackboard key containing the currently accepted server-validated NPC action intent.
#define BB_NPC_ACTION_INTENT "BB_npc_action_intent"

/// Cognition tiers. L0 never leaves Dream Maker; higher tiers may use the configured gateway.
#define NPC_COGNITION_TIER_L0 0
#define NPC_COGNITION_TIER_L1 1
#define NPC_COGNITION_TIER_L2 2
#define NPC_COGNITION_TIER_L3 3

/// Request priorities, ordered from most urgent to background work.
#define NPC_COGNITION_PRIORITY_CRITICAL 0
#define NPC_COGNITION_PRIORITY_PLAYER 1
#define NPC_COGNITION_PRIORITY_DECISION 2
#define NPC_COGNITION_PRIORITY_BACKGROUND 3

/// Request lifecycle states used by SSnpc_cognition and diagnostics.
#define NPC_COGNITION_REQUEST_QUEUED "queued"
#define NPC_COGNITION_REQUEST_IN_FLIGHT "in_flight"
#define NPC_COGNITION_REQUEST_RESOLVED "resolved"
#define NPC_COGNITION_REQUEST_TIMED_OUT "timed_out"
#define NPC_COGNITION_REQUEST_INVALIDATED "invalidated"

/// Version of the provider-agnostic JSON contract between Arcadia and the NPC AI gateway.
#define NPC_COGNITION_SCHEMA_VERSION 1

/// Memory classifications kept distinct so beliefs and lies are never promoted to world facts implicitly.
#define NPC_MEMORY_FACT "fact"
#define NPC_MEMORY_BELIEF "belief"
#define NPC_MEMORY_EPISODIC "memory"
#define NPC_MEMORY_STATEMENT "statement"
#define NPC_MEMORY_RUMOR "rumor"
#define NPC_MEMORY_INFERENCE "inference"
#define NPC_MEMORY_LIE "lie"
#define NPC_MEMORY_ACTION_RESULT "action_result"

/// Server-owned capability kinds exposed to the gateway through opaque per-request IDs.
#define NPC_CAPABILITY_WAIT "wait"
#define NPC_CAPABILITY_SAY "say"
#define NPC_CAPABILITY_MOVE "move"
#define NPC_CAPABILITY_INSPECT "inspect"
#define NPC_CAPABILITY_INTERACT "interact"
#define NPC_CAPABILITY_WORLD_CLICK "world_click"
#define NPC_CAPABILITY_ACTION "action"
#define NPC_CAPABILITY_SWAP_HAND "swap_hand"
#define NPC_CAPABILITY_DROP_ITEM "drop_item"
#define NPC_CAPABILITY_REST "rest"
#define NPC_CAPABILITY_RESIST "resist"
#define NPC_CAPABILITY_MACHINE_CONTROL "machine_control"
#define NPC_CAPABILITY_PULL "pull"
#define NPC_CAPABILITY_STOP_PULLING "stop_pulling"
#define NPC_CAPABILITY_EQUIP_ITEM "equip_item"

/// Hard safety bounds independent of configuration.
#define NPC_COGNITION_MAX_VISIBLE_ENTITIES 24
#define NPC_COGNITION_MAX_CAPABILITY_TARGETS 8
#define NPC_COGNITION_MAX_CAPABILITIES 64
#define NPC_COGNITION_MAX_ACTIONS 8
#define NPC_COGNITION_MAX_RECENT_MEMORY 32
#define NPC_COGNITION_MAX_CONTEXT_MEMORY 12
#define NPC_COGNITION_MAX_CONVERSATION_TURNS 16
#define NPC_COGNITION_MAX_MEMORY_TEXT 512
#define NPC_COGNITION_MAX_SPEECH_TEXT 300
#define NPC_COGNITION_VIEW_RANGE 7
#define NPC_COGNITION_ACTION_TTL (15 SECONDS)
#define NPC_COGNITION_INTERACTION_APPROACH_TIMEOUT (8 SECONDS)
#define NPC_COGNITION_FALLBACK_WAIT (2 SECONDS)
