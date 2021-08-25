defmodule WebtorrentTrackerWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, views, channels and so on.

  This can be used in your application as:

      use WebtorrentTrackerWeb, :controller
      use WebtorrentTrackerWeb, :view

  The definitions below will be executed for every view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define any helper function in modules
  and import those modules here.
  """

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      import WebtorrentTrackerWeb
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  defmacro dbg(ast) do
    label = Macro.to_string(ast)

    quote do
      IO.puts(:stderr, [
        IO.ANSI.yellow(),
        String.replace(__ENV__.file, File.cwd!(), "."),
        ":",
        to_string(__ENV__.line)
      ])

      IO.inspect(:stderr, unquote(ast), label: unquote(label))
      IO.puts(:stderr, IO.ANSI.reset())
    end
  end
end
