defmodule Relay.TopSupervisor do

  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, [])
  end

  def init(_) do
    children = [
      # Independent; Announcer and the various bundles will require it
      # to be live
      worker(Carrier.CredentialManager, []),

      # Simple 1-for-1 that is what ultimately starts bundles;
      # required by the Scanner and Announcer
      supervisor(Relay.Bundle.Runner, []),

      # Catalog is independent, but Scanner and Announcer both require
      # it to be up
      worker(Relay.Bundle.Catalog, []),

      # Start up all currently-installed bundles before announcing
      # them to the world
      worker(Relay.Bundle.Starter, []),

      # Announcer depends on all the previous being up and running.
      # Announces the bundles the bot knows about.
      #
      # TODO: Might need to wait until all command processes are up
      # before announcing; otherwise we might get command messages we
      # don't have processes up for yet. Of course, that would prevent
      # receiving messages for bundles that started fine, if some
      # other bundles croaked.
      #
      # Perhaps Announcer needs to be reworked such that it sends an
      # announcement per bundle when they're up?
      worker(Relay.Announcer, []),

      # Scanner calls Announcer!
      worker(Relay.Bundle.Scanner, []),
    ]

    supervise(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 60)
  end

end
