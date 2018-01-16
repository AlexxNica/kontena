require_relative '../common'

module Kontena::Cli::Stacks::Registry
  class CreateCommand < Kontena::Command
    include Kontena::Cli::Common
    include Kontena::Cli::Stacks::Common
    include Kontena::Cli::Stacks::Common::RegistryNameParam

    banner "Changes stack settings on registry"

    option '--private', :flag, "Create as private", attribute_name: :is_private

    requires_current_account_token

    def execute
      exit_with_error "Can't create a stack with a version number" unless stack_name.version.nil?
      stacks_client.create(stack_name, is_private: is_private?)
      puts "Created a #{is_private? ? pastel.yellow('private') : 'public'} stack #{pastel.cyan(stack_name)} in Kontena Stack Registry"
    end
  end
end


