require 'kontena/client'

module Kontena
  class StacksClient < Client

    ACCEPT_JSON    = { 'Accept' => 'application/json' }
    ACCEPT_YAML    = { 'Accept' => 'application/yaml' }
    ACCEPT_JSONAPI = { 'Accept' => 'application/vnd.api+json' }
    CT_YAML        = { 'Content-Type' => 'application/yaml' }
    CT_JSONAPI     = { 'Content-Type' => 'application/vnd.api+json' }

    def raise_unless_token
      unless token && token['access_token']
        raise Kontena::Errors::StandardError.new(401, "Stack registry write operations require authentication")
      end
    end

    def raise_unless_read_token
      return false unless options[:read_requires_token]
      unless token && token['access_token']
        raise Kontena::Errors::StandardError.new(401, "Stack registry requires authentication")
      end
    end

    def full_uri(stack_name)
      URI.join(api_url, path_to(stack_name)).to_s
    end

    def path_to_version(stack_name)
      path_to_stack(stck_name) + "/stack-versions/%s" % [stack_name.user, stack_name.stack, stack_name.version || 'latest']
    end

    def path_to_stack(stack_name)
      "/v2/organizations/%s/stacks/%s" % [stack_name.user, stack_name.stack]
    end

    def push(stack_name, data)
      raise_unless_token
      post('/stack/', data, {}, CT_YAML, true)
    end

    def show(stack_name, include_prerelease: true)
      raise_unless_read_token
      get("#{path_to_stack(stack_name)}", nil, ACCEPT_JSONAPI)
    end

    def versions(stack_name, include_prerelease: true, include_deleted: false)
      raise_unless_read_token
      get("#{path_to_stack(stack_name)}/stack-versions", { 'include-prerelease' => include_prerelease, 'include-deleted' => include_deleted}, ACCEPT_JSONAPI).dig('data')
    end

    def pull(stack_name, version = nil)
      raise_unless_read_token
      get(path_to_version(stack_name), nil, ACCEPT_JSONAPI).dig('data', 'attributes', 'yaml')
    rescue StandardError => ex
      ex.message << " : #{path_to(stack_name)}"
      raise ex, ex.message
    end

    def search(query, include_prerelease: true, include_private: true)
      raise_unless_read_token
      get('/v2/stacks', { 'query' => query, 'include-prerelease' => include_prerelease, 'include-private' => include_private }, ACCEPT_JSONAPI).dig('data')
    end

    def destroy(stack_name)
      raise_unless_token
      delete('/v2/stacks/%s' % stack_id(stack_name), nil, {}, ACCEPT_JSONAPI)
    end

    def make_private(stack_name)
      change_visibility(stack_name, is_private: true)
    end

    def make_public(stack_name)
      change_visibility(stack_name, is_private: false)
    end

    def create(stack_name, is_private: true)
      post(
        '/v2/stacks',
        stack_data(stack_name, is_private: is_private),
        {},
        CT_JSONAPI.merge(ACCEPT_JSONAPI)
      )
    end

    private

    def stack_id(stack_name)
      show(stack_name).dig('data', 'id')
    end

    def change_visibility(stack_name, is_private: true)
      raise_unless_token
      put(
        '/v2/stacks/%s' % stack_id(stack_name),
        stack_data(stack_name, is_private: is_private),
        {},
        CT_JSONAPI.merge(ACCEPT_JSONAPI)
      )
    end

    def stack_data(stack_name, is_private: true)
      {
        data: {
          type: 'stacks',
          attributes: {
            'name' => stack_name.stack,
            'organization-id' => stack_name.user,
            'is-private' => is_private
          }
        }
      }
    end
  end
end
