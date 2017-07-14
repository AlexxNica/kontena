require_relative '../helpers/iface_helper'
require_relative '../helpers/launcher_helper'

module Kontena::Launchers
  class Etcd
    include Celluloid
    include Celluloid::Notifications
    include Kontena::Logging
    include Kontena::Observer
    include Kontena::Observable
    include Kontena::Helpers::LauncherHelper
    include Kontena::Helpers::IfaceHelper

    ETCD_VERSION = ENV['ETCD_VERSION'] || '2.3.7'
    ETCD_IMAGE = ENV['ETCD_IMAGE'] || 'kontena/etcd'
    IMAGE = "#{ETCD_IMAGE}:#{ETCD_VERSION}"

    def initialize(autostart = true)
      @running = false
      info 'initialized'
      async.start if autostart
    end

    def start
      ensure_image(IMAGE)

      observe(Actor[:node_info_worker], Actor[:weave_launcher]) do |node, weave|
        self.update(node)
      end
    end

    # XXX: exclusive!
    # @param node [Node]
    def update(node)
      state = self.ensure(node)

      update_observable(state)

    rescue => exc
      error exc

      reset_observable
    end

    # @param [Node] node
    # @return [Hash{running: true}]
    def ensure(node)
      create_data_container(IMAGE)
      container = ensure_container(IMAGE, node)

      add_dns(container.id, node.overlay_ip)

      {
        running: container.running?
      }
    end

    # @param [String] image
    # @return [Docker::Container]
    def create_data_container(image)
      unless data_container = inspect_container('kontena-etcd-data')
        info "creating new etcd data container"

        data_container = Docker::Container.create(
          'name' => 'kontena-etcd-data',
          'Image' => image,
          'Volumes' => {'/var/lib/etcd' => {}}
        )
      end
    end

    # @param [String] image
    # @param [Node] node
    # @raise [Docker::Error]
    # @return [Docker::Container]
    def ensure_container(image, node)
      container = self.inspect_container('kontena-etcd')
      container_image = container.info['Config']['Image']

      if container && container_image != image
        info "etcd is outdated, upgrading to #{image} from #{container_image}"
        container.delete(force: true)
      elsif container && container.running?
        info 'etcd is already running'
        return container
      elsif container && !container.running?
        info 'etcd is stopped, starting it'
        container.start!
        return container
      else
        info "etcd does not yet exist"
      end

      if node.initial_member?
        # No previous container exists, update previous membership info if needed
        cluster_state = update_membership(node)

        info "configuring etcd node as a cluster member with initial state: #{cluster_state}"
      else
        info "configuring etcd node as a proxy"

        cluster_state = nil
      end

      options = {
        name: "node-#{node.node_number}",
        overlay_ip: node.overlay_ip,
        docker_ip: docker_gateway,
        cluster_token: node.grid['name'],
        cluster_state: cluster_state,
        initial_cluster: initial_cluster(node.grid_subnet, node.grid_initial_size),
      }

      info "creating etcd service: #{options.inspect}"

      return create_container(image, **options)
    end

    # @param cluster_state [String, nil] proxy if nil, else cluster member
    # @raise [Docker::Error]
    # @return [Docker::Container]
    def create_container(image, name:, overlay_ip:, docker_ip:, initial_cluster:, cluster_state:, cluster_token:)
      cmd = [
        '--name', name, '--data-dir', '/var/lib/etcd',
        '--listen-client-urls', "http://127.0.0.1:2379,http://#{overlay_ip}:2379,http://#{docker_ip}:2379",
        '--initial-cluster', initial_cluster.join(',')
      ]

      if cluster_state
        cmd = cmd + [
          '--listen-peer-urls', "http://#{overlay_ip}:2380",
          '--advertise-client-urls', "http://#{overlay_ip}:2379",
          '--initial-advertise-peer-urls', "http://#{overlay_ip}:2380",
          '--initial-cluster-token', cluster_token,
          '--initial-cluster-state', cluster_state
        ]
      else
        cmd = cmd + ['--proxy', 'on']
      end

      container = Docker::Container.create(
        'name' => 'kontena-etcd',
        'Image' => image,
        'Cmd' => cmd,
        'HostConfig' => {
          'NetworkMode' => 'host',
          'RestartPolicy' => {'Name' => 'always'},
          'VolumesFrom' => ['kontena-etcd-data']
        }
      )
      container.start!
      container
    end

    # Removes possible previous member with the same IP
    #
    # @param [Node] node
    # @return [String] the state of the cluster member
    def update_membership(node)
      info 'checking if etcd previous membership needs to be updated'

      etcd_connection = find_etcd_node(node)
      return 'new' unless etcd_connection # No etcd hosts available, bootstrapping first node --> new cluster

      weave_ip = node.overlay_ip
      peer_url = "http://#{weave_ip}:2380"
      client_url = "http://#{weave_ip}:2379"

      members = JSON.parse(etcd_connection.get.body)
      members['members'].each do |member|
        if member['peerURLs'].include?(peer_url) && member['clientURLs'].include?(client_url)
          # When there's both peer and client URLs, the given peer has been a member of the cluster
          # and needs to be replaced
          delete_membership(etcd_connection, member['id'])
          sleep 1 # There seems to be some race condition with etcd member API, thus some sleeping required
          add_membership(etcd_connection, peer_url)
          sleep 1
          return 'existing'
        elsif member['peerURLs'].include?(peer_url) && !member['clientURLs'].include?(client_url)
          # Peer found but not been part of the cluster yet, no modification needed and it can join as new member
          return 'new'
        end
      end

      info 'previous member info not found at all, adding'
      add_membership(etcd_connection, peer_url)

      'new' # Newly added member will join as new member
    end

    ##
    # Finds a working etcd node from set of initial nodes
    #
    # @param [Node] node
    # @return [Hash] The cluster members as given by etcd API
    def find_etcd_node(node)
      grid_subnet = IPAddr.new(node.grid['subnet'])
      tries = node.grid['initial_size']
      begin
        etcd_host = "http://#{grid_subnet[tries]}:2379/v2/members"

        info "connecting to existing etcd at #{etcd_host}"
        connection = Excon.new(etcd_host)
        members = JSON.parse(connection.get.body)

        return connection
      rescue Excon::Errors::Error => exc
        tries -= 1
        if tries > 0
          info 'retrying next etcd host'
          retry
        else
          info 'no online etcd host found, we\'re probably bootstrapping first node'
        end
      end
      nil
    end

    # Deletes membership of given etcd peer
    #
    # @param [Excon::Connection] etcd HTTP members API connection
    # @param [String] id of the peer to be removed
    def delete_membership(connection, id)
      info "Removing existing etcd membership info with id #{id}"
      connection.delete(:path => "/v2/members/#{id}")
    end

    ##
    # Add new peer membership
    #
    # @param [Excon::Connection] etcd HTTP members API connection
    # @param [String] The peer URL of the new peer to be added to the cluster
    def add_membership(connection, peer_url)
      info "Adding new etcd membership info with peer URL #{peer_url}"
      connection.post(:body => JSON.generate(peerURLs: [peer_url]),
                      :headers => { 'Content-Type' => 'application/json' })
    end

    # @param [String] container_id
    # @param [String] weave_ip
    def add_dns(container_id, weave_ip)
      publish('dns:add', {id: container_id, ip: weave_ip, name: 'etcd.kontena.local'})
    end

    # @param grid_subnet [IPAddress]
    # @param initial_size [Integer]
    # @return [Array<String>]
    def initial_cluster(grid_subnet, initial_size)
      (1..initial_size).map { |i|
        grid_subnet.host_at(i)
      }
    end

    ##
    # @return [String, NilClass]
    def docker_gateway
      interface_ip('docker0')
    end

    # @param [Exception] exc
    def log_error(exc)
      error "#{exc.class.name}: #{exc.message}"
      error exc.backtrace.join("\n")
    end
  end
end
