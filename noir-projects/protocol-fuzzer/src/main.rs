mod token;
pub mod smt;
mod side_effect;
mod wallet;

use clap::{Parser, ValueEnum};

#[derive(Debug, Clone, ValueEnum)]
enum MachineType {
    Token,
    SideEffect,
}

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[arg(long, default_value = "token")]
    machine: MachineType,
    #[arg(long, default_value_t = 1)]
    min_tokens: usize,
    #[arg(long, default_value_t = 4)]
    max_tokens: usize,
    #[arg(long, default_value_t = 2)]
    min_storage_slots: usize,
    #[arg(long, default_value_t = 5)]
    max_storage_slots: usize,
    #[arg(long, default_value_t = 100000)]
    max_steps: usize,
    #[arg(long, default_value_t = 500_000_000)]
    randomness_size: u32,
    /// Replay a specific seed (e.g. 0x5a7211231dcd6500) to reproduce a failure.
    #[arg(long, value_parser = parse_hex_u64)]
    seed: Option<u64>,
}

fn parse_hex_u64(s: &str) -> Result<u64, String> {
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16).map_err(|e| e.to_string())
    } else {
        s.parse::<u64>().map_err(|e| e.to_string())
    }
}

impl From<&Args> for token::TokenMachine {
    fn from(args: &Args) -> Self {
        let mut machine = Self::default();
        machine.min_tokens = args.min_tokens;
        machine.max_tokens = args.max_tokens;
        machine
    }
}

impl From<&Args> for side_effect::SideEffectMachine {
    fn from(args: &Args) -> Self {
        Self {
            min_storage_slots: args.min_storage_slots,
            max_storage_slots: args.max_storage_slots,
        }
    }
}

fn main() {
    env_logger::init();

    let args = Args::parse();

    let builder = match args.seed {
        Some(seed) => {
            log::info!("Replaying seed 0x{seed:016x}");
            smt::seeded_builder(seed)
        }
        None => smt::fixed_size_builder(args.randomness_size),
    };

    match args.machine {
        MachineType::Token => {
            let mut machine = token::TokenMachine::from(&args);
            log::debug!("Starting token machine with parameters: {:?}", &machine);
            builder.run(|u| smt::run(u, &mut machine, args.max_steps))
        }
        MachineType::SideEffect => {
            let mut machine = side_effect::SideEffectMachine::from(&args);
            log::debug!(
                "Starting side-effect machine with parameters: {:?}",
                &machine
            );
            builder.run(|u| smt::run(u, &mut machine, args.max_steps))
        }
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use smt::StateMachine;

    /// Smoke test: deploys 1 token, runs 5 random operations (mints, transfers, balance checks).
    /// Requires a running Aztec sandbox (`aztec start --sandbox`).
    /// Note: may fail on the nightly sandbox due to gas fee spikes between blocks
    /// (maxFeesPerGas estimated at simulation time becomes too low by the time the tx lands).
    #[test]
    #[ignore]
    fn token_machine_smoke() {
        env_logger::try_init().ok();
        let mut machine = token::TokenMachine::default();
        machine.min_tokens = 1;
        machine.max_tokens = 1;
        machine.min_initial_public_mints = 1;
        machine.max_initial_public_mints = 2;
        machine.min_initial_private_mints = 0;
        machine.max_initial_private_mints = 1;
        // 1024 bytes of randomness is plenty for 5 steps
        smt::fixed_size_builder(1024)
            .run(|u| smt::run(u, &mut machine, 5))
    }

    /// Smoke test: deploys side-effect contract, runs 5 random operations (create/destroy notes, nullifiers).
    /// Requires a running Aztec sandbox with the side_effect_contract artifact built (see SANDBOX_INSTRUCTIONS.md).
    /// Note: may fail on the nightly sandbox due to gas fee spikes between blocks
    /// (maxFeesPerGas estimated at simulation time becomes too low by the time the tx lands).
    #[test]
    #[ignore]
    fn side_effect_machine_smoke() {
        env_logger::try_init().ok();
        let mut machine = side_effect::SideEffectMachine {
            min_storage_slots: 2,
            max_storage_slots: 2,
        };
        smt::fixed_size_builder(1024)
            .run(|u| smt::run(u, &mut machine, 5))
    }

    /// The same random byte buffer produces the same command sequence every time.
    /// We skip `new_system` (which deploys contracts) and only exercise
    /// state/command generation to verify determinism.
    #[test]
    fn seeded_run_is_deterministic() {
        use arbitrary::Unstructured;

        // Fixed buffer — any deterministic bytes will do.
        let buf: Vec<u8> = (0u8..=255).cycle().take(4096).collect();
        let steps = 20;

        let collect_commands = |data: &[u8]| {
            let mut u = Unstructured::new(data);
            let mut machine = side_effect::SideEffectMachine {
                min_storage_slots: 2,
                max_storage_slots: 3,
            };
            let mut state = machine.gen_state(&mut u).unwrap();
            let mut commands = Vec::new();
            for _ in 0..steps {
                let cmd = machine.gen_command(&mut u, &state).unwrap();
                commands.push(format!("{:?}", cmd));
                state = machine.next_state(&cmd, state);
            }
            commands
        };

        let run1 = collect_commands(&buf);
        let run2 = collect_commands(&buf);
        assert!(!run1.is_empty(), "should generate at least one command");
        assert_eq!(run1, run2, "same input must produce identical command sequences");
    }

    #[test]
    fn parse_hex_u64_lowercase() {
        assert_eq!(parse_hex_u64("0x5a7211231dcd6500").unwrap(), 0x5a7211231dcd6500);
    }

    #[test]
    fn parse_hex_u64_uppercase_prefix() {
        assert_eq!(parse_hex_u64("0Xdeadbeef").unwrap(), 0xdeadbeef);
    }

    #[test]
    fn parse_hex_u64_decimal() {
        assert_eq!(parse_hex_u64("42").unwrap(), 42);
    }

    #[test]
    fn parse_hex_u64_invalid() {
        assert!(parse_hex_u64("0xZZZZ").is_err());
    }
}
