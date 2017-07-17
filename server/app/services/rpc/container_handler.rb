require_relative 'container_info_mapper'

module Rpc
  class ContainerHandler
    include Logging

    attr_accessor :logs_buffer_size
    attr_accessor :stats_buffer_size

    # @params [HostNode] node
    def initialize(node)
      @node = node
      @logs = []
      @stats = []
      @cached_containers = {}
      @logs_buffer_size = 5
      @stats_buffer_size = 5
      @containers_cache_size = 50
      @db_session = ContainerLog.collection.client.with(
        write: {
          w: 0, fsync: false, j: false
        }
      )
    end

    # @param [Hash] data
    def save(data)
      info_mapper = ContainerInfoMapper.new(@node)
      info_mapper.from_agent(data)

      {}
    end

    # @param [String] node_id
    # @param [Array<String>] ids
    def cleanup(node_id, ids)
      @node.containers.unscoped.where(
        :container_id.in => ids
      ).destroy
    end

    # @param [Hash] data
    def log(data)
      container = cached_container(data['id'])
      if container
        if data['time']
          created_at = Time.parse(data['time'])
        else
          created_at = Time.now.utc
        end
        @logs << {
          grid_id: @node.grid_id,
          host_node_id: @node.id,
          grid_service_id: container['grid_service_id'],
          instance_number: container['instance_number'],
          container_id: container['_id'],
          created_at: created_at,
          name: container['name'],
          type: data['type'],
          data: data['data']
        }
        if @logs.size >= @logs_buffer_size
          flush_logs
          gc_cache
        end
      end
    end

    # @param [Hash] data
    def health(data)
      container = Container.find_by(
        node_id: @node.id, container_id: data['id']
      )
      if container
        container.set_health_status(data['status'])
        if container.grid_service
          MongoPubsub.publish(GridServiceHealthMonitorJob::PUBSUB_KEY, id: container.grid_service.id.to_s)
        end
      else
        warn "health status update failed, could not find container for id: #{data['id']}"
      end
    end

    # @param [Hash] data
    def stat(data)
      container = cached_container(data['id'])
      if container
        time = data['time'] ? Time.parse(data['time']) : Time.now.utc
        @stats << {
          grid_id: @node.grid_id,
          host_node_id: @node.id,
          grid_service_id: container['grid_service_id'],
          container_id: container['_id'],
          spec: data['spec'],
          cpu: data['cpu'],
          memory: data['memory'],
          filesystem: data['filesystem'],
          diskio: data['diskio'],
          network: data['network'],
          created_at: time
        }
        if @stats.size >= @stats_buffer_size
          flush_stats
          gc_cache
        end
      end
    end

    # @param [Hash] data
    def event(data)
      container = cached_container(data['id'])
      if container
        if data['status'] == 'destroy'
          container = Container.instantiate(container)
          container.destroy
        end
      end

      {}
    end

    def flush_logs
      @db_session[:container_logs].insert_many(@logs)
      @logs.clear
    end

    def flush_stats
      @db_session[:container_stats].insert_many(@stats.dup)
      @stats.clear
    end

    def gc_cache
      if @cached_containers.keys.size > @containers_cache_size
        (@containers_cache_size / 5).times { @cached_containers.shift }
      end
    end

    # @param [String] id
    # @return [Hash, NilClass]
    def cached_container(id)
      if @cached_containers[id]
        container = @cached_containers[id]
      else
        container = @db_session[:containers].find(
            host_node_id: @node.node_id, container_id: id
          ).limit(1).first
        @cached_containers[id] = container if container
      end

      container
    end
  end
end
