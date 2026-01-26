use aztec::macros::aztec;

#[aztec::aztec_opts(
    aztec::AztecOptions::new().with_custom_message_handler("handle_multi_log_message"),
)]
#[aztec]
contract CustomMessage {
    use aztec::{
        capsules::CapsuleArray,
        event::event_interface::{
            compute_private_event_commitment, compute_private_serialized_event_commitment,
            EventInterface,
        },
        macros::{events::event, functions::external},
        messages::{
            encoding::{encode_message, MAX_MESSAGE_CONTENT_LEN},
            logs::event::MAX_EVENT_SERIALIZED_LEN,
            message_delivery::{do_private_message_delivery, MessageDelivery},
            processing::{enqueue_event_for_validation, MessageContext},
        },
        oracle::random::random,
        protocol_types::{
            address::AztecAddress,
            hash::sha256_to_field,
            traits::{Deserialize, FromField, Serialize, ToField},
        },
    };
    use aztec::event::EventSelector;

    /// Custom message type ID for multi-log messages.
    global MULTI_LOG_MSG_TYPE_ID: u64 = 42;

    /// Capsule slot for accumulating multi-log parts between handler calls.
    global PENDING_MULTI_LOG_PARTS_SLOT: Field =
        sha256_to_field("CUSTOM_MSG::PENDING_MULTI_LOG_PARTS".as_bytes());

    /// An event with 4 fields, too large to demonstrate fitting in one message content
    /// (in practice you'd use this for events exceeding MAX_EVENT_SERIALIZED_LEN).
    #[event]
    struct MultiLogEvent {
        value0: Field,
        value1: Field,
        value2: Field,
        value3: Field,
    }

    /// A stored multi-log part, kept in a CapsuleArray until all parts arrive.
    #[derive(Serialize, Deserialize)]
    struct PendingMultiLogPart {
        tx_hash: Field,
        message_id: Field,
        part_number: Field,
        total_parts: Field,
        content: BoundedVec<Field, MAX_MESSAGE_CONTENT_LEN>,
    }

    /// Packs part_number and total_parts into a u64 for use as msg_metadata.
    #[contract_library_method]
    fn pack_part_info(part_number: u32, total_parts: u32) -> u64 {
        (part_number as u64) * 0x100000000 + (total_parts as u64)
    }

    /// Unpacks part_number and total_parts from msg_metadata.
    #[contract_library_method]
    unconstrained fn unpack_part_info(packed: u64) -> (u32, u32) {
        let total_parts = (packed % 0x100000000) as u32;
        let part_number = (packed / 0x100000000) as u32;
        (part_number, total_parts)
    }

    /// Emits a multi-log event split across 2 private logs. This demonstrates the multi-log
    /// message pattern: the event data is split into parts, each sent as a separate log with
    /// a custom message type. The receiver's custom message handler reassembles them.
    ///
    /// Each part includes `randomness` as its first content field, which serves as a message_id
    /// for correlating parts belonging to the same multi-log event (allowing multiple multi-log
    /// events per transaction).
    ///
    /// Split layout:
    ///   Part 0 (metadata=pack(0,2)): content = [randomness, event_type_id, value0, value1]
    ///   Part 1 (metadata=pack(1,2)): content = [randomness, value2, value3]
    #[external("private")]
    fn emit_multi_log_event(
        value0: Field,
        value1: Field,
        value2: Field,
        value3: Field,
        recipient: AztecAddress,
    ) {
        let event = MultiLogEvent { value0, value1, value2, value3 };

        // Safety: randomness produced by the sender, same trust model as standard events.
        let randomness = unsafe { random() };

        // Emit commitment as nullifier computed from FULL event (same as standard events)
        let commitment = compute_private_event_commitment(event, randomness);
        self.context.push_nullifier(commitment);

        let event_type_id = MultiLogEvent::get_event_type_id().to_field();

        // Part 0: randomness (message_id), event_type_id, and first 2 event fields
        let msg0 = encode_message(
            MULTI_LOG_MSG_TYPE_ID,
            pack_part_info(0, 2),
            [randomness, event_type_id, value0, value1],
        );
        do_private_message_delivery(
            self.context,
            || msg0,
            Option::none(),
            recipient,
            MessageDelivery.ONCHAIN_UNCONSTRAINED,
        );

        // Part 1: randomness (message_id) and remaining event fields
        let msg1 = encode_message(
            MULTI_LOG_MSG_TYPE_ID,
            pack_part_info(1, 2),
            [randomness, value2, value3],
        );
        do_private_message_delivery(
            self.context,
            || msg1,
            Option::none(),
            recipient,
            MessageDelivery.ONCHAIN_UNCONSTRAINED,
        );
    }

    /// Reassembles multi-log messages. Each part is stored in a CapsuleArray. When all parts for
    /// a given (tx_hash, message_id) arrive, the full event is reconstructed and stored via the
    /// standard event infrastructure.
    ///
    /// Parts are correlated by (tx_hash, message_id) where message_id is the first field of
    /// every part's content (which is the event's randomness). This allows multiple multi-log
    /// events within the same transaction.
    #[contract_library_method]
    unconstrained fn handle_multi_log_message(
        contract_address: AztecAddress,
        msg_type_id: u64,
        msg_metadata: u64,
        msg_content: BoundedVec<Field, MAX_MESSAGE_CONTENT_LEN>,
        message_context: MessageContext,
    ) {
        if msg_type_id == MULTI_LOG_MSG_TYPE_ID {
            let (part_number, total_parts) = unpack_part_info(msg_metadata);
            let parts = CapsuleArray::at(contract_address, PENDING_MULTI_LOG_PARTS_SLOT);

            // First field of every part's content is the message_id (= randomness)
            let message_id = msg_content.get(0);

            // Store this part
            parts.push(
                PendingMultiLogPart {
                    tx_hash: message_context.tx_hash,
                    message_id,
                    part_number: part_number as Field,
                    total_parts: total_parts as Field,
                    content: msg_content,
                },
            );

            // Check if all parts for this (tx_hash, message_id) have arrived
            let mut count: u32 = 0;
            let parts_len = parts.len();
            let mut i: u32 = 0;
            while i < parts_len {
                let p: PendingMultiLogPart = parts.get(i);
                if (p.tx_hash == message_context.tx_hash) & (p.message_id == message_id) {
                    count += 1;
                }
                i += 1;
            }

            if count == total_parts {
                // All parts present - reassemble the event.
                // Every part content[0] is message_id (= randomness).
                // Part 0 content: [randomness, event_type_id, ...event_fields_chunk]
                // Part N content: [randomness, ...event_fields_chunk]

                let randomness = message_id;
                let mut event_type_id_field: Field = 0;
                let mut serialized_event: BoundedVec<Field, MAX_EVENT_SERIALIZED_LEN> =
                    BoundedVec::new();

                // Process parts in order
                let mut part_idx: u32 = 0;
                while part_idx < total_parts {
                    // Find the part with this part_number
                    let mut j: u32 = 0;
                    while j < parts_len {
                        let p: PendingMultiLogPart = parts.get(j);
                        if (p.tx_hash == message_context.tx_hash)
                            & (p.message_id == message_id)
                            & (p.part_number == part_idx as Field) {
                            if part_idx == 0 {
                                // Part 0: content[0]=randomness, content[1]=event_type_id,
                                // content[2..] are event fields
                                event_type_id_field = p.content.get(1);
                                let mut k: u32 = 2;
                                while k < p.content.len() {
                                    serialized_event.push(p.content.get(k));
                                    k += 1;
                                }
                            } else {
                                // Other parts: content[0]=randomness, content[1..] are event fields
                                let mut k: u32 = 1;
                                while k < p.content.len() {
                                    serialized_event.push(p.content.get(k));
                                    k += 1;
                                }
                            }
                            j = parts_len; // break
                        }
                        j += 1;
                    }
                    part_idx += 1;
                }

                // Compute commitment from full reassembled event
                let event_type_id = EventSelector::from_field(event_type_id_field);
                let event_commitment = compute_private_serialized_event_commitment(
                    serialized_event,
                    randomness,
                    event_type_id_field,
                );

                enqueue_event_for_validation(
                    contract_address,
                    event_type_id,
                    randomness,
                    serialized_event,
                    event_commitment,
                    message_context.tx_hash,
                    message_context.recipient,
                );

                // Clean up: remove all parts for this (tx_hash, message_id) - iterate backwards
                // to avoid index shifting
                let mut remove_idx: u32 = parts.len();
                while remove_idx > 0 {
                    remove_idx -= 1;
                    let p: PendingMultiLogPart = parts.get(remove_idx);
                    if (p.tx_hash == message_context.tx_hash) & (p.message_id == message_id) {
                        parts.remove(remove_idx);
                    }
                }
            }
        }
    }
}
