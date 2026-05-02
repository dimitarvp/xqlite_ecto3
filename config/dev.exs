import Config

# Telemetry stays opt-in even in dev — keep parity with the default.
config :xqlite_ecto3, :telemetry_enabled, false
