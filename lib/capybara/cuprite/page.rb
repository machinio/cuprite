# frozen_string_literal: true

require "forwardable"

module Capybara::Cuprite
  class Page < Ferrum::Page
    MODAL_WAIT = ENV.fetch("CUPRITE_MODAL_WAIT", 0.05).to_f
    TRIGGER_CLICK_WAIT = ENV.fetch("CUPRITE_TRIGGER_CLICK_WAIT", 0.1).to_f

    extend Forwardable
    delegate %i[at_css at_xpath css xpath
                current_url current_title body execution_id
                evaluate evaluate_on evaluate_async execute] => :active_frame

    def initialize(*args)
      @frame_stack = []
      @accept_modal = []
      @modal_messages = []
      super
    end

    def set(node, value)
      object_id = command("DOM.resolveNode", nodeId: node.node_id).dig("object", "objectId")
      evaluate("_cuprite.set(arguments[0], arguments[1])", { "objectId" => object_id }, value)
    end

    def select(node, value)
      evaluate_on(node: node, expression: "_cuprite.select(this, #{value})")
    end

    def trigger(node, event)
      options = {}
      options.merge!(wait: TRIGGER_CLICK_WAIT) if event.to_s == "click" && TRIGGER_CLICK_WAIT > 0
      evaluate_on(node: node, expression: %(_cuprite.trigger(this, "#{event}")), **options)
    end

    def hover(node)
      evaluate_on(node: node, expression: "_cuprite.scrollIntoViewport(this)")
      x, y = find_position(node)
      command("Input.dispatchMouseEvent", type: "mouseMoved", x: x, y: y)
    end

    def send_keys(node, keys)
      if !evaluate_on(node: node, expression: %(_cuprite.containsSelection(this)))
        before_click(node, "click")
        node.click(mode: :left, keys: keys)
      end

      keyboard.type(keys)
    end

    def accept_confirm
      @accept_modal << true
    end

    def dismiss_confirm
      @accept_modal << false
    end

    def accept_prompt(modal_response)
      @accept_modal << true
      @modal_response = modal_response
    end

    def dismiss_prompt
      @accept_modal << false
    end

    def find_modal(options)
      start = Ferrum.monotonic_time
      timeout = options.fetch(:wait, browser.timeout)
      expect_text = options[:text]
      expect_regexp = expect_text.is_a?(Regexp) ? expect_text : Regexp.escape(expect_text.to_s)
      not_found_msg = "Unable to find modal dialog"
      not_found_msg += " with #{expect_text}" if expect_text

      begin
        modal_text = @modal_messages.shift
        raise Capybara::ModalNotFound if modal_text.nil? || (expect_text && !modal_text.match(expect_regexp))
      rescue Capybara::ModalNotFound => e
        raise e, not_found_msg if Ferrum.timeout?(start, timeout)
        sleep(MODAL_WAIT)
        retry
      end

      modal_text
    end

    def reset_modals
      @accept_modal = []
      @modal_response = nil
      @modal_messages = []
    end

    def before_click(node, name, keys = [], offset = {})
      evaluate_on(node: node, expression: "_cuprite.scrollIntoViewport(this)")

      # If offset is given it may go outside of the element and likely error
      # will be raised that we detected another element at this position.
      return true if offset[:x] || offset[:y]

      x, y = find_position(node, **offset)
      evaluate_on(node: node, expression: "_cuprite.mouseEventTest(this, '#{name}', #{x}, #{y})")
      true
    rescue Ferrum::JavaScriptError => e
      browser.notify_silenceable_exception(MouseEventFailed.new(e.message)) if e.class_name == "MouseEventFailed"
    end

    def switch_to_frame(handle)
      case handle
      when :parent
        @frame_stack.pop
      when :top
        @frame_stack = []
      else
        @frame_stack << handle
        inject_extensions
      end
    end

    def frame_name
      evaluate("window.name")
    end

    def title
      active_frame.current_title
    end

    private

    def prepare_page
      super

      network.intercept if !Array(@browser.url_whitelist).empty? ||
                           !Array(@browser.url_blacklist).empty?

      on(:request) do |request, index, total|
        if @browser.url_blacklist && !@browser.url_blacklist.empty?
          if @browser.url_blacklist.any? { |r| request.match?(r) }
            request.abort and next
          else
            request.continue and next
          end
        elsif @browser.url_whitelist && !@browser.url_whitelist.empty?
          if @browser.url_whitelist.any? { |r| request.match?(r) }
            request.continue and next
          else
            request.abort and next
          end
        elsif index + 1 < total
          # There are other callbacks that may handle this request
          next
        else
          # If there are no callbacks then just continue
          request.continue
        end
      end

      on("Page.javascriptDialogOpening") do |params|
        accept_modal = @accept_modal.last
        if accept_modal == true || accept_modal == false
          @accept_modal.pop
          @modal_messages << params["message"]
          options = { accept: accept_modal }
          response = @modal_response || params["defaultPrompt"]
          options.merge!(promptText: response) if response
          command("Page.handleJavaScriptDialog", **options)
        else
          with_text = params["message"] ? "with text `#{params["message"]}` " : ""
          warn "Modal window #{with_text}has been opened, but you didn't wrap "\
               "your code into (`accept_prompt` | `dismiss_prompt` | "\
               "`accept_confirm` | `dismiss_confirm` | `accept_alert`), "\
               "accepting by default"
          options = { accept: true }
          response = params["defaultPrompt"]
          options.merge!(promptText: response) if response
          command("Page.handleJavaScriptDialog", **options)
        end
      end
    end

    def find_position(node, **options)
      x, y = node.find_position(**options)
    rescue Ferrum::BrowserError => e
      if e.message == "Could not compute content quads."
        browser.notify_silenceable_exception(MouseEventFailed.new("MouseEventFailed: click, none, 0, 0"))
      else
        raise
      end
    end

    def active_frame
      if @frame_stack.empty?
        main_frame
      else
        @frames[@frame_stack.last]
      end
    end
  end
end
