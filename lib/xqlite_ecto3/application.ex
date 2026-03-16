defmodule XqliteEcto3.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: XqliteEcto3.Worker.start_link(arg)
      # {XqliteEcto3.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: XqliteEcto3.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
