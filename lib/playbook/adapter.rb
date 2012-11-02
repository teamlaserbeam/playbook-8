module Playbook
  class Adapter  
    
    def initialize(request = nil)
      @request = request
      @response = nil
    end

    def success(variables = {})
      respond(true, variables)
    end

    def failure(object_or_message = nil)
      respond(false, object_or_message)
    end

    def respond(success, variables_or_message)
      if success
        @response = @request.response_class.new(@request, true, variables_or_message)
      else 
        @response = @request.error_response_class.new(@request, variable_or_message)
      end    
    end


    class << self
      
      def whitelist(*keys)
        options = keys.extract_options!

        on = [options[:on] || options[:for] || :all].flatten.compact

        on.each do |key|
          whitelisted_params[key] ||= []
          whitelisted_params[key] |= keys
        end
      end

      def require_params(*keys)
        whitelist(*keys)

        options = keys.extract_options!

        any = options.delete(:any)
        on = [options[:on] || options[:for] || :all].flatten.compact
        
        on.each do |key|
          required_params[key] ||= {}
          required_params[key][:need] ||= []
          required_params[key][:any_of] ||= []
          if any
            required_params[key][:any_of] |= keys
          else
            required_params[key][:need] |= keys
          end
        end
      end
      alias_method :require_param, :require_params


      def require_any_param(*keys)
        options = keys.extract_options!
        options[:any] = true
        keys << options
        require_params(*keys)
      end
      
      def sanitize_params(params, method_name)
        safe_keys = Array(whitelisted_params[method_name.to_sym])
        return params if safe_keys.empty?
        
        always_safe = Array(whitelisted_params[:all])
        params.slice(*(safe_keys | always_safe))
      end

      # TODO: refactor. creates a lot of extra arrays and stuff.
      def ensure_required_params_exist!(params, method_name)
        required_keys = Array(required_params[method_name.to_sym].try(:[], :need))
        any_of = Array(required_params[method_name.to_sym].try(:[], :any_of))
        
        return if required_keys.empty? && any_of.empty?
        
        param_keys = params.keys.map(&:to_sym)
        unless required_keys.empty?
          missing_required = (required_keys - param_keys)
          raise ::Playbook::Errors::RequiredParameterMissingError.new(missing_required) unless missing_required.empty?
        end
      
        unless any_of.empty? 
          has_intersection = !(any_of & param_keys).empty?
          raise ::Playbook::Errors::RequiredParameterMissingError.new(any_of, true) unless has_intersection
        end
      end
      
      def whitelisted_params
        @whitelisted_params ||= {}
      end
      
      def whitelisted_params=(params)
        @whitelisted_params = params
      end

      def required_params
        @required_params ||= {}
      end
      
      def required_params=(params)
        @required_params = params
      end

      def desc(content = nil)
        content ||= yield if block_given?
        @current_method_documentation = content
      end
      alias_method :doc, :desc

      def nodoc
        @current_method_documentation = 'nodoc'
      end

      # do this at the end so only methods declared from this point on are observed
      def method_added(method_name)
        return if @skip_method_checking
        return if method_name.to_s =~ /_with(out)?_filters$/
        return unless self.public_instance_methods.include?(method_name.to_s)
        endpoint(method_name)
      end

      protected

      def endpoint(name, options = {}, &block)
        if ::Playbook.config.require_documentation && @current_method_documentation.nil?
          raise ::Playbook::Errors::DocumentationNotProvidedError.new(self, name)
        end

        without_method_checks do
          class_eval <<-SAN, __FILE__, __LINE__ + 1
            def #{name}_with_filters(params)
              self.class.ensure_required_params_exist!(params, '#{name}')
              params = self.class.sanitize_params(params, '#{name}')
              #{name}_without_filters(params)
            end
          SAN
          alias_method_chain name, :filters
        end
        @current_method_documentation = nil
      end

      # this is needed because confusing things happen and you end up with a stack level too deep.
      # stack level too deeps aren't cool and stuff.
      def without_method_checks
        @skip_method_checking = true
        yield
        @skip_method_checking = false
      end

    end
  end
endadapter.rb