use std::meta::ctstring::AsCtString;

use crate::macros::{
    calls_generation::{
        external_functions::{generate_external_function_calls, generate_external_function_self_calls_structs},
        internal_functions::generate_call_internal_struct,
    },
    dispatch::generate_public_dispatch,
    internals_functions_generation::{create_fn_abi_exports, process_functions},
    notes::NOTES,
    storage::STORAGE_LAYOUT_NAME,
    utils::{
        get_trait_impl_method, is_fn_contract_library_method, is_fn_external, is_fn_internal, is_fn_test,
        module_has_storage,
    },
};

/// Builder for configuring Aztec contract settings.
///
/// Usage:
/// ```noir
/// #[aztec(aztec::macros::AztecConfig::new().custom_message_handler("my_handler"))]
/// contract MyContract { ... }
/// ```
pub struct AztecConfig {
    custom_message_handler: Option<CtString>,
}

impl AztecConfig {
    /// Creates a new `AztecConfig` with default values.
    ///
    /// Calling `new` is equivalent to invoking the [`#[aztec]`](aztec) macro with no parameters. The different methods
    /// (e.g. [`custom_message_handler`](custom_message_handler)) can then be used to change the default behavior.
    pub comptime fn new() -> Self {
        Self { custom_message_handler: Option::none() }
    }

    /// Sets a handler for custom messages.
    ///
    /// This enables contracts to process non-standard messages (i.e. any with a message type that is not in
    /// [`messages::msg_type`]).
    ///
    /// `handler_name` must be the name of a `#[contract_library_method]` function that conforms to the
    /// [`messages::discovery::CustomMessageHandler`](crate::messages::discovery::CustomMessageHandler) type signature.
    pub comptime fn custom_message_handler(_self: Self, handler_name: CtString) -> Self {
        Self { custom_message_handler: Option::some(handler_name) }
    }
}

/// Enables aztec-nr features on a `contract`.
///
/// All aztec-nr contracts should have this macro invoked on them, as it is the one that processes all contract
/// functions, notes, storage, generates interfaces for external calls, and creates the message processing
/// boilerplate.
///
/// ## Examples
///
/// Most contracts can simply invoke the macro with no parameters, resulting in default aztec-nr behavior:
/// ```noir
/// #[aztec]
/// contract MyContract { ... }
/// ```
///
/// Advanced contracts can use [`AztecConfig`](AztecConfig) to customize parts of its behavior, such as message
/// processing.
/// ```noir
/// #[aztec(aztec::macros::AztecConfig::new().custom_message_handler("my_handler"))]
/// contract MyAdvancedContract { ... }
/// ```
#[varargs]
pub comptime fn aztec(m: Module, args: [AztecConfig]) -> Quoted {
    let num_args = args.len();
    let config = if num_args == 0 {
        AztecConfig::new()
    } else if num_args == 1 {
        args[0]
    } else {
        panic(f"#[aztec] expects 0 or 1 arguments, got {num_args}")
    };

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

    // We generate `_compute_note_hash_and_nullifier`, `sync_state` and `process_message` functions only if they are
    // not already implemented. If they are implemented we just insert empty quotes.
    let contract_library_method_compute_note_hash_and_nullifier = if !m.functions().any(|f| {
        f.name() == quote { _compute_note_hash_and_nullifier }
    }) {
        generate_contract_library_method_compute_note_hash_and_nullifier()
    } else {
        quote {}
    };
    let process_custom_message_option = if config.custom_message_handler.is_some() {
        // User specified handler - validate and use it.
        let handler_name_str = config.custom_message_handler.unwrap();
        let handler_fn = validate_custom_message_handler(m, handler_name_str);
        // Suppress "unused function" warning since the handler is used via function pointer
        handler_fn.add_attribute("allow(dead_code)");
        let handler_name = handler_fn.name();
        quote { Option::some($handler_name) }
    } else {
        quote { Option::<aztec::messages::discovery::CustomMessageHandler<()>>::none() }
    };

    let sync_state_fn_and_abi_export = if !m.functions().any(|f| f.name() == quote { sync_state }) {
        generate_sync_state(process_custom_message_option)
    } else {
        quote {}
    };

    let process_message_fn_and_abi_export = if !m.functions().any(|f| f.name() == quote { process_message }) {
        generate_process_message(process_custom_message_option)
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
        $public_dispatch
        $sync_state_fn_and_abi_export
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
            pub target_contract: aztec::protocol::address::AztecAddress
        }

        impl $module_name {
            $calls

            pub fn at(
                addr: aztec::protocol::address::AztecAddress
            ) -> Self {
                Self { target_contract: addr }
            }

            pub fn interface() -> Self {
                Self { target_contract: aztec::protocol::address::AztecAddress::zero() }
            }

            $storage_layout_getter
        }

        #[contract_library_method]
        pub fn at(
            addr: aztec::protocol::address::AztecAddress
        ) -> $module_name {
            $module_name { target_contract: addr }
        }

        #[contract_library_method]
        pub fn interface() -> $module_name {
            $module_name { target_contract: aztec::protocol::address::AztecAddress::zero() }
        }

        $library_storage_layout_getter

    }
}

/// Generates a contract library method called `_compute_note_hash_and_nullifier` which is used for note discovery (to
/// create the `aztec::messages::discovery::ComputeNoteHashAndNullifier` function) and to implement the
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
                quote { crate::protocol::traits::Packable },
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
                        let expected_len = <$typ as $crate::protocol::traits::Packable>::N;
                        let actual_len = packed_note.len();
                        assert(
                            actual_len == expected_len,
                            f"Expected packed note of length {expected_len} but got {actual_len} for note type id {note_type_id}"
                        );

                        let note = $unpack(aztec::utils::array::subarray(packed_note.storage(), 0));

                        let note_hash = $compute_note_hash(note, owner, storage_slot, randomness);
    
                        // The message discovery process finds settled notes, that is, notes that were created in prior transactions and are therefore already part of the note hash tree. We therefore compute the nullification note hash by treating the note as a settled note with the provided note nonce.
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
            /// Unpacks an array into a note corresponding to `note_type_id` and then computes its note hash (non-siloed) and inner nullifier (non-siloed) assuming the note has been inserted into the note hash tree with `note_nonce`.
            ///
            /// The signature of this function notably matches the `aztec::messages::discovery::ComputeNoteHashAndNullifier` type, and so it can be used to call functions from that module such as `do_sync_state` and `attempt_note_discovery`.
            ///
            /// This function is automatically injected by the `#[aztec]` macro.
            #[contract_library_method]
            unconstrained fn _compute_note_hash_and_nullifier(
                packed_note: BoundedVec<Field, aztec::messages::logs::note::MAX_NOTE_PACKED_LEN>,
                owner: aztec::protocol::address::AztecAddress,
                storage_slot: Field,
                note_type_id: Field,
                contract_address: aztec::protocol::address::AztecAddress,
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
            /// This contract does not use private notes, so this function should never be called as it will unconditionally fail.
            ///
            /// This function is automatically injected by the `#[aztec]` macro.
            #[contract_library_method]
            unconstrained fn _compute_note_hash_and_nullifier(
                _packed_note: BoundedVec<Field, aztec::messages::logs::note::MAX_NOTE_PACKED_LEN>,
                _owner: aztec::protocol::address::AztecAddress,
                _storage_slot: Field,
                _note_type_id: Field,
                _contract_address: aztec::protocol::address::AztecAddress,
                _randomness: Field,
                _nonce: Field,
            ) -> Option<aztec::messages::discovery::NoteHashAndNullifier> {
                panic(f"This contract does not use private notes")
            }
        }
    }
}

/// Generates the `sync_state` utility function that performs message discovery.
comptime fn generate_sync_state(process_custom_message_option: Quoted) -> Quoted {
    quote {
        pub struct sync_state_parameters {}

        #[abi(functions)]
        pub struct sync_state_abi {
            parameters: sync_state_parameters,
        }

        #[aztec::macros::internals_functions_generation::abi_attributes::abi_utility]
        unconstrained fn sync_state() {
            let address = aztec::context::UtilityContext::new().this_address();
            aztec::messages::discovery::do_sync_state(
                address,
                _compute_note_hash_and_nullifier,
                $process_custom_message_option,
            );
        }
    }
}

/// Generates the `process_message` utility function that processes a single message ciphertext.
comptime fn generate_process_message(process_custom_message_option: Quoted) -> Quoted {
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
                $process_custom_message_option,
                message_ciphertext,
                message_context,
            );

            // At this point, the note is pending validation and storage in the database. We must call
            // validate_and_store_enqueued_notes_and_events to complete that process.
            aztec::messages::processing::validate_and_store_enqueued_notes_and_events(address);
        }
    }
}

/// Validates a custom message handler.
///
/// Custom message handlers are specified by name via `AztecConfig::custom_message_handler`. A custom message
/// handler must be a function that conforms to the
/// [`CustomMessageHandler`](crate::messages::discovery::CustomMessageHandler) type signature. The function must be
/// unconstrained and marked as `#[contract_library_method]`.
///
/// Returns a `FunctionDefinition` so we can get its properly quoted name.
comptime fn validate_custom_message_handler(m: Module, handler_name: CtString) -> FunctionDefinition {
    let expected_type: Type = quote { crate::messages::discovery::CustomMessageHandler<()> }.as_type();
    let expected_type_name = f"{expected_type}";

    let matching_fns = m.functions().filter(|f: FunctionDefinition| {
        let fn_name_quoted = f.name();
        let fn_name = f"{fn_name_quoted}".as_ctstring();
        fn_name.eq(handler_name)
    });

    if matching_fns.len() == 0 {
        panic(
            f"Custom message handler '{handler_name}' not found in the contract. The handler must be a #[contract_library_method] conforming to {expected_type_name}.",
        );
    }

    let handler = matching_fns[0];

    if !is_fn_contract_library_method(handler) {
        panic(
            f"Custom message handler '{handler_name}' must be marked #[contract_library_method]. See {expected_type_name} for the expected signature.",
        );
    }

    if !handler.is_unconstrained() {
        panic(
            f"Custom message handler '{handler_name}' must be unconstrained. See {expected_type_name} for the expected signature.",
        );
    }

    let expected_param_types: [Type; 5] = [
        quote { crate::protocol::address::AztecAddress }.as_type(),
        quote { u64 }.as_type(),
        quote { u64 }.as_type(),
        quote { BoundedVec<Field, crate::messages::encoding::MAX_MESSAGE_CONTENT_LEN> }.as_type(),
        quote { crate::messages::processing::MessageContext }.as_type(),
    ];

    let params = handler.parameters();
    let num_params = params.len();
    let expected_num_params = expected_param_types.len();
    if num_params != expected_num_params {
        panic(
            f"Custom message handler '{handler_name}' has {num_params} parameters but expected {expected_num_params}. See {expected_type_name} for the expected signature.",
        );
    }

    for i in 0..expected_param_types.len() {
        let (_param_name, param_type) = params[i];
        let expected_param_type = expected_param_types[i];
        if param_type != expected_param_type {
            let actual = f"{param_type}";
            let expected = f"{expected_param_type}";
            panic(
                f"Custom message handler '{handler_name}' parameter {i} has type {actual} but expected {expected}. See {expected_type_name} for the expected signature.",
            );
        }
    }

    let return_type = handler.return_type();
    let expected_return_type: Type = quote { () }.as_type();
    if return_type != expected_return_type {
        let actual = f"{return_type}";
        let expected = f"{expected_return_type}";
        panic(
            f"Custom message handler '{handler_name}' returns {actual} but expected {expected}. See {expected_type_name} for the expected signature.",
        );
    }

    handler
}

/// Checks that all functions in the module have a context macro applied.
///
/// Non-macroified functions are not allowed in contracts. They must all be one of
/// [`external`](crate::macros::functions::external), [`internal`](crate::macros::functions::internal) or `test`.
comptime fn check_each_fn_macroified(m: Module) {
    for f in m.functions() {
        let name = f.name();
        if !is_fn_external(f) & !is_fn_contract_library_method(f) & !is_fn_internal(f) & !is_fn_test(f) {
            // We  don't suggest that #[contract_library_method] is allowed because we don't want to introduce another
            // concept
            panic(
                f"Function {name} must be marked as either #[external(...)], #[internal(...)], or #[test]",
            );
        }
    }
}
