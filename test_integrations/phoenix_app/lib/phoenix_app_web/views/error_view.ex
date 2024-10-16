defmodule PhoenixAppWeb.ErrorView do
  use PhoenixAppWeb, :html

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.html", _assigns) do
  #   "Internal Server Error"
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
