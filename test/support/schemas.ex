defmodule XqliteEcto3.Test.User do
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    field :active, :boolean, default: true

    timestamps()
  end
end

defmodule XqliteEcto3.Test.Post do
  use Ecto.Schema

  schema "posts" do
    field :title, :string
    field :body, :string
    belongs_to :user, XqliteEcto3.Test.User

    timestamps()
  end
end
