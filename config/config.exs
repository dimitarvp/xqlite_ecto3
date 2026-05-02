import Config

# Telemetry is opt-in. Set to `true` in your config to compile in
# `:telemetry.execute/3` / `:telemetry.span/3` calls at every event
# site in the adapter. When `false` (the default), all emission sites
# compile to no-ops.
#
# Mirrors the parent `:xqlite, :telemetry_enabled` flag — both must
# be enabled for full event coverage. The xqlite-level events
# (`[:xqlite, :*]`) are gated by `:xqlite, :telemetry_enabled`; the
# adapter-level events (`[:xqlite_ecto3, :*]`) are gated here.
config :xqlite_ecto3, :telemetry_enabled, false

if config_env() != :prod do
  import_config "#{config_env()}.exs"
end
