use poseidon::poseidon2::Poseidon2Hasher;
use std::{collections::umap::UHashMap, hash::BuildHasherDefault, meta::ctstring::AsCtString};

use crate::macros::{
    calls_generation::{
        external_functions::{
            generate_external_function_calls, generate_external_function_self_calls_structs,
        },
        internal_functions::generate_call_internal_struct,
    },
    dispatch::generate_public_dispatch,
    internals_functions_generation::{create_fn_abi_exports, process_functions},
    notes::NOTES,
    storage::STORAGE_LAYOUT_NAME,
    utils::{
        get_trait_impl_method, is_fn_contract_library_method, is_fn_external, is_fn_internal,
        is_fn_test, module_has_storage,
    },
};

/// Contract-level options for the #[aztec] macro.
struct AztecContractOpts {
    /// Name of the custom message handler function.
    custom_message_handler: Option<CtString>,
}

/// Stores contract-level options set via #[aztec_opts(...)].
/// The #[aztec] macro reads from this registry to configure code generation.
comptime mut global AZTEC_CONTRACT_OPTS: UHashMap<Module, AztecContractOpts, BuildHasherDefault<Poseidon2Hasher>> =
    UHashMap::default();

/// Sets contract-level options for the #[aztec] macro.
///
/// Currently supports specifying a custom message handler function:
/// ```noir
/// #[aztec_opts(handle_multi_log_message)]
/// #[aztec]
/// contract MyContract {
///     #[contract_library_method]
///     unconstrained fn my_handler_function(...) { ... }
/// }
/// ```
///
/// The specified function must exist in the contract, be marked `#[contract_library_method]`,
/// be `unconstrained`, and have the correct signature for a custom message handler.
pub comptime fn aztec_opts(m: Module, custom_message_handler: CtString) -> Quoted {
    let opts = AztecContractOpts { custom_message_handler: Option::some(custom_message_handler) };
    AZTEC_CONTRACT_OPTS.insert(m, opts);
    quote {}
}

/// Marks a contract as an Aztec contract, generating the interfaces for its functions and notes, as well as injecting
/// the `sync_private_state` utility function.
/// Note: This is a module annotation, so the returned quote gets injected inside the module (contract) itself.
pub comptime fn aztec(m: Module) -> Quoted {
    // Functions that don't have #[external(...)], #[contract_library_method], or #[test] are not allowed in contracts.
    check_each_fn_macroified(m);

    // We generate new functions prefixed with `__aztec_nr_internals__` and we replace the original functions' bodies
    // with `static_assert(false, ...)` to prevent them from being called directly from within the contract.
    let functions = process_functions(m);

    // We generate structs and their implementations necessary for convenient functions calls.
    let interface = generate_contract_interface(m);
    let self_call_structs = generate_external_function_self_calls_structs(m);
    let call_internal_struct = generate_call_internal_struct(m);

    // We generate ABI exports for all the external functions in the contract.
    let fn_abi_exports = create_fn_abi_exports(m);

    // We generate `_compute_note_hash_and_nullifier`, `sync_private_state` and `process_message`
    // functions only if they are not already implemented. If they are implemented we just insert empty
    // quotes.
    let contract_library_method_compute_note_hash_and_nullifier = if !m.functions().any(|f| {
        f.name() == quote { _compute_note_hash_and_nullifier }
    }) {
        generate_contract_library_method_compute_note_hash_and_nullifier()
    } else {
        quote {}
    };
    // Look for a user-provided custom message handler via #[aztec_opts(...)], or generate a default.
    let (contract_library_method_process_custom_message, custom_message_handler_name) = if AZTEC_CONTRACT_OPTS
        .get(m)
        .is_some() {
        let opts = AZTEC_CONTRACT_OPTS.get(m).unwrap();
        if opts.custom_message_handler.is_some() {
            // User specified handler via #[aztec_opts(handler_name)] - validate and use it.
            let handler_name_str = opts.custom_message_handler.unwrap();
            let handler_fn = validate_custom_message_handler(m, handler_name_str);
            // Use the function's name as quoted token for generated code
            (quote {}, handler_fn.name())
        } else {
            // aztec_opts present but no handler specified - generate the default.
            (
                generate_contract_library_method_process_custom_message(),
                quote { _process_custom_message },
            )
        }
    } else {
        // No aztec_opts - generate the default.
        (
            generate_contract_library_method_process_custom_message(),
            quote { _process_custom_message },
        )
    };
    let sync_private_state_fn_and_abi_export = if !m.functions().any(|f| {
        f.name() == quote { sync_private_state }
    }) {
        generate_sync_private_state(custom_message_handler_name)
    } else {
        quote {}
    };

    let process_message_fn_and_abi_export = if !m.functions().any(|f| {
        f.name() == quote { process_message }
    }) {
        generate_process_message(custom_message_handler_name)
    } else {
        quote {}
    };
    let public_dispatch = generate_public_dispatch(m);

    quote {
        $interface
        $self_call_structs
        $call_internal_struct
        $functions
        $fn_abi_exports
        $contract_library_method_compute_note_hash_and_nullifier
        $contract_library_method_process_custom_message
        $public_dispatch
        $sync_private_state_fn_and_abi_export
        $process_message_fn_and_abi_export
    }
}

comptime fn generate_contract_interface(m: Module) -> Quoted {
    let calls = generate_external_function_calls(m);

    let module_name = m.name();

    let has_storage_layout = module_has_storage(m) & STORAGE_LAYOUT_NAME.get(m).is_some();
    let storage_layout_getter = if has_storage_layout {
        let storage_layout_name = STORAGE_LAYOUT_NAME.get(m).unwrap();
        quote {
            pub fn storage_layout() -> StorageLayoutFields {
                $storage_layout_name.fields
            }
        }
    } else {
        quote {}
    };

    let library_storage_layout_getter = if has_storage_layout {
        quote {
            #[contract_library_method]
            $storage_layout_getter
        }
    } else {
        quote {}
    };

    quote {
        pub struct $module_name {
            pub target_contract: dep::aztec::protocol_types::address::AztecAddress
        }

        impl $module_name {
            $calls

            pub fn at(
                addr: aztec::protocol_types::address::AztecAddress
            ) -> Self {
                Self { target_contract: addr }
            }

            pub fn interface() -> Self {
                Self { target_contract: aztec::protocol_types::address::AztecAddress::zero() }
            }

            $storage_layout_getter
        }

        #[contract_library_method]
        pub fn at(
            addr: aztec::protocol_types::address::AztecAddress
        ) -> $module_name {
            $module_name { target_contract: addr }
        }

        #[contract_library_method]
        pub fn interface() -> $module_name {
            $module_name { target_contract: aztec::protocol_types::address::AztecAddress::zero() }
        }

        $library_storage_layout_getter

    }
}

/// Generates a contract library method called `_compute_note_hash_and_nullifier` which is used for note
/// discovery (to create the `aztec::messages::discovery::ComputeNoteHashAndNullifier` function) and to implement the
/// `compute_note_hash_and_nullifier` unconstrained contract function.
comptime fn generate_contract_library_method_compute_note_hash_and_nullifier() -> Quoted {
    if NOTES.len() > 0 {
        // Contracts that do define notes produce an if-else chain where `note_type_id` is matched against the
        // `get_note_type_id()` function of each note type that we know of, in order to identify the note type. Once we
        // know it we call we correct `unpack` method from the `Packable` trait to obtain the underlying note type, and
        // compute the note hash (non-siloed) and inner nullifier (also non-siloed).

        let mut if_note_type_id_match_statements_list = @[];
        for i in 0..NOTES.len() {
            let typ = NOTES.get(i);

            let get_note_type_id = get_trait_impl_method(
                typ,
                quote { crate::note::note_interface::NoteType },
                quote { get_id },
            );
            let unpack = get_trait_impl_method(
                typ,
                quote { crate::protocol_types::traits::Packable },
                quote { unpack },
            );

            let compute_note_hash = get_trait_impl_method(
                typ,
                quote { crate::note::note_interface::NoteHash },
                quote { compute_note_hash },
            );

            let compute_nullifier_unconstrained = get_trait_impl_method(
                typ,
                quote { crate::note::note_interface::NoteHash },
                quote { compute_nullifier_unconstrained },
            );

            let if_or_else_if = if i == 0 {
                quote { if }
            } else {
                quote { else if }
            };

            if_note_type_id_match_statements_list = if_note_type_id_match_statements_list.push_back(
                quote {
                    $if_or_else_if note_type_id == $get_note_type_id() {
                        // As an extra safety check we make sure that the packed_note BoundedVec has the expected
                        // length, since we're about to interpret its raw storage as a fixed-size array by calling the
                        // unpack function on it.
                        let expected_len = <$typ as $crate::protocol_types::traits::Packable>::N;
                        let actual_len = packed_note.len();
                        assert(
                            actual_len == expected_len,
                            f"Expected packed note of length {expected_len} but got {actual_len} for note type id {note_type_id}"
                        );

                        let note = $unpack(aztec::utils::array::subarray(packed_note.storage(), 0));

                        let note_hash = $compute_note_hash(note, owner, storage_slot, randomness);
    
                        // The message discovery process finds settled notes, that is, notes that were created in prior
                        // transactions and are therefore already part of the note hash tree. We therefore compute the
                        // nullification note hash by treating the note as a settled note with the provided note nonce.
                        let note_hash_for_nullification = aztec::note::utils::compute_note_hash_for_nullification(
                            aztec::note::HintedNote{
                                note,
                                contract_address,
                                owner,
                                randomness,
                                storage_slot,
                                metadata: aztec::note::note_metadata::SettledNoteMetadata::new(note_nonce).into()
                            }
                        );

                        let inner_nullifier = $compute_nullifier_unconstrained(note, owner, note_hash_for_nullification);

                        Option::some(
                            aztec::messages::discovery::NoteHashAndNullifier {
                                note_hash, inner_nullifier
                            }
                        )
                    }
                },
            );
        }

        let if_note_type_id_match_statements = if_note_type_id_match_statements_list.join(quote {});

        quote {
            /// Unpacks an array into a note corresponding to `note_type_id` and then computes its note hash
            /// (non-siloed) and inner nullifier (non-siloed) assuming the note has been inserted into the note hash
            /// tree with `note_nonce`.
            ///
            /// The signature of this function notably matches the `aztec::messages::discovery::ComputeNoteHashAndNullifier` type,
            /// and so it can be used to call functions from that module such as `discover_new_messages`, 
            /// `do_process_message` and `attempt_note_discovery`.
            ///
            /// This function is automatically injected by the `#[aztec]` macro.
            #[contract_library_method]
            unconstrained fn _compute_note_hash_and_nullifier(
                packed_note: BoundedVec<Field, aztec::messages::logs::note::MAX_NOTE_PACKED_LEN>,
                owner: aztec::protocol_types::address::AztecAddress,
                storage_slot: Field,
                note_type_id: Field,
                contract_address: aztec::protocol_types::address::AztecAddress,
                randomness: Field,
                note_nonce: Field,
            ) -> Option<aztec::messages::discovery::NoteHashAndNullifier> {
                $if_note_type_id_match_statements
                else {
                    Option::none()
                }
            }
        }
    } else {
        // Contracts with no notes still implement this function to avoid having special-casing, the implementation
        // simply throws immediately.
        quote {
            /// This contract does not use private notes, so this function should never be called as it will
            /// unconditionally fail.
            ///
            /// This function is automatically injected by the `#[aztec]` macro.
            #[contract_library_method]
            unconstrained fn _compute_note_hash_and_nullifier(
                _packed_note: BoundedVec<Field, aztec::messages::logs::note::MAX_NOTE_PACKED_LEN>,
                _owner: aztec::protocol_types::address::AztecAddress,
                _storage_slot: Field,
                _note_type_id: Field,
                _contract_address: aztec::protocol_types::address::AztecAddress,
                _randomness: Field,
                _nonce: Field,
            ) -> Option<aztec::messages::discovery::NoteHashAndNullifier> {
                panic(f"This contract does not use private notes")
            }
        }
    }
}

/// Generates a default `_process_custom_message` function which handles unknown message types encountered during
/// message processing. The default implementation simply logs the unknown type ID.
/// This is only generated when no custom message handler is specified via `#[aztec_opts(...)]`.
comptime fn generate_contract_library_method_process_custom_message() -> Quoted {
    quote {
        #[contract_library_method]
        unconstrained fn _process_custom_message(
            _contract_address: aztec::protocol_types::address::AztecAddress,
            msg_type_id: u64,
            _msg_metadata: u64,
            _msg_content: BoundedVec<Field, aztec::messages::encoding::MAX_MESSAGE_CONTENT_LEN>,
            _message_context: aztec::messages::processing::MessageContext,
        ) {
            aztec::protocol_types::debug_log::debug_log_format("Unknown msg type id {0}", [msg_type_id as Field]);
        }
    }
}

comptime fn generate_sync_private_state(custom_message_handler_name: Quoted) -> Quoted {
    quote {
        pub struct sync_private_state_parameters {}

        #[abi(functions)]
        pub struct sync_private_state_abi {
            parameters: sync_private_state_parameters,
        }

        #[aztec::macros::internals_functions_generation::abi_attributes::abi_utility]
        unconstrained fn sync_private_state() {
            let address = aztec::context::UtilityContext::new().this_address();

            aztec::messages::discovery::discover_new_messages(address, _compute_note_hash_and_nullifier, $custom_message_handler_name);
        }
    }
}

comptime fn generate_process_message(custom_message_handler_name: Quoted) -> Quoted {
    quote {
        pub struct process_message_parameters {
            pub message_ciphertext: BoundedVec<Field, aztec::messages::encoding::MESSAGE_CIPHERTEXT_LEN>,
            pub message_context: aztec::messages::processing::MessageContext,
        }

        #[abi(functions)]
        pub struct process_message_abi {
            parameters: process_message_parameters,
        }

        #[aztec::macros::internals_functions_generation::abi_attributes::abi_utility]
        unconstrained fn process_message(
            message_ciphertext: BoundedVec<Field, aztec::messages::encoding::MESSAGE_CIPHERTEXT_LEN>,
            message_context: aztec::messages::processing::MessageContext,
        ) {
            let address = aztec::context::UtilityContext::new().this_address();

            aztec::messages::discovery::process_message::process_message_ciphertext(
                address,
                _compute_note_hash_and_nullifier,
                $custom_message_handler_name,
                message_ciphertext,
                message_context,
            );
        }
    }
}

/// Validates that a custom message handler specified via #[aztec_opts(...)] is valid.
/// Returns the FunctionDefinition so we can get its properly quoted name.
comptime fn validate_custom_message_handler(
    m: Module,
    handler_name: CtString,
) -> FunctionDefinition {
    // Find the function by comparing name strings
    let matching_fns = m.functions().filter(|f: FunctionDefinition| {
        let fn_name_quoted = f.name();
        let fn_name = f"{fn_name_quoted}".as_ctstring();
        fn_name.eq(handler_name)
    });

    if matching_fns.len() == 0 {
        panic(
            f"#[aztec_opts] specifies custom_message_handler '{handler_name}' but no such function exists in the contract",
        );
    }

    let handler = matching_fns[0];

    if !is_fn_contract_library_method(handler) {
        panic(
            f"Custom message handler '{handler_name}' must be marked #[contract_library_method]",
        );
    }

    if !handler.is_unconstrained() {
        panic(
            f"Custom message handler '{handler_name}' must be unconstrained",
        );
    }

    let param_count = handler.parameters().len();
    if param_count != 5 {
        panic(
            f"Custom message handler '{handler_name}' must have exactly 5 parameters (contract_address, msg_type_id, msg_metadata, msg_content, message_context), but has {param_count}",
        );
    }

    handler
}

/// Checks that all functions in the module have a context macro applied.
///
/// Non-macroified functions are not allowed in contracts. They must all be one of
/// [external](crate::macros::functions::external), [internal](crate::macros::functions::internal) or `test`.
comptime fn check_each_fn_macroified(m: Module) {
    for f in m.functions() {
        let name = f.name();
        if !is_fn_external(f)
            & !is_fn_contract_library_method(f)
            & !is_fn_internal(f)
            & !is_fn_test(f) {
            // We  don't suggest that #[contract_library_method] is allowed because we don't want to introduce another
            // concept
            panic(
                f"Function {name} must be marked as either #[external(...)], #[internal(...)], or #[test]",
            );
        }
    }
}
