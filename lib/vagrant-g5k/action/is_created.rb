require "log4r"

module VagrantPlugins
  module G5K
    module Action
      # This can be used with "Call" built-in to check if the machine
      # is created and branch in the middleware.
      class IsCreated
        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant_g5k::action::is_created")
        end

        def call(env)
          machine_state_id = env[:machine].state.id
          @logger.info "machine is in state #{machine_state_id}"
          env[:result] = machine_state_id == :Running or machine_state_id == :Waiting
          @app.call(env)
        end
      end
    end
  end
end
