import Config

# Tests verify telemetry events are emitted with the documented shape,
# so the test build compiles emission call sites in for both libraries.
config :xqlite, :telemetry_enabled, true
config :xqlite_ecto3, :telemetry_enabled, true
