-- Phase 9: Hard-cutover cleanup of legacy pre-federated schema.
-- Keep only federated account/device/prekey/mailbox/media model.

DROP TABLE IF EXISTS call_security_context CASCADE;
DROP TABLE IF EXISTS trusted_peer_keys CASCADE;
DROP TABLE IF EXISTS friend_key_exchange_consent CASCADE;
DROP TABLE IF EXISTS friendships CASCADE;
DROP TABLE IF EXISTS call_quality_metrics CASCADE;
DROP TABLE IF EXISTS device_tokens CASCADE;
DROP TABLE IF EXISTS pinned_messages CASCADE;
DROP TABLE IF EXISTS message_mentions CASCADE;
DROP TABLE IF EXISTS message_reactions CASCADE;
DROP TABLE IF EXISTS message_visibility CASCADE;
DROP TABLE IF EXISTS message_edits CASCADE;
DROP TABLE IF EXISTS file_attachments CASCADE;
DROP TABLE IF EXISTS mesh_routing_table CASCADE;
DROP TABLE IF EXISTS mesh_connections CASCADE;
DROP TABLE IF EXISTS mesh_peers CASCADE;
DROP TABLE IF EXISTS calls CASCADE;
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS conversation_participants CASCADE;
DROP TABLE IF EXISTS conversations CASCADE;
DROP TABLE IF EXISTS users CASCADE;

DROP FUNCTION IF EXISTS calculate_call_duration() CASCADE;
DROP FUNCTION IF EXISTS update_device_token_last_used() CASCADE;
