defmodule PhoenixAppWeb.ScrubbingDemoHTML do
  @moduledoc """
  The page the parameter-scrubbing e2e spec interacts with.

  See the `scrubbing_demo_html` directory for all templates available.
  """
  use PhoenixAppWeb, :html

  embed_templates "scrubbing_demo_html/*"
end
