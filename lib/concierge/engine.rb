module Concierge
  class Engine < ::Rails::Engine
    isolate_namespace Concierge

    # Seam for wiring that must run after the host app initializes (registering
    # tools, channels, sweep jobs). Deliberately a no-op in Phase 0.
    initializer "concierge.config" do
      # Later phases hook eager wiring here.
    end
  end
end
