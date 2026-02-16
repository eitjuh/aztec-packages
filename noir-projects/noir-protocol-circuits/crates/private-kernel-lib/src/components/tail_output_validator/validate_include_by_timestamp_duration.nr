use types::{abis::global_variables::GlobalVariables, constants::MAX_INCLUDE_BY_TIMESTAMP_DURATION};

/// We enforce in the tail circuit that the `include_by_timestamp` is at most MAX_INCLUDE_BY_TIMESTAMP_DURATION after the
/// tx's anchor timestamp. This restriction was motivated by wanting to prune network nodes'
/// mempools of all txs that are longer than a day old.
pub fn validate_include_by_timestamp_duration(
    include_by_timestamp: u64,
    global_variables: GlobalVariables,
) {
    let max_timestamp = global_variables.timestamp + MAX_INCLUDE_BY_TIMESTAMP_DURATION;
    assert(
        include_by_timestamp <= max_timestamp,
        "include_by_timestamp exceeds the maximum duration",
    );
}
