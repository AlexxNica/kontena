module Kontena
  # An Actor that has some value
  # The value does not yet exist when initialized, it is nil
  # Once the value is first updated, then other Actors will be able to observe it
  # When the value later updated, other Actors will also observe those changes
  module Observable
    include Kontena::Logging

    class Message
      attr_reader :observe, :observable, :value

      # @param observe [Kontena::Observable::Observe]
      # @param observable [Kontena::Observable]
      # @param value [Object, nil]
      def initialize(observe, observable, value)
        @observe = observe
        @observable = observable
        @value = value
      end

      # @return [String]
      def describe_observable
        "Observable<#{@observable.class.name}>"
      end
    end

    # @return [Object, nil] last updated value, or nil if not observable?
    def observable_value
      @observable_value
    end

    # Obsevable has updated, as has not reset
    # @return [Boolean]
    def observable?
      !!@observable_value
    end

    # Registered observers
    #
    # @return [Hash{Kontena::Observer::Observe => Celluloid::Mailbox}]
    def observers
      @observers ||= {}
    end

    # The Observable has a value. Propagate it to any observing Actors.
    #
    # This will notify any Observers, causing them to yield if ready.
    #
    # The value must be safe for access by multiple threads, even after this update,
    # and even after any later updates. Ideally, it should be immutable (frozen).
    #
    # @param value [Object]
    # @raise [ArgumentError] Update with nil value
    def update_observable(value)
      raise ArgumentError, "Update with nil value" if value.nil?
      debug "update: #{value}"

      @observable_value = value

      notify_observers
    end

    # The Observable no longer has a value
    # This will notify any Observers, causing them to block yields until we update again
    def reset_observable
      @observable_value = nil

      notify_observers
    end

    # Observer actor is observing this Actor's @value.
    # Updates to value will send to update_observe on given actor.
    # Returns current value.
    #
    # @param mailbox [Celluloid::Mailbox]
    # @param observe [Observer::Observe]
    # @return [Kontena::Observable::Message] with current value
    def add_observer(mailbox, observe, persistent: true)
      if value = @observable_value
        debug "observer: #{observe.describe_observer} <= #{value.inspect[0..64] + '...'}"

        observers[observe] = mailbox if persistent
      else
        debug "observer: #{observe.describe_observer}..."

        observers[observe] = mailbox
      end

      return Message.new(observe, self, @observable_value)
    end

    # Update @value to each Observer::Observe
    def notify_observers
      observers.each do |observe, mailbox|
        if observe.alive? && mailbox.alive?
          debug "notify: #{observe.describe_observer} <- #{@observable_value.inspect[0..64] + '...'}"

          mailbox << Message.new(observe, self, @observable_value)
        else
          debug "dead: #{observe.describe_observer}"

          observers.delete(observe)
        end
      end
    end
  end
end
