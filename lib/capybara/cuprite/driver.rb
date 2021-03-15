# frozen_string_literal: true

require "uri"
require "forwardable"

module Capybara::Cuprite
  class Driver < Capybara::Driver::Base
    DEFAULT_MAXIMIZE_SCREEN_SIZE = [1366, 768].freeze
    EXTENSION = File.expand_path("javascripts/index.js", __dir__)

    extend Forwardable

    delegate %i(restart quit status_code timeout timeout=) => :browser

    attr_reader :app, :options, :screen_size

    def initialize(app, options = {})
      @app     = app
      @options = options.dup
      @started = false

      @options[:extensions] ||= []
      @options[:extensions] << EXTENSION

      @screen_size = @options.delete(:screen_size)
      @screen_size ||= DEFAULT_MAXIMIZE_SCREEN_SIZE

      @options[:save_path] = Capybara.save_path.to_s if Capybara.save_path

      ENV["FERRUM_DEBUG"] = "true" if ENV["CUPRITE_DEBUG"]
    end

    def needs_server?
      true
    end

    def browser
      @browser ||= Browser.new(@options)
    end

    def visit(url)
      @started = true
      browser.visit(url)
    end

    def current_url
      if Capybara::VERSION.to_f < 3.0
        frame_url
      else
        browser.current_url
      end
    end

    def frame_url
      evaluate_script("window.location.href")
    end

    def html
      browser.body
    end
    alias_method :body, :html

    def source
      browser.source.to_s
    end

    def title
      if Capybara::VERSION.to_f < 3.0
        frame_title
      else
        browser.title
      end
    end

    def frame_title
      evaluate_script("document.title")
    end

    def find_xpath(selector)
      find(:xpath, selector)
    end

    def find_css(selector)
      find(:css, selector)
    end

    def find(method, selector)
      browser.find(method, selector).map { |native| Node.new(self, native) }
    end

    def click(x, y)
      browser.mouse.click(x: x, y: y)
    end

    def evaluate_script(script, *args)
      result = browser.evaluate(script, *native_args(args))
      unwrap_script_result(result)
    end

    def evaluate_async_script(script, *args)
      result = browser.evaluate_async(script, session_wait_time, *native_args(args))
      unwrap_script_result(result)
    end

    def execute_script(script, *args)
      browser.execute(script, *native_args(args))
      nil
    end

    def switch_to_frame(locator)
      handle = case locator
      when Capybara::Node::Element
        locator.native.description["frameId"]
      when :parent, :top
        locator
      end

      browser.switch_to_frame(handle)
    end

    def current_window_handle
      browser.window_handle
    end

    def window_handles
      browser.window_handles
    end

    def close_window(handle)
      browser.close_window(handle)
    end

    def open_new_window
      target = browser.default_context.create_target
      target.maybe_sleep_if_new_window
      target.page = Page.new(target.id, browser)
      target.page
    end

    def switch_to_window(handle)
      browser.switch_to_window(handle)
    end

    def within_window(name, &block)
      browser.within_window(name, &block)
    end

    def no_such_window_error
      Ferrum::NoSuchPageError
    end

    def reset!
      @zoom_factor = nil
      @paper_size = nil
      browser.url_blacklist = @options[:url_blacklist]
      browser.url_whitelist = @options[:url_whitelist]
      browser.on_mouse_event_failed = @options[:on_mouse_event_failed]
      browser.reset
      @started = false
    end

    def save_screenshot(path, options = {})
      options[:scale] = @zoom_factor if @zoom_factor

      if pdf?(path, options)
        options[:paperWidth] = @paper_size[:width].to_f if @paper_size
        options[:paperHeight] = @paper_size[:height].to_f if @paper_size
        browser.pdf(path: path, **options)
      else
        browser.screenshot(path: path, **options)
      end
    end
    alias_method :render, :save_screenshot

    def render_base64(format = :png, options = {})
      if pdf?(nil, options)
        options[:paperWidth] = @paper_size[:width].to_f if @paper_size
        options[:paperHeight] = @paper_size[:height].to_f if @paper_size
        browser.pdf(encoding: :base64, **options)
      else
        browser.screenshot(format: format, encoding: :base64, **options)
      end
    end

    def zoom_factor=(value)
      @zoom_factor = value.to_f
    end

    def paper_size=(value)
      @paper_size = value
    end

    def resize(width, height)
      browser.resize(width: width, height: height)
    end
    alias_method :resize_window, :resize

    def resize_window_to(handle, width, height)
      within_window(handle) do
        resize(width, height)
      end
    end

    def maximize_window(handle)
      resize_window_to(handle, *screen_size)
    end

    def window_size(handle)
      within_window(handle) do
        evaluate_script("[window.innerWidth, window.innerHeight]")
      end
    end

    def fullscreen_window(handle)
      within_window(handle) do
        browser.resize(fullscreen: true)
      end
    end

    def scroll_to(left, top)
      browser.mouse.scroll_to(left, top)
    end

    def network_traffic(type = nil)
      traffic = browser.network.traffic

      case type.to_s
      when "all"
        traffic
      when "blocked"
        traffic.select(&:blocked?)
      else
        # when request isn't blocked
        traffic.reject(&:blocked?)
      end
    end

    def clear_network_traffic
      browser.network.clear(:traffic)
    end

    def set_proxy(ip, port, type = nil, user = nil, password = nil, bypass = nil)
      @options[:browser_options] ||= {}
      server = type ? "#{type}=#{ip}:#{port}" : "#{ip}:#{port}"
      @options[:browser_options].merge!("proxy-server" => server)
      @options[:browser_options].merge!("proxy-bypass-list" => bypass) if bypass
      browser.network.authorize(type: :proxy, user: user, password: password) do |request|
        request.continue
      end
    end

    def headers
      browser.headers.get
    end

    def headers=(headers)
      browser.headers.set(headers)
    end

    def add_headers(headers)
      browser.headers.add(headers)
    end

    def add_header(name, value, permanent: true)
      browser.headers.add({ name => value }, permanent: permanent)
    end

    def response_headers
      browser.network.response&.headers
    end

    def cookies
      browser.cookies.all
    end

    def set_cookie(name, value, options = {})
      options = options.dup
      options[:name]   ||= name
      options[:value]  ||= value
      options[:domain] ||= default_domain
      browser.cookies.set(**options)
    end

    def remove_cookie(name, **options)
      options[:domain] = default_domain if options.empty?
      browser.cookies.remove(**options.merge(name: name))
    end

    def clear_cookies
      browser.cookies.clear
    end

    def wait_for_network_idle(**options)
      browser.network.wait_for_idle(**options)
    end

    def clear_memory_cache
      browser.network.clear(:cache)
    end

    def basic_authorize(user, password)
      browser.network.authorize(user: user, password: password) do |request|
        request.continue
      end
    end
    alias_method :authorize, :basic_authorize

    def debug_url
      "http://#{browser.process.host}:#{browser.process.port}"
    end

    def debug(binding = nil)
      if @options[:inspector]
        Process.spawn(browser.process.path, debug_url)

        if binding&.respond_to?(:pry)
          Pry.start(binding)
        elsif binding&.respond_to?(:irb)
          binding.irb
        else
          pause
        end
      else
        raise Error, "To use the remote debugging, you have to launch " \
                     "the driver with `inspector: ENV['INSPECTOR']` " \
                     "configuration option and run your test suite passing " \
                     "env variable"
      end
    end

    def pause
      # STDIN is not necessarily connected to a keyboard. It might even be closed.
      # So we need a method other than keypress to continue.

      # In jRuby - STDIN returns immediately from select
      # see https://github.com/jruby/jruby/issues/1783
      read, write = IO.pipe
      thread = Thread.new { IO.copy_stream(STDIN, write); write.close }

      STDERR.puts "Cuprite execution paused. Press enter (or run 'kill -CONT #{Process.pid}') to continue."

      signal = false
      old_trap = trap("SIGCONT") { signal = true; STDERR.puts "\nSignal SIGCONT received" }
      keyboard = IO.select([read], nil, nil, 1) until keyboard || signal # wait for data on STDIN or signal SIGCONT received

      unless signal
        begin
          input = read.read_nonblock(80) # clear out the read buffer
          puts unless input&.end_with?("\n")
        rescue EOFError, IO::WaitReadable # Ignore problems reading from STDIN.
        end
      end
    ensure
      thread.kill
      read.close
      trap("SIGCONT", old_trap) # Restore the previous signal handler, if there was one.
      STDERR.puts "Continuing"
    end

    def wait?
      true
    end

    def invalid_element_errors
      [Capybara::Cuprite::ObsoleteNode,
       Capybara::Cuprite::MouseEventFailed,
       Ferrum::CoordinatesNotFoundError,
       Ferrum::NoExecutionContextError,
       Ferrum::NodeNotFoundError]
    end

    def go_back
      browser.back
    end

    def go_forward
      browser.forward
    end

    def refresh
      browser.refresh
    end

    def wait_for_reload(*args)
      browser.wait_for_reload(*args)
    end

    def accept_modal(type, options = {})
      case type
      when :alert, :confirm
        browser.accept_confirm
      when :prompt
        browser.accept_prompt(options[:with])
      end

      yield if block_given?

      browser.find_modal(options)
    end

    def dismiss_modal(type, options = {})
      case type
      when :confirm
        browser.dismiss_confirm
      when :prompt
        browser.dismiss_prompt
      end

      yield if block_given?

      browser.find_modal(options)
    end

    private

    def default_domain
      if @started
        URI.parse(browser.current_url).host
      else
        URI.parse(default_cookie_host).host || "127.0.0.1"
      end
    end

    def native_args(args)
      args.map { |arg| arg.is_a?(Capybara::Cuprite::Node) ? arg.node : arg }
    end

    def session_wait_time
      if respond_to?(:session_options)
        session_options.default_max_wait_time
      else
        begin
          Capybara.default_max_wait_time
        rescue
          Capybara.default_wait_time
        end
      end
    end

    def default_cookie_host
      if respond_to?(:session_options)
        session_options.app_host
      else
        Capybara.app_host
      end || ""
    end

    def unwrap_script_result(arg)
      case arg
      when Array
        arg.map { |e| unwrap_script_result(e) }
      when Hash
        arg.each { |k, v| arg[k] = unwrap_script_result(v) }
      when Ferrum::Node
        Node.new(self, arg)
      else
        arg
      end
    end

    def pdf?(path, options)
      (path && File.extname(path).delete(".") == "pdf") ||
      options[:format].to_s == "pdf"
    end
  end
end
