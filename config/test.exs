import Config

# Tests verify telemetry events are emitted with the documented shape,
# so the test build compiles emission call sites in for both libraries.
config :xqlite, :telemetry_enabled, true

# The adapter's own flag can be forced off (the production default) so the
# no-op emit/span macro path can be smoke-tested: set XQLITE_ECTO3_TELEMETRY=off.
config :xqlite_ecto3, :telemetry_enabled, System.get_env("XQLITE_ECTO3_TELEMETRY") != "off"
